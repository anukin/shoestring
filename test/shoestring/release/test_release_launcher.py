"""Hermetic launcher checks: local Python children only, never a release or network."""

import importlib.util
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import unittest

LAUNCHER = Path(__file__).resolve().parents[3] / "priv" / "release_launcher.py"
spec = importlib.util.spec_from_file_location("release_launcher", LAUNCHER)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class ForwardTest(unittest.TestCase):
    def child(self):
        return subprocess.Popen([sys.executable, "-B", "-c", "import sys; sys.stdin.read()"],
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)

    def test_a_running_runtime_receives_the_signal_in_its_group(self):
        process = self.child()
        launcher.forward(process, signal.SIGTERM)
        self.assertEqual(process.wait(timeout=5), -signal.SIGTERM)
        process.stdin.close()

    def test_a_runtime_that_exits_just_after_the_poll_is_left_alone(self):
        process = self.child()
        exited_unreaped(process)
        first_poll_misses_the_exit(process)
        launcher.forward(process, signal.SIGTERM)
        self.assertEqual(process.wait(timeout=5), 0)


class InterruptTest(unittest.TestCase):
    def test_ctrl_c_stops_the_runtime_with_sigterm(self):
        with tempfile.TemporaryDirectory() as root:
            runtime = Path(root) / "runtime"
            runtime.write_text(f"""#!{sys.executable} -B
import signal, sys
if sys.argv[1] == "eval":
    sys.exit(0)
def stopped(signum, _frame):
    print(signal.Signals(signum).name, flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM, stopped)
signal.signal(signal.SIGINT, stopped)
print("ready", flush=True)
signal.pause()
""")
            runtime.chmod(0o755)
            env = dict(os.environ, SHOESTRING_STATE_DIR=str(Path(root) / "state"))
            process = subprocess.Popen([sys.executable, "-B", str(LAUNCHER), str(runtime), "start"],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       env=env, text=True)
            try:
                self.assertEqual(process.stdout.readline(), "ready\n")
                process.send_signal(signal.SIGINT)
                self.assertEqual(process.stdout.readline(), "SIGTERM\n")
                self.assertEqual(process.wait(timeout=10), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()


def exited_unreaped(process):
    """Let the child exit and wait for it without reaping it."""
    if hasattr(os, "waitid"):
        process.stdin.close()
        os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT)
        return
    queue = select.kqueue()
    try:
        exit_event = select.kevent(process.pid, select.KQ_FILTER_PROC,
                                   select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                   select.KQ_NOTE_EXIT)
        queue.control([exit_event], 0)
        process.stdin.close()
        queue.control(None, 1, 5)
    finally:
        queue.close()


def first_poll_misses_the_exit(process):
    """The child exits between forward's poll and its killpg."""
    real_poll = process.poll
    polled = []

    def poll():
        if not polled:
            polled.append(True)
            return None
        return real_poll()

    process.poll = poll


if __name__ == "__main__":
    unittest.main()
