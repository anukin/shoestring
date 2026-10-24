#!/usr/bin/env python3
"""Scripted stand-in for `opencode acp` (Agent Client Protocol over stdio).

Used only by hermetic tests: it starts no model, opens no network connection
and reads no credentials. The scenario comes from FAKE_OPENCODE_SCENARIO;
every frame received is appended as one JSON line to FAKE_OPENCODE_LOG.

Like opencode 2.0.31 it starts a child that leads its own process group and
exits when its parent goes away (the real `opencode serve --stdio`). The
`hang` scenario also leaves a `sleep` in yet another group that would
outlive the parent unless the caller reaps the tree.
"""
import json
import os
import subprocess
import sys

SCENARIO = os.environ.get("FAKE_OPENCODE_SCENARIO", "complete")
LOG = os.environ.get("FAKE_OPENCODE_LOG")
SESSION = "ses_000000000000000000000001"

child = subprocess.Popen(
    [sys.executable, "-c", "import sys; sys.stdin.read()"],
    stdin=subprocess.PIPE,
    start_new_session=True,
)


def log(entry):
    if LOG:
        with open(LOG, "a") as handle:
            handle.write(json.dumps(entry) + "\n")


def send(obj):
    try:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        # The session closed or reaped us mid-write; that is the test's point.
        os._exit(0)


def update(payload):
    send({"jsonrpc": "2.0", "method": "session/update",
          "params": {"sessionId": SESSION, "update": payload}})


def result(rid, value):
    send({"jsonrpc": "2.0", "id": rid, "result": value})


def error(rid, code, message):
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message, "data": {}}})


def options(model="opencode-go/default-model"):
    efforts = ["none", "low", "medium", "high", "default"] if model.startswith("opencode/") else ["low", "high", "default"]
    return [
        {"id": "model", "category": "model", "type": "select", "currentValue": model,
         "options": [{"value": v, "name": v} for v in ["opencode/test-model", "openai/test-model", "opencode-go/default-model"]]},
        {"id": "effort", "category": "thought_level", "type": "select", "currentValue": "default",
         "options": [{"value": v, "name": v} for v in efforts]},
        {"id": "mode", "category": "mode", "type": "select", "currentValue": "build",
         "options": [{"value": "build", "name": "build"}, {"value": "plan", "name": "plan"}]},
    ]


model = "opencode-go/default-model"
prompt_id = None
next_id = 1000

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    frame = json.loads(line)
    log(frame)
    method, rid, params = frame.get("method"), frame.get("id"), frame.get("params") or {}

    if method is None and rid is not None:
        # The client's answer to our permission request.
        outcome = (frame.get("result") or {}).get("outcome") or {}
        update({"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "permission " + outcome.get("outcome", "?") + " " + str(outcome.get("optionId"))}})
        result(prompt_id, {"stopReason": "end_turn"})
        continue

    if method == "initialize":
        version = 2 if SCENARIO == "protocol" else 1
        result(rid, {"protocolVersion": version, "agentCapabilities": {"loadSession": True},
                     "authMethods": [], "agentInfo": {"name": "OpenCode", "version": "2.0.31"}})
    elif method == "session/new":
        result(rid, {"sessionId": SESSION, "configOptions": options()})
    elif method == "session/resume":
        result(rid, {"configOptions": options(model)})
    elif method == "session/set_config_option":
        if params.get("configId") == "model":
            if SCENARIO == "bad_model" or params.get("value") not in ["opencode/test-model", "openai/test-model"]:
                error(rid, -32602, "Invalid params: model not found: " + str(params.get("value")))
                continue
            model = params["value"]
        result(rid, {"configOptions": options(model)})
    elif method == "session/prompt":
        prompt_id = rid
        if SCENARIO == "auth":
            error(rid, -32000, "Authentication required: provider authentication required")
        elif SCENARIO == "hang":
            sleeper = subprocess.Popen(["sleep", "300"], start_new_session=True)
            log({"sleeper_pid": sleeper.pid, "child_pid": child.pid})
            update({"sessionUpdate": "tool_call", "toolCallId": "call_1", "kind": "execute",
                    "status": "in_progress", "title": "sleep", "rawInput": {"command": "sleep 300"}})
        elif SCENARIO == "permission":
            next_id += 1
            send({"jsonrpc": "2.0", "id": next_id, "method": "session/request_permission",
                  "params": {"sessionId": SESSION,
                             "toolCall": {"toolCallId": "call_1", "kind": "edit", "title": "write outside"},
                             "options": [{"optionId": "once", "kind": "allow_once", "name": "Allow"},
                                         {"optionId": "always", "kind": "allow_always", "name": "Always"},
                                         {"optionId": "reject", "kind": "reject_once", "name": "Reject"}]}})
        elif SCENARIO == "oversized":
            send("x" * 70000)
        elif SCENARIO == "refusal":
            result(rid, {"stopReason": "refusal"})
        else:
            update({"sessionUpdate": "available_commands_update", "availableCommands": []})
            update({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "private reasoning"}})
            update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Working "}})
            update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "in /Users/someone/x"}})
            update({"sessionUpdate": "tool_call", "toolCallId": "call_1", "kind": "execute", "status": "pending",
                    "title": "printf", "rawInput": {"command": "printf hello"}})
            update({"sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "in_progress"})
            update({"sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "completed"})
            update({"sessionUpdate": "tool_call", "toolCallId": "call_2", "kind": "edit", "status": "pending",
                    "title": "edit a.txt", "locations": [{"path": "a.txt"}]})
            update({"sessionUpdate": "tool_call_update", "toolCallId": "call_2", "status": "completed"})
            update({"sessionUpdate": "plan", "entries": [{"content": "x", "priority": "high", "status": "completed"}]})
            update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Done."}})
            result(rid, {"stopReason": "end_turn"})
    elif method == "session/cancel":
        if prompt_id is not None:
            result(prompt_id, {"stopReason": "cancelled"})
    elif rid is not None:
        error(rid, -32601, "Method not found")
