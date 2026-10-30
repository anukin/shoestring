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


class Runtime:
    """The runtime child of the moment, and a stop once one is asked for.

    A stop is remembered: one that arrives between two launches prevents the
    next, and one that arrives while a child is being spawned reaches that
    child as soon as it exists.
    """

    def __init__(self):
        self.child = None
        self.stop = None

    def request_stop(self, signum):
        self.stop = signum
        forward(self.child, signum)

    def run(self, argv, descriptors):
        if self.stop is not None:
            return None
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, start_new_session=True, pass_fds=descriptors)
        # Stops are held back while the child is published, so one that came
        # during the spawn is forwarded here and a later one by the handler.
        held = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            self.child = child
            if self.stop is not None:
                forward(child, self.stop)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, held)
        return child.wait()


def main():
    program, action = sys.argv[1:]
    root = pathlib.Path(os.environ.get("SHOESTRING_STATE_DIR", str(pathlib.Path.home() / "Library/Application Support/Shoestring")))
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    descriptor = os.open(root / ".service-lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit("State is owned by a running Shoestring process. Stop it explicitly before upgrading or starting another instance.")
    runtime = Runtime()
    signal.signal(signal.SIGTERM, lambda signum, _frame: runtime.request_stop(signum))
    # Ctrl-C stops the runtime as SIGTERM does: a SIGINT would open the
    # runtime's BREAK menu, which reads EOF from /dev/null and halts at once.
    signal.signal(signal.SIGINT, lambda _signum, _frame: runtime.request_stop(signal.SIGTERM))
    status = runtime.run([program, "eval", "Shoestring.Release.initialize()"], (descriptor,))
    if status is None:
        return 0
    if status != 0 or action == "init":
        return status
    os.environ["PHX_SERVER"] = "true"
    status = runtime.run([program, "start"], (descriptor,))
    if status is None:
        print("Stopped before the service started.", file=sys.stderr)
        return 0
    return status


if __name__ == "__main__":
    sys.exit(main())
