#![cfg(all(target_os = "macos", target_arch = "aarch64"))]
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

struct Helper {
    child: Child,
    events: Receiver<Value>,
}
impl Helper {
    fn new() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_shoestring-terminal"))
            .env("SHOESTRING_TERMINAL_UNAPPROVED", "synthetic-private-value")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut stdout = child.stdout.take().unwrap();
        let (tx, events) = mpsc::sync_channel(16);
        std::thread::spawn(move || {
            loop {
                let mut header = [0u8; 4];
                if stdout.read_exact(&mut header).is_err() {
                    break;
                }
                let size = u32::from_be_bytes(header) as usize;
                assert!(size <= 65_536);
                let mut body = vec![0u8; size];
                if stdout.read_exact(&mut body).is_err() {
                    break;
                }
                let value = serde_json::from_slice(&body).unwrap();
                if tx.send(value).is_err() {
                    break;
                }
            }
        });
        Self { child, events }
    }
    fn send(&mut self, v: Value) {
        let body = serde_json::to_vec(&v).unwrap();
        let stdin = self.child.stdin.as_mut().unwrap();
        stdin.write_all(&(body.len() as u32).to_be_bytes()).unwrap();
        stdin.write_all(&body).unwrap();
    }
    fn event(&self) -> Value {
        self.events
            .recv_timeout(Duration::from_secs(5))
            .expect("helper event deadline")
    }
    fn spawn(&mut self) -> i32 {
        self.send(json!({"op":"hello","version":1}));
        assert_eq!(self.event()["version"], 1);
        let python = Command::new("/usr/bin/which")
            .arg("python3")
            .output()
            .unwrap();
        let python = String::from_utf8(python.stdout).unwrap().trim().to_string();
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .unwrap();
        self.send(json!({"op":"spawn","request_id":"request","session_id":"fixture",
            "executable":python,"argv":[root.join("priv/terminal/fixture.py")],
            "cwd":root,"env":{"PATH":std::env::var("PATH").unwrap(),"TERM":"xterm-256color","LANG":"en_US.UTF-8"},
            "rows":24,"cols":80}));
        let spawned = self.event();
        assert_eq!(spawned["op"], "spawned", "{spawned:?}");
        let pid = spawned["pid"].as_i64().unwrap() as i32;
        assert_eq!(spawned["process_group"], pid);
        self.until_bytes(b"SIZE 24 80");
        pid
    }
    fn input(&mut self, data: &[u8]) {
        self.send(json!({"op":"input","session_id":"fixture","data":STANDARD.encode(data)}));
    }
    fn until_bytes(&self, expected: &[u8]) -> Vec<u8> {
        let mut output = Vec::new();
        for _ in 0..128 {
            let event = self.event();
            if event["op"] == "output" {
                output.extend(STANDARD.decode(event["data"].as_str().unwrap()).unwrap());
                if output.windows(expected.len()).any(|v| v == expected) {
                    return output;
                }
            } else {
                assert_ne!(event["op"], "error", "{event:?}");
            }
        }
        panic!("output limit reached");
    }
}

