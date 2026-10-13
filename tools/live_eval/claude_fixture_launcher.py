#!/usr/bin/env python3
"""Explicit live-evaluation launch configuration; never calls a model on import."""

import json
import os
from pathlib import Path
import shutil
import sys
import uuid


def command(args, state_root, workdir, source, executable):
    if (len(args) != 8 or args[:5] != ["--print", "--verbose", "--output-format", "stream-json", "--model"]
            or args[5] != "opus" or args[6] != "--tools=Bash"):
        raise ValueError("unexpected_adapter_arguments")
    root = Path(state_root).resolve(strict=True)
    workdir = Path(workdir).resolve(strict=True)
    source = Path(source).resolve(strict=True)
    if workdir.parent != root / "worktrees" or not workdir.name.startswith("run-"):
        raise ValueError("unexpected_worktree")
    run_id = str(uuid.UUID(workdir.name[4:]))
    repository = root / "worktrees" / ".git-repositories" / run_id
    pointer = (workdir / ".git").read_text().strip()
    if not pointer.startswith("gitdir: "):
        raise ValueError("unexpected_git_pointer")
    gitdir = Path(pointer[8:])
    if gitdir.parent != repository / "worktrees" or gitdir.is_symlink():
        raise ValueError("shared_or_redirected_git_storage")
    if (gitdir / "commondir").read_text().strip() != "../..":
        raise ValueError("redirected_common_storage")
    if Path((gitdir / "gitdir").read_text().strip()).resolve() != workdir / ".git":
        raise ValueError("mismatched_worktree")
    alternates = repository / "objects" / "info" / "alternates"
    if alternates.exists() or alternates.is_symlink():
        raise ValueError("shared_objects")
    roots = [workdir, gitdir, repository / "objects", repository / "refs" / "heads",
             repository / "logs" / "refs" / "heads"]
    for path in roots:
        for component in [path, *path.parents]:
            if component == root:
                break
            if component.is_symlink():
                raise ValueError("symlinked_write_root")
        if path == source or source in path.parents:
            raise ValueError("source_write_root")
        path.mkdir(parents=True, exist_ok=True)
    settings = {
        "alwaysThinkingEnabled": False,
        "attribution": {"commit": "", "pr": ""},
        "sandbox": {
            "enabled": True, "failIfUnavailable": True,
            "autoAllowBashIfSandboxed": True, "allowUnsandboxedCommands": False,
            "excludedCommands": [],
            "filesystem": {
                "allowWrite": [str(p) for p in roots],
                "denyWrite": [str(source)],
                "denyRead": [str(Path.home())],
                "allowRead": [str(workdir), str(repository)],
            },
            "network": {"allowedDomains": []},
        },
    }
    options = ["--safe-mode", "--restricted", "--setting-sources", "",
               "--settings", json.dumps(settings), "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
               "--disable-slash-commands", "--no-session-persistence", "--effort", "medium",
               "--permission-mode", "dontAsk", "--permission-prompts", "none"]
    return [executable, *args[:-1], *options, args[-1]], settings


def main():
    executable = shutil.which("claude")
    if not executable:
        raise ValueError("claude_unavailable")
    argv, settings = command(sys.argv[1:], os.environ["SHOESTRING_STATE_DIR"], Path.cwd(),
                             os.environ["ITER6_REPOSITORY"], executable)
    root = Path(os.environ["SHOESTRING_STATE_DIR"])
    run_id = Path.cwd().name[4:]
    # Local diagnostic configuration only; no prompt, credential or raw frames.
    (root / f"launch-{run_id}.json").write_text(json.dumps(settings, indent=2))
    os.execv(executable, argv)


if __name__ == "__main__":
    main()
