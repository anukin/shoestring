#!/usr/bin/env python3
"""Foreground state ownership. Persistent lock file, OS advisory lock, no expiry or deletion."""
import fcntl
import os
import pathlib
import signal
import subprocess
import sys


def forward(child, signum):
    if child is not None and child.poll() is None:
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass
        except PermissionError:
            # macOS refuses to signal a group whose only member exited after
            # the poll above and is not yet reaped: nothing is left to signal.
            pass


def main():
    runtime, action = sys.argv[1:]
    root = pathlib.Path(os.environ.get("SHOESTRING_STATE_DIR", str(pathlib.Path.home() / "Library/Application Support/Shoestring")))
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    descriptor = os.open(root / ".service-lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit("State is owned by a running Shoestring process. Stop it explicitly before upgrading or starting another instance.")
    child = None
    signal.signal(signal.SIGTERM, lambda signum, _frame: forward(child, signum))
    signal.signal(signal.SIGINT, lambda signum, _frame: forward(child, signum))
    child = subprocess.Popen([runtime, "eval", "Shoestring.Release.initialize()"], stdin=subprocess.DEVNULL, start_new_session=True, pass_fds=(descriptor,))
    status = child.wait()
    if status != 0 or action == "init":
        return status
    os.environ["PHX_SERVER"] = "true"
    child = subprocess.Popen([runtime, "start"], stdin=subprocess.DEVNULL, start_new_session=True, pass_fds=(descriptor,))
    return child.wait()


if __name__ == "__main__":
    sys.exit(main())
