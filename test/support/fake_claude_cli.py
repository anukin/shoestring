#!/usr/bin/env python3
"""Scripted stand-in for `claude --print --output-format stream-json`.

Used only by hermetic tests: it starts no model, opens no network connection
and reads no credentials. Like a worker that did its job, it makes `add()` in
`calc.py` (in its working directory, the run's worktree) return the sum of
its arguments, commits that change, and prints the stream-json frames a
headless Claude run prints, in the 2.1.310 order: `system`/`init`, one
`assistant` text message, a `rate_limit_event` (Claude's own usage report)
and a `result` with token usage. Its argv is appended as one JSON line to
FAKE_CLAUDE_LOG when that is set.

FAKE_CLAUDE_SCENARIO=limit instead changes nothing and stops at the usage
limit: a `rate_limit_event` whose five-hour window is full and rejected,
then an error `result`. SYNTHETIC: Claude's real limit output has never been
captured; the result copies the captured auth failure's shape
(`is_error: true`, `terminal_reason: "api_error"`).
"""
import json
import os
import subprocess
import sys
import time

SESSION = "aaaaaaaa-0000-4000-a000-0000000000c1"
LOG = os.environ.get("FAKE_CLAUDE_LOG")
SCENARIO = os.environ.get("FAKE_CLAUDE_SCENARIO", "complete")


def emit(frame):
    sys.stdout.write(json.dumps(frame) + "\n")
    sys.stdout.flush()


if LOG:
    with open(LOG, "a") as handle:
        handle.write(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd()}) + "\n")



def usage(five_hour, status):
    resets = int(time.time()) + 3600
    emit(
        {
            "type": "rate_limit_event",
            "session_id": SESSION,
            "rate_limit_info": {
                "status": status,
                "rateLimitType": "five_hour",
                "resetsAt": resets,
                "unifiedWindows": {
                    "five_hour": {"utilization": five_hour, "resetsAt": resets, "status": status},
                    "seven_day": {"utilization": 0.1, "resetsAt": resets + 86400, "status": "allowed"},
                },
            },
        }
    )


model = sys.argv[sys.argv.index("--model") + 1] if "--model" in sys.argv else None
emit({"type": "system", "subtype": "init", "session_id": SESSION, "model": model})

if SCENARIO == "limit":
    # A real CLI takes at least this long to start; a process that is gone
    # before Shoestring verifies its process group is refused at launch.
    time.sleep(1)
    usage(1.0, "rejected")
    emit(
        {
            "type": "result",
            "subtype": "success",
            "is_error": True,
            "terminal_reason": "api_error",
            "result": "Claude usage limit reached.",
            "num_turns": 1,
            "session_id": SESSION,
        }
    )
    sys.exit(1)

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

usage(0.2, "allowed")

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
