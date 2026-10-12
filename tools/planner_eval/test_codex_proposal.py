"""Hermetic capture checks: local Python children only, never Codex or network."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

import codex_proposal as proposal


class CaptureTest(unittest.TestCase):
    def message(self, text="{\"tasks\":[]}"):
        return {"type": "item.completed", "item": {"type": "agent_message", "text": text}}

    def test_reasoning_and_identifiers_are_discarded_but_answer_and_usage_remain(self):
        capture = proposal.Capture()
        capture.accept({"type": "thread.started", "thread_id": "private-provider-id"})
        capture.accept({"type": "item.completed", "item": {
            "type": "reasoning", "text": "private-reasoning", "id": "private-item-id"}})
        capture.accept(self.message())
        capture.accept({"type": "turn.completed", "usage": {
            "input_tokens": 123, "cached_input_tokens": 0, "output_tokens": 45,
            "provider_id": "private-provider-id", "reasoning": "private-reasoning"}})
        saved = json.dumps(vars(capture))
        self.assertNotIn("private-", saved)
        self.assertEqual(capture.answer, '{"tasks":[]}')
        self.assertEqual(capture.usage, {
            "input_tokens": 123, "cached_input_tokens": 0, "output_tokens": 45})
        self.assertTrue(capture.completed)

    def test_tool_start_is_rejected_before_its_output_can_be_retained(self):
        for item in ("command_execution", "file_change", "mcp_tool_call", "web_search", "todo_list"):
            capture = proposal.Capture()
            with self.assertRaisesRegex(proposal.Rejected, "^unexpected_tool_or_item$"):
                capture.accept({"type": "item.started", "item": {
                    "type": item, "text": "private-tool-output"}})
            self.assertEqual(capture.tool_items, 1)
            self.assertNotIn("private-tool-output", json.dumps(vars(capture)))

    def test_multiple_messages_are_not_silently_combined(self):
        capture = proposal.Capture()
        capture.accept(self.message())
        with self.assertRaisesRegex(proposal.Rejected, "^multiple_messages$"):
            capture.accept(self.message("different"))
        self.assertEqual(capture.answer, '{"tasks":[]}')

    def test_oversized_multibyte_answer_is_rejected_without_truncation(self):
        capture = proposal.Capture()
        with self.assertRaisesRegex(proposal.Rejected, "^oversized_answer$"):
            capture.accept(self.message("é" * (proposal.MAX_OUTPUT_BYTES // 2 + 1)))
        self.assertIsNone(capture.answer)

    def test_provider_failure_does_not_echo_diagnostics(self):
        capture = proposal.Capture()
        with self.assertRaisesRegex(proposal.Rejected, "^provider_error$"):
            capture.accept({"type": "error", "message": "secret diagnostic"})
        self.assertNotIn("secret", json.dumps(vars(capture)))

    def test_startup_error_item_is_counted_as_diagnostic_and_valid_answer_survives(self):
        capture = proposal.Capture()
        capture.accept({"type": "item.completed", "item": {
            "type": "error", "message": "private startup diagnostic"}})
        capture.accept(self.message())
        self.assertEqual(capture.diagnostic_items, 1)
        self.assertEqual(capture.tool_items, 0)
        self.assertEqual(capture.answer, '{"tasks":[]}')
        self.assertNotIn("private", json.dumps(vars(capture)))

    def test_usage_drops_invalid_numbers_and_unknown_fields(self):
        capture = proposal.Capture()
        capture.accept({"type": "turn.completed", "usage": {
            "input_tokens": True, "cached_input_tokens": -1, "output_tokens": 2,
            "another_token_count": 100}})
        self.assertEqual(capture.usage, {"output_tokens": 2})

    def test_invocation_ignores_user_configuration_and_disables_execution_surfaces(self):
        args = proposal.command(Path("/tmp/empty"), Path("/tmp/instructions.txt"))
        for arg in ("--ignore-user-config", "--ignore-rules", "--ephemeral", "read-only",
                    "agents.enabled=false", 'web_search="disabled"', "project_doc_max_bytes=0"):
            self.assertIn(arg, args)
        self.assertEqual(args[args.index("--model") + 1], "gpt-6-luna")
        self.assertIn("shell_tool", args)
        self.assertIn("multi_agent", args)
        self.assertIn("hooks", args)


class StreamTest(unittest.TestCase):
    def collect_local(self, source, prompt=b"input", timeout=3):
        process = subprocess.Popen([sys.executable, "-B", "-c", source],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        capture = proposal.Capture()
        try:
            proposal.collect(process, prompt, capture, timeout=timeout)
            return capture
        finally:
            proposal.stop_owned_group(process)

    def test_prompt_is_fully_sent_and_closed_and_final_result_is_captured(self):
        source = """import json, sys
text = sys.stdin.read()
print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':text}}))
print(json.dumps({'type':'turn.completed','usage':{'output_tokens':7}}))
"""
        capture = self.collect_local(source, prompt=b"snapshot " * 6000)
        self.assertEqual(capture.answer, "snapshot " * 6000)
        self.assertEqual(capture.usage, {"output_tokens": 7})

    def test_incomplete_frame_is_rejected(self):
        with self.assertRaisesRegex(proposal.Rejected, "^incomplete_frame$"):
            self.collect_local("import sys; sys.stdin.read(); sys.stdout.write('{}')")

    def test_oversized_frame_is_rejected(self):
        with self.assertRaisesRegex(proposal.Rejected, "^oversized_frame$"):
            self.collect_local("import sys; sys.stdin.read(); print('x' * 1048577)")

    def test_missing_result_is_rejected(self):
        with self.assertRaisesRegex(proposal.Rejected, "^missing_result$"):
            self.collect_local("import sys; sys.stdin.read()")

    def test_hung_owned_process_is_bounded(self):
        with self.assertRaisesRegex(proposal.Rejected, "^timeout$"):
            self.collect_local("import signal; signal.pause()", timeout=0.1)


if __name__ == "__main__":
    unittest.main()