#[test]
fn user_identity_survives_without_unapproved_inherited_environment() {
    let mut h = Helper::new();
    h.send(json!({"op":"hello","version":1}));
    assert_eq!(h.event()["version"], 1);
    h.send(json!({"op":"spawn","request_id":"request","session_id":"fixture",
        "executable":"/bin/sh",
        "argv":["-c", "printf 'USER=%s\\nUNAPPROVED=%s\\n' \"$USER\" \"${SHOESTRING_TERMINAL_UNAPPROVED:-absent}\""],
        "cwd":std::env::temp_dir().canonicalize().unwrap(),
        "env":{"USER":"terminal-fixture-user","PATH":"/usr/bin:/bin","TERM":"xterm-256color"},
        "rows":24,"cols":80}));
    let spawned = h.event();
    assert_eq!(spawned["op"], "spawned", "{spawned:?}");
    let output = h.until_bytes(b"UNAPPROVED=absent");
    assert!(
        output
            .windows(b"USER=terminal-fixture-user".len())
            .any(|v| v == b"USER=terminal-fixture-user")
    );
    assert!(
        !output
            .windows(b"synthetic-private-value".len())
            .any(|v| v == b"synthetic-private-value")
    );
    loop {
        let event = h.event();
        if event["op"] == "exited" {
            assert_eq!(event["exit_code"], 0);
            break;
        }
    }
    assert!(h.child.wait().unwrap().success());
}
impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct ExitWatch(i32);
impl ExitWatch {
    fn new(pid: i32) -> Self {
        let fd = unsafe { libc::kqueue() };
        assert!(fd >= 0);
        let event = libc::kevent {
            ident: pid as usize,
            filter: libc::EVFILT_PROC,
            flags: libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
            fflags: libc::NOTE_EXIT,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        assert_eq!(
            unsafe { libc::kevent(fd, &event, 1, std::ptr::null_mut(), 0, std::ptr::null()) },
            0
        );
        Self(fd)
    }
    fn assert_exit(self) {
        let timeout = libc::timespec {
            tv_sec: 5,
            tv_nsec: 0,
        };
        let mut event = std::mem::MaybeUninit::<libc::kevent>::uninit();
        assert_eq!(
            unsafe { libc::kevent(self.0, std::ptr::null(), 0, event.as_mut_ptr(), 1, &timeout) },
            1
        );
        assert_ne!(unsafe { event.assume_init() }.fflags & libc::NOTE_EXIT, 0);
    }
}
impl Drop for ExitWatch {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.0);
        }
    }
}

#[test]
fn real_tui_round_trips_binary_unicode_resize_and_ctrl_c() {
    let mut h = Helper::new();
    h.spawn();
    h.input("héllo 世界\x1b[200~paste\x1b[201~".as_bytes());
    h.until_bytes("ECHO héllo 世界\x1b[200~paste\x1b[201~".as_bytes());
    h.input(b"BINARY\r");
    h.until_bytes(&(0..=255).collect::<Vec<u8>>());
    h.send(json!({"op":"resize","session_id":"fixture","rows":40,"cols":120}));
    h.until_bytes(b"SIZE 40 120");
    h.send(json!({"op":"signal","session_id":"fixture","signal":"INT"}));
    h.until_bytes(b"INTERRUPT");
    h.input(b"EXIT\r");
    loop {
        let e = h.event();
        if e["op"] == "exited" {
            assert_eq!(e["exit_code"], 0);
            assert!(e["signal"].is_null());
            break;
        }
    }
    assert!(h.child.wait().unwrap().success());
}

#[test]
fn termination_and_helper_death_kill_owned_descendants() {
    for crash in [false, true] {
        let mut h = Helper::new();
        let pid = h.spawn();
        h.input(b"FORK\r");
        let output = h.until_bytes(b"DESCENDANT ");
        let text = String::from_utf8(output).unwrap();
        let descendant = text
            .split("DESCENDANT ")
            .nth(1)
            .unwrap()
            .split_whitespace()
            .next()
            .unwrap()
            .parse()
            .unwrap();
        let child_exit = ExitWatch::new(pid);
        let descendant_exit = ExitWatch::new(descendant);
        if crash {
            h.child.kill().unwrap();
        } else {
            h.send(json!({"op":"terminate","session_id":"fixture","grace_ms":0}));
        }
        child_exit.assert_exit();
        descendant_exit.assert_exit();
    }
}

#[test]
fn slow_consumer_and_control_eof_do_not_leak_the_child() {
    let mut h = Helper::new();
    let pid = h.spawn();
    let exit = ExitWatch::new(pid);
    h.input(b"FLOOD\r");
    h.until_bytes(b"xxxxxxxx");
    drop(h.child.stdin.take());
    exit.assert_exit();
}

#[test]
fn incompatible_version_and_wrong_session_fail_closed() {
    let mut h = Helper::new();
    h.send(json!({"op":"hello","version":99}));
    assert_eq!(
        h.event(),
        json!({"op":"error","code":"incompatible_version"})
    );
    assert!(!h.child.wait().unwrap().success());
    let mut h = Helper::new();
    let pid = h.spawn();
    let exit = ExitWatch::new(pid);
    h.send(json!({"op":"input","session_id":"wrong","data":"YQ=="}));
    assert_eq!(h.event()["code"], "invalid_command_order_or_session");
    exit.assert_exit();
}
