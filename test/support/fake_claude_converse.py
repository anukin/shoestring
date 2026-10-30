#!/usr/bin/env python3
"""Scripted stand-in for Claude Code's conversation mode, for hermetic tests.

`claude -p --input-format stream-json --output-format stream-json` reads one
JSON line per message on stdin and prints stream-json frames. This script
does the same with no model, no network and no credentials, in the frame
shapes Claude Code 2.1.312 printed against a scripted model
(plans/evidence/15-native-chat/):

  - control_request `initialize` -> control_response listing two models
    (`opus`, resolving to claude-opus-5-5, efforts low/medium/high, and
    `sonnet`, efforts low/medium), plus a "Custom model" entry echoing an
    unknown --model, as Claude Code does;
  - control_request `interrupt` -> control_response, and a running turn ends
    with result/error_during_execution;
  - a user message -> system/init, then by its text:
      SAY text      assistant text, result success
      CALL tool     assistant tool_use, user tool_result, assistant "RESULT"
      SLOW ms text  the reply after ms milliseconds (interruptible)
      FAIL          result error_during_execution, is_error true
      THINK         a thinking block, then the text "visible"
      BIG n         one assistant text frame of n bytes
      EXIT n        exits with status n at once
      SPAWN         starts `sleep 300` (pid logged), then replies "spawned"
      REKEY id      reports session `id` from now on (system/init), "ACK"
      anything else assistant text "ACK";
  - EOF on stdin -> exit 0.

When FAKE_CLAUDE_LOG is set, one JSON line records argv, cwd, whether
ANTHROPIC_API_KEY is set, and the mode and content of the --mcp-config
file; SPAWN adds the child's pid.
"""
import json
import os
import subprocess
import sys
import threading
from conversation_memory import Memory

LOG = os.environ.get("FAKE_CLAUDE_LOG")
ARGV = sys.argv[1:]
LOCK = threading.Lock()
MODELS = [
    {"value": "opus", "resolvedModel": "claude-opus-5-5", "displayName": "Opus",
     "supportedEffortLevels": ["low", "medium", "high"]},
    {"value": "sonnet", "resolvedModel": "claude-sonnet-5-5", "displayName": "Sonnet",
     "supportedEffortLevels": ["low", "medium"]},
]


def flag(name):
    return ARGV[ARGV.index(name) + 1] if name in ARGV else None


SESSION = flag("--session-id") or flag("--resume") or "missing-session"
memory = Memory()
SESSION = memory.open(SESSION, flag("--resume") is not None)
if SESSION is None:
    sys.exit(1)


def log(record):
    if LOG:
        with open(LOG, "a") as handle:
            handle.write(json.dumps(record) + "\n")


def emit(frame):
    with LOCK:
        sys.stdout.write(json.dumps(frame) + "\n")
        sys.stdout.flush()


def mcp_record():
    path = flag("--mcp-config")
    if not path or not os.path.isfile(path):
        return {"path": path}
    with open(path) as handle:
        content = json.load(handle)
    return {"path": path, "mode": oct(os.stat(path).st_mode & 0o777), "content": content}


log({"argv": ARGV, "cwd": os.getcwd(), "api_key_set": "ANTHROPIC_API_KEY" in os.environ,
     "mcp": mcp_record()})

turn = {"timer": None, "n": 0}


def text(value):
    emit({"type": "assistant", "session_id": SESSION,
          "message": {"role": "assistant", "content": [{"type": "text", "text": value}]}})


def result(success=True, subtype="success"):
    emit({"type": "result", "subtype": subtype, "is_error": not success, "session_id": SESSION,
          "num_turns": 1, "result": None,
          "usage": {"input_tokens": 12, "output_tokens": 3, "cache_read_input_tokens": 7,
                    "cache_creation_input_tokens": 0}})


def finish_slow(reply):
    with LOCK:
        if turn["timer"] is None:
            return
        turn["timer"] = None
    text(reply)
    result()


def user(message):
    global SESSION
    content = message.get("content")
    body = content if isinstance(content, str) else " ".join(
        b.get("text", "") for b in content if isinstance(b, dict))
    body = body.strip()
    answer = memory.answer(SESSION, body)
    if answer is not None:
        body = "SAY " + answer
    if body.startswith("REKEY "):
        SESSION = body.split(" ", 1)[1]
    emit({"type": "system", "subtype": "init", "session_id": SESSION, "model": flag("--model")})
    verb, _, rest = body.partition(" ")
    if verb == "SAY":
        text(rest)
        result()
    elif verb == "CALL":
        turn["n"] += 1
        call = "toolu_fake%04d" % turn["n"]
        emit({"type": "assistant", "session_id": SESSION, "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": call, "name": rest, "input": {"secret_input": "never forwarded"}}]}})
        emit({"type": "user", "session_id": SESSION, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": call, "content": "tool output never forwarded"}]}})
        text("RESULT")
        result()
    elif verb == "SLOW":
        ms, _, reply = rest.partition(" ")
        timer = threading.Timer(int(ms) / 1000, finish_slow, args=(reply,))
        timer.daemon = True
        turn["timer"] = timer
        timer.start()
    elif verb == "FAIL":
        result(False, "error_during_execution")
    elif verb == "THINK":
        emit({"type": "assistant", "session_id": SESSION, "message": {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "hidden reasoning never forwarded", "signature": "sig"},
            {"type": "text", "text": "visible"}]}})
        result()
    elif verb == "BIG":
        text("x" * int(rest))
        result()
    elif verb == "EXIT":
        os._exit(int(rest))
    elif verb == "SPAWN":
        child = subprocess.Popen(["sleep", "300"])
        log({"spawned": child.pid})
        text("spawned")
        result()
    else:
        text("ACK")
        result()


def control(frame):
    request_id = frame.get("request_id")
    subtype = (frame.get("request") or {}).get("subtype")
    if subtype == "initialize":
        # Like Claude Code 2.1.312, an unknown --model is listed back as a
        # "Custom model" entry.
        models = list(MODELS)
        chosen = flag("--model")
        if chosen and chosen not in [m["value"] for m in MODELS] + [m["resolvedModel"] for m in MODELS]:
            models.append({"value": chosen, "resolvedModel": chosen, "displayName": chosen,
                           "description": "Custom model", "supportedEffortLevels": ["low", "medium", "high"]})
        emit({"type": "control_response", "response": {
            "subtype": "success", "request_id": request_id, "response": {"models": models}}})
    elif subtype == "interrupt":
        with LOCK:
            timer, turn["timer"] = turn["timer"], None
        emit({"type": "control_response", "response": {
            "subtype": "success", "request_id": request_id, "response": {"still_queued": []}}})
        if timer is not None:
            timer.cancel()
            result(False, "error_during_execution")


for line in sys.stdin:
    try:
        frame = json.loads(line)
    except ValueError:
        continue
    if frame.get("type") == "control_request":
        control(frame)
    elif frame.get("type") == "user":
        user(frame.get("message") or {})
sys.exit(0)
