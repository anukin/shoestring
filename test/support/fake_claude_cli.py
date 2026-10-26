#!/usr/bin/env python3
"""Scripted stand-in for `claude --print --output-format stream-json`.

Used only by hermetic tests: it starts no model, opens no network connection
and reads no credentials. Like a worker that did its job, it makes `add()` in
`calc.py` (in its working directory, the run's worktree) return the sum of
its arguments, commits that change, and prints the stream-json frames a
headless Claude run prints: `system`/`init`, one `assistant` text message and
a `result` with token usage. Its argv is appended as one JSON line to
FAKE_CLAUDE_LOG when that is set.
"""
import json
import os
import subprocess
import sys

SESSION = "aaaaaaaa-0000-4000-a000-0000000000c1"
LOG = os.environ.get("FAKE_CLAUDE_LOG")


def emit(frame):
    sys.stdout.write(json.dumps(frame) + "\n")
    sys.stdout.flush()


if LOG:
    with open(LOG, "a") as handle:
        handle.write(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd()}) + "\n")

model = sys.argv[sys.argv.index("--model") + 1] if "--model" in sys.argv else None
emit({"type": "system", "subtype": "init", "session_id": SESSION, "model": model})

with open("calc.py") as handle:
    source = handle.read()

with open("calc.py", "w") as handle:
    handle.write(source.replace("raise NotImplementedError", "return a + b"))

subprocess.run(["git", "add", "calc.py"], check=True)
subprocess.run(
    [
        "git",
        "-c",
        "user.name=Fake Worker",
        "-c",
        "user.email=worker@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-q",
        "-m",
        "Make add return the sum of its arguments",
    ],
    check=True,
)

emit(
    {
        "type": "assistant",
        "session_id": SESSION,
        "message": {
            "id": "msg_000000000000000000000001",
            "content": [{"type": "text", "text": "add() now returns a + b; committed."}],
        },
    }
)

emit(
    {
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "terminal_reason": "completed",
        "result": "add() now returns a + b; committed.",
        "num_turns": 3,
        "duration_ms": 4200,
        "total_cost_usd": 0.0123,
        "usage": {
            "input_tokens": 1200,
            "output_tokens": 340,
            "cache_read_input_tokens": 5000,
            "cache_creation_input_tokens": 800,
        },
        "session_id": SESSION,
    }
)
