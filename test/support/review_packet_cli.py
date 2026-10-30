#!/usr/bin/env python3
"""Hermetic tool-free Codex review transport. No provider or network."""
import json
import sys

packet = json.loads(sys.argv[-1])
assert packet["briefs"]["implementation"]
answer = {"verdict": "approve", "summary": "Scripted packet accepted.", "findings": []}
print(json.dumps({"type": "item.completed", "item": {
    "type": "agent_message", "text": json.dumps(answer)}}))
print(json.dumps({"type": "turn.completed", "usage": {"output_tokens": 10}}))
