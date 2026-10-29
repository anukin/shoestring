#!/usr/bin/env python3
"""A local owned group with a descendant; explicit TERM reaps that descendant."""
import os
import signal
import socket
import subprocess
import sys

child = subprocess.Popen([sys.executable, "-c", "import signal; signal.pause()"], stdin=subprocess.DEVNULL)

def stop(signum, frame):
    # killpg delivers the signal to both processes; wait proves child reaping.
    child.wait(timeout=5)
    sys.exit(0)

signal.signal(signal.SIGTERM, stop)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as ready:
    ready.sendto(f"{os.getpid()} {child.pid}".encode(), ("127.0.0.1", int(sys.argv[1])))
signal.pause()
