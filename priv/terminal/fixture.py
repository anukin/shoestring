"""Harmless real TUI: no provider, network, repository writes or shell."""
import os
import signal
import struct
import termios
import tty


def write(data):
    while data:
        data = data[os.write(1, data):]


def dimensions(*_):
    rows, cols, _, _ = struct.unpack("HHHH", __import__("fcntl").ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
    write(f"SIZE {rows} {cols}\r\n".encode())


tty.setraw(0)
signal.signal(signal.SIGWINCH, dimensions)
signal.signal(signal.SIGINT, lambda *_: write(b"INTERRUPT\r\n"))
write(b"\x1b[?1049h\x1b[?2004h\x1b[32mShoestring fixture terminal\x1b[0m\r\n")
write(f"READY {os.getpid()}\r\n".encode())
dimensions()
while True:
    data = os.read(0, 8192)
    if not data:
        break
    if data == b"EXIT\r":
        write(b"\x1b[?2004l\x1b[?1049l")
        break
    if data == b"BINARY\r":
        write(bytes(range(256)))
    elif data == b"FORK\r":
        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            while True:
                signal.pause()
        write(f"DESCENDANT {child}\r\n".encode())
    elif data == b"FLOOD\r":
        while True:
            write(b"x" * 4096)
    else:
        write(b"ECHO " + data)
