#!/usr/bin/env python3
"""Scripted ACP with asserted read-only/direct-tool launch policy. No provider or network."""
import json
import os
import sys
from pathlib import Path
from conversation_memory import Memory

memory = Memory()

config = json.loads(os.environ["OPENCODE_CONFIG_CONTENT"])
assert os.environ["OPENCODE_CONFIG_PROJECT_DISABLE"] == "1"
assert os.environ["OPENCODE_DISABLE_CLAUDE_CODE"] == "1"
assert Path(os.environ["XDG_CONFIG_HOME"]) == Path(os.environ["OPENCODE_CONFIG_DIR"])
assert not os.environ.get("OPENAI_API_KEY") and not os.environ.get("ANTHROPIC_API_KEY")
agent = config["default_agent"]
rules = config["agents"][agent]["permissions"]
assert rules[0] == {"action": "*", "resource": "*", "effect": "deny"}
assert rules[-1] == {"action": "execute", "resource": "*", "effect": "deny"}
assert {"action": "shoestring_*", "resource": "*", "effect": "allow"} in rules
for server in config["mcp"]["servers"].values():
    assert server["codemode"] is False
    assert server["headers"]["Authorization"] == "Bearer {env:SHOESTRING_CHAT_TOOL_TOKEN}"
session = "11111111-2222-4333-8444-555555555555"
turn_request = None
pending_edit = None
# Shapes follow opencode 2.0.31: agents are the `mode` config option and
# `modes` is null; the session starts on the default model and agent.
modes = ["build", "plan"] + ([] if os.environ.get("FAKE_OPENCODE_NO_AGENT") else [agent])
current = {"model": "opencode/default-free", "effort": "default", "mode": "build"}

def options():
    offered = {"model": ["opencode/default-free", "opus"], "effort": ["default", "high"], "mode": modes}
    return [{"id": key, "type": "select", "currentValue": current[key],
             "options": [{"value": value, "name": value} for value in offered[key]]} for key in current]

def emit(value):
    print(json.dumps(value), flush=True)
def reply(frame, result):
    emit({"jsonrpc": "2.0", "id": frame["id"], "result": result})
def update(value):
    emit({"method": "session/update", "params": {"sessionId": session, "update": value}})
def done(reason):
    emit({"id": turn_request, "result": {"stopReason": reason}})

for line in sys.stdin:
    f = json.loads(line)
    method, params = f.get("method"), f.get("params", {})
    if method == "initialize":
        assert params["clientCapabilities"]["fs"]["writeTextFile"] is False
        assert params["clientCapabilities"]["terminal"] is False
        reply(f, {"protocolVersion": 1, "agentInfo": {"version": os.environ.get("FAKE_OPENCODE_VERSION", "2.0.31")}})
    elif method in ("session/new", "session/resume"):
        assert params["mcpServers"] == []
        if method == "session/resume": session = params["sessionId"]
        else: session = memory.fresh(session)
        session = memory.open(session, method == "session/resume")
        if session is None:
            emit({"id": f["id"], "error": {"code": -32602, "message": "session unavailable"}})
            continue
        reply(f, {"sessionId": session, "configOptions": options()})
    elif method == "session/set_config_option":
        key, value = params["configId"], params["value"]
        if value == "not-a-model" or (key == "mode" and value not in modes):
            emit({"id": f["id"], "error": {"code": -32602, "message": f"{key} not found: {value}"}})
        else:
            if not (key == "model" and os.environ.get("FAKE_OPENCODE_FALLBACK")):
                current[key] = value
            reply(f, {"configOptions": options()})
    elif method == "session/prompt":
        assert current["mode"] == agent
        turn_request = f["id"]
        text = params["prompt"][0]["text"]
        answer = memory.answer(session, text)
        if answer is not None:
            text = "SAY " + answer
        update({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "hidden reasoning"}})
        if text.startswith("SLOW "): continue
        if text.startswith("CALL "):
            update({"sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": text[5:], "rawInput": {"secret": "never forwarded"}})
            update({"sessionUpdate": "tool_call_update", "toolCallId": "tool-1", "status": "completed", "content": []})
        elif text.startswith("SPLIT "):
            for chunk in text[6:]:
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": chunk}})
        elif text.startswith("SAY "):
            update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text[4:]}})
        elif text == "WRITE":
            pending_edit = Path(params.get("cwd", os.getcwd())) / "keep.txt"
            emit({"id": "write-1", "method": "fs/write_text_file", "params": {"path": str(pending_edit), "content": "changed"}})
            continue
        elif text == "PERMISSION":
            emit({"id": "permit-1", "method": "session/request_permission", "params": {"options": [{"kind": "allow_once", "optionId": "allow"}]}})
            continue
        done("failed" if text == "FAIL" else "end_turn")
    elif method == "session/cancel":
        done("cancelled")
    elif f.get("id") == "write-1":
        assert "error" in f
        assert pending_edit.read_text() == "readable original"
        update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Write refused; readable original retained"}})
        done("end_turn")
    elif f.get("id") == "permit-1":
        assert f["result"]["outcome"]["outcome"] == "cancelled"
        done("failed")
