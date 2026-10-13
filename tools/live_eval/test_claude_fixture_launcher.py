import json
from pathlib import Path
import tempfile
import unittest
import uuid

from claude_fixture_launcher import command


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="shoestring-claude-launcher-")).resolve()
        run_id = str(uuid.uuid4())
        self.workdir = self.root / "worktrees" / f"run-{run_id}"
        self.repository = self.root / "worktrees" / ".git-repositories" / run_id
        self.gitdir = self.repository / "worktrees" / "fixture"
        self.source = self.root / "source"
        for path in [self.workdir, self.gitdir, self.source]:
            path.mkdir(parents=True)
        (self.workdir / ".git").write_text(f"gitdir: {self.gitdir}\n")
        (self.gitdir / "commondir").write_text("../..\n")
        (self.gitdir / "gitdir").write_text(str(self.workdir / ".git") + "\n")
        self.args = ["--print", "--verbose", "--output-format", "stream-json", "--model", "opus", "--tools=Bash", "fixture prompt"]

    def build(self, args=None):
        return command(args or self.args, self.root, self.workdir, self.source, "/synthetic/claude")

    def test_model_prompt_and_isolation_are_preserved(self):
        argv, settings = self.build()
        self.assertEqual(argv[1:8], self.args[:-1])
        self.assertEqual(argv[-1], "fixture prompt")
        self.assertNotIn("--dangerously-skip-permissions", argv)
        self.assertIn("--safe-mode", argv)
        self.assertIn("--no-session-persistence", argv)
        self.assertTrue(settings["sandbox"]["failIfUnavailable"])
        self.assertFalse(settings["sandbox"]["allowUnsandboxedCommands"])
        self.assertEqual(settings["sandbox"]["network"]["allowedDomains"], [])
        roots = settings["sandbox"]["filesystem"]["allowWrite"]
        self.assertIn(str(self.gitdir), roots)
        self.assertIn(str(self.repository / "objects"), roots)
        self.assertNotIn(str(self.repository), roots)
        self.assertNotIn(str(self.source), roots)
        self.assertEqual(json.loads(argv[argv.index("--settings") + 1]), settings)

    def test_permission_bypass_or_changed_model_is_refused(self):
        for args in [self.args + ["--dangerously-skip-permissions"], self.args[:5] + ["other", *self.args[6:]]]:
            with self.assertRaisesRegex(ValueError, "unexpected_adapter_arguments"):
                self.build(args)

    def test_shared_source_git_is_refused(self):
        (self.workdir / ".git").write_text(f"gitdir: {self.source}/.git/worktrees/fixture\n")
        with self.assertRaisesRegex(ValueError, "shared_or_redirected_git_storage"):
            self.build()

    def test_redirected_common_storage_is_refused(self):
        (self.gitdir / "commondir").write_text(str(self.source))
        with self.assertRaisesRegex(ValueError, "redirected_common_storage"):
            self.build()

    def test_symlinked_objects_are_refused_without_writing_through_them(self):
        (self.repository / "objects").symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked_write_root"):
            self.build()
        self.assertEqual(list(self.source.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
