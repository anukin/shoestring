"""Ask one harness CLI for its model list over its own protocol. No prompt is sent.

usage: python3 -I probe.py codex|opencode|claude OUT_JSONL CWD
"""
import json
import os
import select
import signal
import subprocess
import sys
import time

harness, out_path, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
TIMEOUT = 45

COMMANDS = {
    "codex": ["codex", "app-server", "--stdio"],
    "opencode": ["opencode", "acp"],
    "claude": [
        "claude", "--print", "--verbose",
        "--input-format", "stream-json", "--output-format", "stream-json",
    ],
}

proc = subprocess.Popen(
    COMMANDS[harness], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, start_new_session=True,
)
log = open(out_path, "w")
buffer = b""
deadline = time.time() + TIMEOUT


def send(frame):
    log.write(json.dumps({"sent": frame}) + "\n")
    proc.stdin.write((json.dumps(frame) + "\n").encode())
    proc.stdin.flush()


def receive(predicate):
    """Read frames until one satisfies predicate; return it, or None on timeout/EOF."""
    global buffer
    while time.time() < deadline:
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                frame = json.loads(line)
            except ValueError:
                log.write(json.dumps({"unparsed": line.decode(errors="replace")[:2000]}) + "\n")
                continue
            log.write(json.dumps({"received": frame}) + "\n")
            if predicate(frame):
                return frame
        ready, _, _ = select.select([proc.stdout], [], [], 1.0)
        if ready:
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                return None
            buffer += chunk
    return None


result = None
try:
    if harness == "codex":
        send({"method": "initialize", "id": 1, "params": {"clientInfo": {
            "name": "shoestring_model_probe", "title": "Shoestring model probe", "version": "0.1.0"}}})
        if receive(lambda f: f.get("id") == 1):
            send({"method": "initialized", "params": {}})
            send({"method": "model/list", "id": 2, "params": {"includeHidden": False}})
            result = receive(lambda f: f.get("id") == 2)
    elif harness == "opencode":
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
            "clientInfo": {"name": "shoestring-model-probe", "version": "1"}}})
        if receive(lambda f: f.get("id") == 1):
            send({"jsonrpc": "2.0", "id": 2, "method": "session/new",
                  "params": {"cwd": cwd, "mcpServers": []}})
            result = receive(lambda f: f.get("id") == 2)
    elif harness == "claude":
        send({"type": "control_request", "request_id": "probe-1",
              "request": {"subtype": "initialize"}})
        result = receive(lambda f: f.get("type") == "control_response")
finally:
    try:
        proc.stdin.close()
    except Exception:
        pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
    stderr = proc.stderr.read().decode(errors="replace")
    log.write(json.dumps({"exit": proc.returncode, "stderr_tail": stderr[-2000:]}) + "\n")
    log.close()

print(json.dumps({"harness": harness, "got_result": result is not None, "exit": proc.returncode}))
