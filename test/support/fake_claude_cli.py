#!/usr/bin/env python3
"""Scripted stand-in for `claude --print --output-format stream-json`.

Used only by hermetic tests: it starts no model, opens no network connection
and reads no credentials. Like a worker that did its job, it makes `add()` in
`calc.py` (in its working directory, the run's worktree) return the sum of
its arguments (or, when add() already does, adds sub()), commits that
change, and prints the stream-json frames a
headless Claude run prints, in the 2.1.310 order: `system`/`init`, one
`assistant` text message, a `rate_limit_event` (Claude's own usage report)
and a `result` with token usage. Its argv is appended as one JSON line to
FAKE_CLAUDE_LOG when that is set.

FAKE_CLAUDE_SCENARIO=batch appends a line to the first file its task contract
names and commits it. FAKE_CLAUDE_SCENARIO=limit instead changes nothing and stops at the usage
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

if SCENARIO == "batch":
    # A batch task changes the first file its task contract names (the
    # prompt's first line is the task, then its contract as JSON); a task
    # that names none changes calc.py.
    prompt = sys.argv[-1]
    contract, _ = json.JSONDecoder().raw_decode(prompt.split("\n", 1)[1])
    target = ((contract["task"].get("hints") or {}).get("files") or ["calc.py"])[0]
    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    with open(target, "a") as handle:
        handle.write("# changed by " + contract["task"]["id"] + "\n")
    subprocess.run(["git", "add", target], check=True)
    subprocess.run(
        ["git", "-c", "user.name=Fake Worker", "-c", "user.email=worker@example.invalid",
         "-c", "commit.gpgsign=false", "commit", "-q", "-m", "Change " + target],
        check=True,
    )
    emit({"type": "assistant", "session_id": SESSION, "message": {
        "id": "msg_000000000000000000000002",
        "content": [{"type": "text", "text": "Changed " + target + "."}]}})
    usage(0.2, "allowed")
    emit({"type": "result", "subtype": "success", "is_error": False,
          "terminal_reason": "completed", "result": "Changed " + target + ".", "num_turns": 1,
          "duration_ms": 1000, "total_cost_usd": 0.001,
          "usage": {"input_tokens": 100, "output_tokens": 10,
                    "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
          "session_id": SESSION})
    sys.exit(0)

with open("calc.py") as handle:
    source = handle.read()

# A worker that starts where an earlier one finished (a dependent dispatch)
# finds add() done and adds sub() instead.
followed = "return a + b" in source
with open("calc.py", "w") as handle:
    if followed:
        handle.write(source + "\n\ndef sub(a, b):\n    return a - b\n")
    else:
        handle.write(source.replace("raise NotImplementedError", "return a + b"))

# FAKE_CLAUDE_LESSON: propose a lesson the way an IMPLEMENT worker is told to,
# in its worktree, and stage everything as a careless worker would; the
# private storage's exclusion keeps it out of the commit.
LESSON = os.environ.get("FAKE_CLAUDE_LESSON")
if LESSON:
    os.makedirs(".shoestring", exist_ok=True)
    with open(".shoestring/lessons.md", "w") as handle:
        handle.write("- " + LESSON + "\n")
    subprocess.run(["git", "add", "-A"], check=True)

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
        "Add sub" if followed else "Make add return the sum of its arguments",
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
