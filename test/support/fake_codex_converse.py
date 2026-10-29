#!/usr/bin/env python3
"""Hermetic app-server stand-in. No provider or network."""
import json
import os
import sys

assert not os.environ.get("OPENAI_API_KEY")
assert not os.environ.get("CODEX_API_KEY")
assert 'web_search="disabled"' in sys.argv
session = "11111111-2222-4333-8444-555555555555"
turn = None

def emit(value):
    print(json.dumps(value), flush=True)
def reply(frame, result):
    emit({"id": frame["id"], "result": result})
def event(method, **params):
    emit({"method": method, "params": {"threadId": session, **params}})
def complete(status):
    event("turn/completed", turn={"id": turn, "status": status})

for line in sys.stdin:
    f = json.loads(line)
    method, params = f.get("method"), f.get("params", {})
    if method == "initialize":
        reply(f, {})
    elif method == "model/list":
        reply(f, {"data": [{"id": "opus", "model": "opus", "supportedReasoningEfforts": [{"reasoningEffort": "high"}]}]})
    elif method in ("thread/start", "thread/resume"):
        assert params["sandbox"] == "read-only"
        assert params["approvalPolicy"] == "never"
        assert params["model"] == "opus"
        if method == "thread/resume":
            session = params["threadId"]
        reply(f, {"thread": {"id": session}})
    elif method == "turn/start":
        assert params["sandboxPolicy"] == {"type": "readOnly"}
        assert params["approvalPolicy"] == "never"
        assert params["model"] == "opus"
        turn = "turn-" + str(f["id"])
        reply(f, {"turn": {"id": turn}})
        event("turn/started", turn={"id": turn})
        text = params["input"][0]["text"]
        event("item/reasoning/summaryTextDelta", turnId=turn, delta="hidden reasoning")
        if text.startswith("SLOW "):
            continue
        if text.startswith("CALL "):
            item = {"type": "mcpToolCall", "id": "tool-1", "tool": text[5:], "arguments": {"secret": "hidden"}}
            event("item/started", turnId=turn, item=item)
            event("item/completed", turnId=turn, item=item)
        elif text.startswith("SAY "):
            event("item/agentMessage/delta", turnId=turn, itemId="message-1", delta=text[4:])
            event("item/completed", turnId=turn, item={"id": "message-1", "type": "agentMessage", "text": text[4:]})
        elif text == "APPROVAL":
            emit({"id": "approval-1", "method": "item/commandExecution/requestApproval", "params": {}})
            continue
        complete("failed" if text == "FAIL" else "completed")
    elif method == "turn/interrupt":
        assert params["turnId"] == turn
        reply(f, {})
        complete("interrupted")
    elif f.get("id") == "approval-1":
        assert "error" in f
        complete("failed")
