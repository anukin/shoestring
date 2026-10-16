# The CLI work loop

`shoestring do` takes a request in plain words and carries it through the same
recorded steps as the step-by-step commands: goal, plan, approval, execution,
verification and result. It is not a chat agent. You approve the plan before
anything runs, and you take the result into your repository yourself.

## One-time setup

```sh
# 1. Put the wrapper on your PATH (it runs this checkout's Mix tasks).
ln -s "$PWD/bin/shoestring" /usr/local/bin/shoestring   # or add bin/ to PATH

# 2. Allow a Claude model for agents (Settings in the web UI does the same).
shoestring models add claude opus

# 3. Create the default agent. Its Coordinator plans; its Worker does the work.
shoestring agents create builder --worker claude:opus --default

# 4. Start the service from this checkout and leave it running.
mix phx.server
```

`do` refuses to queue work unless the service it reaches reports the same
database it uses (`/health` carries a fingerprint of the database path), so
run both from this checkout or give both the same `SHOESTRING_STATE_DIR`.

## Using it

```sh
cd ~/code/my-project            # a clean Git repository
shoestring do "add retry with backoff to the HTTP client" --test test/test_http.py
```

1. **Intake.** The base is your `HEAD`; uncommitted changes are refused.
   Checks come from `--test` (tracked test files) and `--gate`
   (`mix_test`, `mix_precommit`, `mix_format_check`, `mix_compile_strict`), or
   are detected: a Mix project runs `mix_test`; Python with 1-16
   `test/**/test_*.py` files runs `python_unittest` over them. The planner
   never picks checks.
2. **Plan.** Claude drafts tasks from your request and a list of tracked file
   paths (never file contents), with no tools and no repository access. When
   Claude's remaining usage cannot be confirmed automatically you are asked
   before the call; its output allowance is charged before it runs. At most
   two planner calls per goal (one draft, one repair).
3. **Review.** The plan is printed. `y` approves exactly that revision, `n`
   stops (the goal and draft stay recorded), `e` writes it to a file for you to
   edit and submits your edit as a new revision.
4. **Run.** The service admits each task against capacity and runs a
   sandboxed Claude Elf in a private copy: writes only to that copy, no home
   reads beyond it, no network for its shell, no permission bypass. Ctrl-C
   detaches; the work keeps running. `shoestring follow GOAL` re-attaches.
5. **Waits.** If a task is held because capacity cannot be confirmed, you are
   asked to confirm that one attempt. Failures and scope blockers stop
   following with the command to resolve them.
6. **Result.** `shoestring result GOAL` prints the final commit, the recorded
   checks, a diff stat, and:

   ```sh
   cd ~/code/my-project
   git fetch <run worktree> <commit>
   git merge FETCH_HEAD
   ```

## Limits

- Manual runs from `/runs/new` share Git storage and are not sandboxed this
  way; only plan runs are.
- Planning uses Claude only (or a configured local Ollama planner); Codex
  planning is not available.
- The checks Shoestring runs after a worker finishes are not sandboxed; they
  run the worker's code with the service's access. Planned for iteration 8.
- The planner tends to propose 3 attempts and `do` has no budget option; press
  `e` to lower it before approving.
- Verified live on 2026-10-15 (see
  `plans/evidence/07a-cli-work-loop/README.md`): Claude's structured planning
  output is accepted as is, and a sandboxed Elf can read and write its own
  worktree when the state directory is under your home directory. That the
  rest of your home directory is unreadable is configured but was not probed
  live.
