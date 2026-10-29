"""Hermetic launcher checks: local Python children only, never a release or network."""

import importlib.util
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
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
