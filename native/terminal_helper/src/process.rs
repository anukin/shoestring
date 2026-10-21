//! One guardian watches only this helper's owned process group. Closing its
//! pipe (including SIGKILL/helper crash) kills that group; no global sweep.
use std::io::{self, Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};

pub struct Guardian {
    process: Child,
    pipe: Option<ChildStdin>,
    pub pgid: i32,
}

impl Guardian {
    pub fn start(pgid: i32) -> io::Result<Self> {
        if pgid <= 1 {
            return Err(io::Error::other("invalid_group"));
        }
        let mut process = Command::new(std::env::current_exe()?)
            .args(["--guard", &pgid.to_string()])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let pipe = process.stdin.take();
        Ok(Self {
            process,
            pipe,
            pgid,
        })
    }

    pub fn signal(&self, signal: i32) {
        // Negative PID addresses the owned group, never the helper or host group.
        unsafe {
            libc::kill(-self.pgid, signal);
        }
    }
}

impl Drop for Guardian {
    fn drop(&mut self) {
        self.signal(libc::SIGKILL);
        if let Some(mut pipe) = self.pipe.take() {
            let _ = pipe.write_all(b"D");
        }
        let _ = self.process.wait();
    }
}

pub fn guard(pgid: i32) {
    if pgid <= 1 {
        return;
    }
    let mut b = [0u8; 1];
    if !matches!(io::stdin().read_exact(&mut b), Ok(())) || b != *b"D" {
        unsafe {
            libc::kill(-pgid, libc::SIGKILL);
        }
    }
}

pub fn nonblocking(fd: i32) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub fn read(fd: i32, bytes: &mut [u8]) -> io::Result<usize> {
    let size = unsafe { libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len()) };
    if size < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(size as usize)
    }
}

pub fn write(fd: i32, bytes: &[u8]) -> io::Result<usize> {
    let size = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
    if size < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(size as usize)
    }
}

// The PTY child is initially this tiny bootstrap, which has default signal
// handlers and cannot launch the provider before the guardian is installed.
// If its helper dies during spawn, closing the master hangs up the bootstrap.
pub fn bootstrap(executable: &str, args: &[String]) -> ! {
    use std::os::unix::process::CommandExt;
    let mut original = std::mem::MaybeUninit::<libc::termios>::uninit();
    if unsafe { libc::tcgetattr(0, original.as_mut_ptr()) } != 0 {
        std::process::exit(2);
    }
    let original = unsafe { original.assume_init() };
    let mut raw = original;
    unsafe {
        libc::cfmakeraw(&mut raw);
    }
    if unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw) } != 0 {
        std::process::exit(2);
    }
    if io::stdout().write_all(b"PTYREADY").is_err() {
        std::process::exit(2);
    }
    if io::stdout().flush().is_err() {
        std::process::exit(2);
    }
    let mut ack = [0u8; 1];
    if io::stdin().read_exact(&mut ack).is_err() || ack != [0] {
        std::process::exit(2);
    }
    if unsafe { libc::tcsetattr(0, libc::TCSANOW, &original) } != 0 {
        std::process::exit(2);
    }
    let _ = Command::new(executable).args(args).exec();
    std::process::exit(2);
}

pub fn await_bootstrap(master: i32) -> io::Result<()> {
    let mut ready = [0u8; 8];
    let mut received = 0;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while received < ready.len() {
        if std::time::Instant::now() >= deadline {
            return Err(io::Error::other("bootstrap_timeout"));
        }
        let mut fd = libc::pollfd {
            fd: master,
            events: libc::POLLIN,
            revents: 0,
        };
        if unsafe { libc::poll(&mut fd, 1, 100) } <= 0 {
            continue;
        }
        let n = read(master, &mut ready[received..])?;
        if n == 0 {
            return Err(io::Error::other("bootstrap_closed"));
        }
        received += n;
    }
    if ready != *b"PTYREADY" {
        return Err(io::Error::other("invalid_bootstrap"));
    }
    Ok(())
}
