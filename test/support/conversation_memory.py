"""Optional durable scripted context. Test data only; no model or network."""
import json
import os
import uuid
from pathlib import Path


class Memory:
    def __init__(self):
        root = os.environ.get("FAKE_CONVERSATION_MEMORY")
        self.root = Path(root) if root else None
        if self.root:
            self.root.mkdir(parents=True, exist_ok=True)

    def open(self, session, resume):
        if not self.root:
            return session
        if resume:
            return session if self.path(session).exists() else None
        self.path(session).write_text(json.dumps({"remembered": "NO MEMORY"}))
        return session

    def fresh(self, fallback):
        return str(uuid.uuid4()) if self.root else fallback

    def path(self, session):
        return self.root / (str(uuid.UUID(session)) + ".json")

    def answer(self, session, text):
        if not self.root:
            return None
        state = json.loads(self.path(session).read_text())
        with (self.root / "calls.jsonl").open("a") as log:
            log.write(json.dumps({"session": session, "text": text}) + "\n")
        if text.startswith("REMEMBER "):
            state["remembered"] = text[len("REMEMBER "):]
            self.path(session).write_text(json.dumps(state))
            return "stored"
        if text == "RECALL":
            return state["remembered"]
        return None
