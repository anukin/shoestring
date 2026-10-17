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
   reads beyond it, no network for its shell, no permission bypass. The checks
   then run in a macOS sandbox of their own (see Limits). Ctrl-C detaches; the
   work keeps running. `shoestring follow GOAL` re-attaches.
5. **Waits.** If a task is held because capacity cannot be confirmed, you are
   asked to confirm that one attempt. Failures and scope blockers stop
   following with the command to resolve them.
6. **Review (optional, off by default).** With cross-review enabled, each task
   whose checks pass is reviewed by another provider before it is accepted;
   see [Cross-review](#cross-review).
7. **Result.** `shoestring result GOAL` prints the final commit, the recorded
   checks, every review and its blocking findings, a diff stat, and:

   ```sh
   cd ~/code/my-project
   git fetch <run worktree> <commit>
   git merge FETCH_HEAD
   ```

## Cross-review

Turn it on with `config :shoestring, :plan_review, enabled: true` (in
`config/config.exs` or your runtime config) and give the agent a reviewer of
another provider than its worker:

```sh
shoestring models add codex gpt-6-luna
shoestring agents set-role builder Reviewer codex:gpt-6-luna
```

After a task's checks pass, the reviewer gets one bounded packet: the goal and
task contract, the diff from the task's base, the changed and tracked files and
the check results. It never gets the worker's transcript, the worktree or any
tools: Codex runs `codex exec` read-only and ephemeral with every tool
disabled, Claude runs the planner's tool-free call. It returns structured
findings; code, not the reviewer, decides:

- No supported blocking finding: the task is accepted, with the review
  recorded.
- Blocking findings: the task is sent back once more, starting from the
  reviewed commit with the findings in the worker's prompt, and its checks and
  review run again.
- The last round (two by default) still blocking, the same finding again, or
  no attempts left: it waits for you.

A finding about a file the packet does not contain is shown as unsupported and
never blocks. Each review call is admitted like any provider call; `follow`
asks you to confirm one held call, as it does for a held task. When a review
cannot run (no reviewer, a reviewer of the worker's provider, a failed or lost
call), nothing is accepted until you decide:

```sh
shoestring review list GOAL
shoestring review show GOAL TASK
shoestring review accept GOAL TASK --reason "why"   # waive or dismiss
shoestring review reject GOAL TASK --reason "why"   # fail the attempt
shoestring review retry GOAL TASK --reason "why"    # one more call
```

## Limits

- Manual runs from `/runs/new` share Git storage and are not sandboxed this
  way; only plan runs are.
- Planning uses Claude only (or a configured local Ollama planner); Codex
  planning is not available.
- Cross-review was verified live on 2026-10-17 on one small fixture (Codex and
  Claude each found a seeded defect and approved a correct change; one full
  loop with a Codex review approved a real Claude Elf change). The repair loop
  (blocking findings, repair, re-review) has been tested only with the fixture
  reviewer. A fan-out replacement after a blocking review starts from the
  approved base with the findings, not from the reviewed commit, and fan-out
  with review enabled has no test yet.
- The checks Shoestring runs after a worker finishes run under macOS
  `sandbox-exec`: they can read the worktree and anything outside your home
  directory, write only to the worktree and a temporary directory, make no
  outbound connection (not even to localhost), and see only `PATH`, the locale
  and their own `HOME`/`TMPDIR`. So a check fails if its tests need the
  network, a service on localhost, or a client connection to a server they
  start themselves. File names and sizes in your home directory stay visible.
  A check cannot run, and the task stops for you, when there is no sandbox
  (any platform other than macOS), the worktree is not a private run worktree,
  or the check's program (`mix`, `python3`) is installed under your home
  directory.
- The planner tends to propose 3 attempts and `do` has no budget option; press
  `e` to lower it before approving.
- Verified live on 2026-10-15 (see
  `plans/evidence/07a-cli-work-loop/README.md`): Claude's structured planning
  output is accepted as is, and a sandboxed Elf can read and write its own
  worktree when the state directory is under your home directory. That the
  rest of your home directory is unreadable is configured but was not probed
  live.
