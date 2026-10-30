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
        with launched(STOPPABLE_START) as process:
            self.assertEqual(process.stdout.readline(), "ready\n")
            process.send_signal(signal.SIGINT)
            self.assertEqual(process.stdout.readline(), "SIGTERM\n")
            self.assertEqual(process.wait(timeout=10), 0)

    def test_a_stop_as_initialization_finishes_prevents_the_start(self):
        # Initialization has done its work when the stop arrives and exits 0
        # anyway: the stop must still keep the main runtime from launching.
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum.name), launched(FINISHING_INIT) as process:
                self.assertEqual(process.stdout.readline(), "initializing\n")
                process.send_signal(signum)
                output, errors = process.communicate(timeout=10)
                self.assertEqual(output, "init SIGTERM\n")
                self.assertIn("Stopped before the service started.", errors)
                self.assertEqual(process.returncode, 0)


class StopRequestTest(unittest.TestCase):
    """The stop handler and spawn, driven in this process with stand-in children."""

    def setUp(self):
        self.children = []
        self.runtime = launcher.Runtime()
        real_popen = launcher.subprocess.Popen

        def popen(argv, **options):
            # A stand-in that is never signalled gives up after 5 s with SIGALRM.
            child = real_popen([sys.executable, "-B", "-c", "import signal; signal.alarm(5); signal.pause()"],
                               stdout=subprocess.DEVNULL, **options)
            self.children.append(child)
            if argv == ["start"]:
                # The stop arrives after the spawn but before the launcher holds the child.
                self.runtime.request_stop(signal.SIGTERM)
            return child

        launcher.subprocess.Popen = popen
        self.addCleanup(setattr, launcher.subprocess, "Popen", real_popen)

    def test_a_stop_during_the_spawn_reaches_the_new_child(self):
        self.assertEqual(self.runtime.run(["start"], ()), -signal.SIGTERM)
        self.assertEqual(len(self.children), 1)

    def test_a_remembered_stop_launches_nothing_more(self):
        self.runtime.request_stop(signal.SIGTERM)
        self.assertIsNone(self.runtime.run(["eval"], ()))
        self.assertEqual(self.children, [])


STOPPABLE_START = """
if sys.argv[1] == "eval":
    sys.exit(0)
def stopped(signum, _frame):
    print(signal.Signals(signum).name, flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM, stopped)
signal.signal(signal.SIGINT, stopped)
print("ready", flush=True)
signal.pause()
"""

FINISHING_INIT = """
if sys.argv[1] != "eval":
    print("started", flush=True)
    sys.exit(0)
def finished(signum, _frame):
    print("init", signal.Signals(signum).name, flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM, finished)
print("initializing", flush=True)
signal.pause()
"""


class launched:
    """The real launcher over a stand-in runtime, in a scratch state directory."""

    def __init__(self, body):
        self.body = body

    def __enter__(self):
        self.root = tempfile.TemporaryDirectory()
        runtime = Path(self.root.name) / "runtime"
        runtime.write_text(f"#!{sys.executable} -B\nimport signal, sys\n{self.body}")
        runtime.chmod(0o755)
        env = dict(os.environ, SHOESTRING_STATE_DIR=str(Path(self.root.name) / "state"))
        self.process = subprocess.Popen([sys.executable, "-B", str(LAUNCHER), str(runtime), "start"],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env, text=True)
        return self.process

    def __exit__(self, *_exc):
        if self.process.poll() is None:
            self.process.kill()
        self.process.communicate()
        self.root.cleanup()


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
