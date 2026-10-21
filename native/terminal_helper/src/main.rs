mod process;
mod protocol;

use base64::{Engine, engine::general_purpose::STANDARD};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use protocol::{Command, MAX_FRAME, MAX_INPUT, MAX_QUEUE, VERSION};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::io::{self, Write};
use std::path::Path;
use std::time::{Duration, Instant};

fn size(rows: u16, cols: u16) -> PtySize {
    PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

fn enqueue(queue: &mut VecDeque<u8>, value: Value) -> Result<(), &'static str> {
    let bytes = protocol::frame(&value).map_err(|_| "frame_size")?;
    if queue.len() + bytes.len() > MAX_QUEUE {
        return Err("output_queue_full");
    }
    queue.extend(bytes);
    Ok(())
}

fn allowed_env(key: &str) -> bool {
    matches!(
        key,
        "PATH"
            | "HOME"
            | "TMPDIR"
            | "LANG"
            | "LC_ALL"
            | "LC_CTYPE"
            | "TERM"
            | "COLORTERM"
            | "GIT_CONFIG_GLOBAL"
            | "GIT_CONFIG_NOSYSTEM"
            | "GIT_CONFIG_COUNT"
            | "PYTHONDONTWRITEBYTECODE"
            | "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    ) || (0..8)
        .any(|i| key == format!("GIT_CONFIG_KEY_{i}") || key == format!("GIT_CONFIG_VALUE_{i}"))
}

fn run() -> Result<(), &'static str> {
    if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        return Err("unsupported_target");
    }
    match protocol::read_command(&mut io::stdin()).map_err(|_| "invalid_handshake")? {
        Command::Hello { version: VERSION } => (),
        _ => return Err("incompatible_version"),
    }
    io::stdout()
        .write_all(
            &protocol::frame(&json!({"op":"hello", "version":VERSION,
        "helper_version":env!("CARGO_PKG_VERSION"),"max_frame":MAX_FRAME}))
            .unwrap(),
        )
        .map_err(|_| "control_closed")?;
    io::stdout().flush().map_err(|_| "control_closed")?;

    let Command::Spawn {
        request_id,
        session_id,
        executable,
        argv,
        cwd,
        env,
        rows,
        cols,
    } = protocol::read_command(&mut io::stdin()).map_err(|_| "invalid_spawn")?
    else {
        return Err("spawn_required");
    };
    if !protocol::identifier(&request_id)
        || !protocol::identifier(&session_id)
        || !protocol::dimensions(rows, cols)
        || !Path::new(&cwd).is_absolute()
        || !Path::new(&cwd).is_dir()
        || !Path::new(&executable).is_absolute()
        || !Path::new(&executable).is_file()
        || argv.len() > 64
        || argv.iter().any(|s| s.len() > 16_384 || s.contains('\0'))
        || env.len() > 32
        || env
            .iter()
            .any(|(k, v)| !allowed_env(k) || v.len() > 16_384 || v.contains('\0'))
    {
        return Err("invalid_spawn");
    }
    let pair = native_pty_system()
        .openpty(size(rows, cols))
        .map_err(|_| "pty_unavailable")?;
    let mut cmd = CommandBuilder::new(std::env::current_exe().map_err(|_| "helper_path")?);
    cmd.args(["--child", &executable]);
    cmd.args(argv);
    cmd.cwd(cwd);
    cmd.env_clear();
    for (k, v) in env {
        cmd.env(k, v);
    }
    let mut child = pair.slave.spawn_command(cmd).map_err(|_| "spawn_failed")?;
    drop(pair.slave);
    let pgid = child.process_id().ok_or("pid_unavailable")? as i32;
    // portable-pty establishes a new session/group before exec. Verify the
    // identity before making any negative-PID signal possible.
    if pgid <= 1 || unsafe { libc::getpgid(pgid) } != pgid {
        let _ = child.kill();
        let _ = child.wait();
        return Err("invalid_process_group");
    }
    let guardian = match process::Guardian::start(pgid) {
        Ok(value) => value,
        Err(_) => {
            unsafe {
                libc::kill(-pgid, libc::SIGKILL);
            }
            let _ = child.wait();
            return Err("guardian_unavailable");
        }
    };
    let master = pair.master.as_raw_fd().ok_or("pty_fd_unavailable")?;
    process::await_bootstrap(master).map_err(|_| "bootstrap_failed")?;
    if process::write(master, &[0]).map_err(|_| "bootstrap_failed")? != 1 {
        return Err("bootstrap_failed");
    }
    for fd in [0, 1, master] {
        process::nonblocking(fd).map_err(|_| "nonblocking_failed")?;
    }
    let mut output = VecDeque::new();
    let mut input = VecDeque::new();
    let mut control = Vec::new();
    let mut buffer = [0u8; 4096];
    let mut termination = None;
    let mut exit_status = None;
    let mut exit_sent = false;
    let mut eof = false;
    let mut sequence: u64 = 0;
    enqueue(
        &mut output,
        json!({"op":"spawned","session_id":session_id,
        "request_id":request_id,"pid":pgid,"process_group":pgid}),
    )?;

    loop {
        if termination.is_some_and(|deadline| Instant::now() >= deadline) {
            guardian.signal(libc::SIGKILL);
            termination = None;
        }
        if exit_status.is_none()
            && let Some(status) = child.try_wait().map_err(|_| "wait_failed")?
        {
            guardian.signal(libc::SIGKILL);
            exit_status = Some(status);
        }
        if eof
            && !exit_sent
            && let Some(status) = exit_status.as_ref()
        {
            enqueue(
                &mut output,
                json!({"op":"exited","session_id":session_id,
                "exit_code":status.exit_code(),"signal":status.signal(),"sequence":sequence}),
            )?;
            exit_sent = true;
        }
        if exit_sent && output.is_empty() {
            return Ok(());
        }
        let read_pty = !eof && output.len() < MAX_QUEUE / 2;
        let mut fds = [
            libc::pollfd {
                fd: 0,
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: master,
                events: (if read_pty { libc::POLLIN } else { 0 })
                    | (if input.is_empty() { 0 } else { libc::POLLOUT }),
                revents: 0,
            },
            libc::pollfd {
                fd: 1,
                events: if output.is_empty() { 0 } else { libc::POLLOUT },
                revents: 0,
            },
        ];
        if unsafe { libc::poll(fds.as_mut_ptr(), 3, 100) } < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err("poll_failed");
        }
        if fds[0].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            match process::read(0, &mut buffer) {
                Ok(0) => return Err("control_closed"),
                Ok(n) => control.extend_from_slice(&buffer[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => (),
                Err(_) => return Err("control_closed"),
            }
            while let Some(command) =
                protocol::take_command(&mut control).map_err(|_| "invalid_command")?
            {
                match command {
                    Command::Input {
                        session_id: id,
                        data,
                    } if id == session_id && exit_status.is_none() => {
                        let bytes = STANDARD.decode(data).map_err(|_| "invalid_input")?;
                        if bytes.len() > MAX_INPUT || input.len() + bytes.len() > MAX_INPUT {
                            return Err("input_queue_full");
                        }
                        input.extend(bytes);
                    }
                    Command::Resize {
                        session_id: id,
                        rows,
                        cols,
                    } if id == session_id && protocol::dimensions(rows, cols) => {
                        pair.master
                            .resize(size(rows, cols))
                            .map_err(|_| "resize_failed")?;
                        enqueue(
                            &mut output,
                            json!({"op":"resized","session_id":session_id,"rows":rows,"cols":cols}),
                        )?;
                    }
                    Command::Signal {
                        session_id: id,
                        signal,
                    } if id == session_id && matches!(signal.as_str(), "INT" | "TERM" | "HUP") => {
                        let signal = match signal.as_str() {
                            "INT" => libc::SIGINT,
                            "TERM" => libc::SIGTERM,
                            _ => libc::SIGHUP,
                        };
                        guardian.signal(signal);
                        enqueue(
                            &mut output,
                            json!({"op":"signalled","session_id":session_id}),
                        )?;
                    }
                    Command::Terminate {
                        session_id: id,
                        grace_ms,
                    } if id == session_id && grace_ms <= 2000 => {
                        guardian.signal(libc::SIGTERM);
                        termination = Some(Instant::now() + Duration::from_millis(grace_ms));
                    }
                    Command::Ping { session_id: id } if id == session_id => {
                        enqueue(
                            &mut output,
                            json!({"op":"heartbeat","session_id":session_id,"version":VERSION}),
                        )?;
                    }
                    _ => return Err("invalid_command_order_or_session"),
                }
            }
        }
        if read_pty && fds[1].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            match process::read(master, &mut buffer) {
                Ok(0) => eof = true,
                Ok(n) => {
                    sequence += 1;
                    enqueue(
                        &mut output,
                        json!({"op":"output","session_id":session_id,
                        "sequence":sequence,"data":STANDARD.encode(&buffer[..n])}),
                    )?;
                }
                Err(e) if e.raw_os_error() == Some(libc::EIO) => eof = true,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => (),
                Err(_) => return Err("pty_read_failed"),
            }
        }
        if !input.is_empty() && fds[1].revents & libc::POLLOUT != 0 {
            match process::write(master, input.make_contiguous()) {
                Ok(n) => {
                    input.drain(..n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => (),
                Err(_) => return Err("pty_write_failed"),
            }
        }
        if !output.is_empty() && fds[2].revents & libc::POLLOUT != 0 {
            match process::write(1, output.make_contiguous()) {
                Ok(n) => {
                    output.drain(..n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => (),
                Err(_) => return Err("control_closed"),
            }
        }
        if fds[2].revents & (libc::POLLERR | libc::POLLHUP) != 0 {
            return Err("control_closed");
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 3 && args[1] == "--guard" {
        if let Ok(pgid) = args[2].parse() {
            process::guard(pgid);
        }
        return;
    }
    if args.len() >= 3 && args[1] == "--child" {
        process::bootstrap(&args[2], &args[3..]);
    }
    if args.len() != 1 {
        std::process::exit(2);
    }
    if let Err(code) = run() {
        // No command text, argv, environment, paths, terminal bytes or secrets.
        let _ =
            io::stdout().write_all(&protocol::frame(&json!({"op":"error","code":code})).unwrap());
        let _ = io::stdout().flush();
        let _ = writeln!(io::stderr(), "terminal helper stopped: {code}");
        std::process::exit(2);
    }
}
