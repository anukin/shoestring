# The CLI work loop

`shoestring do` takes a request in plain words and carries it through the same
recorded steps as the step-by-step commands: goal, plan, approval, execution,
verification and result. It is not a chat agent. You approve the plan before
anything runs, and you take the result into your repository yourself.

## One-time setup

With an installed release (Homebrew), `shoestring` is already on your `PATH`:

```sh
shoestring init                 # create the state directory
shoestring doctor --probe-providers   # is the claude CLI installed, signed in, tested?
shoestring models add claude opus
shoestring agents create builder --worker claude:opus --default
shoestring start                # in another terminal; leave it running
```

From a source checkout, the wrapper runs the same commands with this
checkout's code and state:

```sh
# 1. Put the wrapper on your PATH.
ln -s "$PWD/bin/shoestring" /usr/local/bin/shoestring   # or add bin/ to PATH

# 2. Allow a Claude model for agents (Settings in the web UI does the same).
shoestring models add claude opus

# 3. Create the default agent. Its Coordinator plans; its Worker does the work.
shoestring agents create builder --worker claude:opus --default

# 4. Start the service from this checkout and leave it running.
mix phx.server
```

To run tasks through opencode instead, see [opencode worker](opencode-worker.md):
the worker becomes `opencode:PROVIDER/MODEL` and the coordinator stays Claude or
Codex.

`do` refuses to queue work unless the service it reaches reports the same
database it uses (`/health` carries a fingerprint of the database path), so
give both the same state directory: the installation's default, or the same
`SHOESTRING_STATE_DIR`. Output streams, `--json` and exit statuses are in
[the CLI output contract](cli-output.md).

## Using it

```sh
cd ~/code/my-project            # a clean Git repository
shoestring do "add retry with backoff to the HTTP client" --test test/test_http.py
```

1. **Intake.** The base is your `HEAD`; uncommitted changes are refused.
   Checks come from `--test` (tracked test files) and `--gate`
   (`mix_test`, `mix_precommit`, `mix_format_check`, `mix_compile_strict`, or
   `project:NAME` for a command you approved, see [Checks](#checks)), or
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

## Checks

Each check has a versioned specification: its command (an argument array,
never a shell string), kind, timeout, output limit, environment allowlist,
whether it is required, and how its output is kept. Every run records that
specification's identity, the exact result (`passed`, `failed`, `timeout`,
`output_oversized`, `unavailable` or `error`), the exit status, the commit it
verified and its duration, and keeps the output (redacted) as an artifact.

Checks run cheap first: repository status, formatting, lint / compile /
typecheck, build, tests, precommit; in the plan's order within a kind. When a
required check fails, the rest are not run and are listed as skipped.

For commands the built-in checks do not cover, approve them in your
configuration (never in a plan):

```elixir
config :shoestring, :project_gates, %{
  "npm_test" => %{argv: ["npm", "test"], kind: "test", timeout_ms: 300_000},
  "ruff" => %{argv: ["ruff", "check", "."], kind: "lint", required: false}
}
```

and cite them with `--gate project:npm_test`. The program must be a bare
name on `PATH` (not installed under your home directory, which the check
sandbox cannot read). A failed check with `required: false` is recorded and
shown but does not block the task, unless all of a task's checks are
optional. A cited name that is no longer configured stops the task for you;
it is never skipped as passed.

```sh
shoestring checks GOAL            # every check run: task, attempt, result, spec
shoestring checks GOAL --output 3 # check 3's output so far, or its complete output
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

- Manual Claude and Codex runs from `/runs/new` now also get private per-run
  Git storage, and manual Claude runs the same sandbox as plan runs. Their
  commits live in that copy: fetch them with the `git fetch` the goal page
  shows. Fake manual runs, and manual runs started before this change, still
  share the source repository's Git storage and are not sandboxed.
- A task that cannot be admitted because there is no capacity reading for
  its provider yet says so once in `follow` ("is waiting: no capacity
  reading for ...") and starts when a reading arrives.
- Planning uses Claude only (or a configured local Ollama planner); Codex
  planning is not available.
- Cross-review was verified live on 2026-10-17 on one small fixture (Codex and
  Claude each found a seeded defect and approved a correct change; one full
  loop with a Codex review approved a real Claude Elf change; one loop with a
  seeded defect was blocked by Codex, repaired from the reviewed commit and
  approved on the second round; one escalated and was dismissed with
  `shoestring review accept`; one with a Codex worker and a Claude reviewer
  approved). On 13 small seeded cases whose contracts name the requirement,
  both reviewers found all 8 defects and blocked none of the 5 clean
  changes; that is not a measure of subtle defects. A fan-out replacement
  after a blocking review starts from the approved base with the findings,
  not from the reviewed commit. On 2026-10-19 a live sibling fan-out had two
  workers concurrently, two separate reviews and both tasks accepted; the
  join phase was not run after the authorized worker budget was exhausted.
  Both manual provider paths, human reject/retry and two more seeded repair
  samples also passed; see iteration 8 evidence for the retained initial
  fan-out failure and its session-index ownership fix.
- Check output streams into redacted artifacts as complete lines arrive.
  Incomplete lines and credential labels wait for more bytes or completion.
  `checks --output N` marks output without a complete artifact as partial;
  it remains inspectable if the invocation is interrupted.
  Artifact writes run separately from the raw output collector, so a stalled
  write cannot extend command execution or its byte cap. A failed gate gets
  at most 500 ms to flush partial chunks after its command is stopped.
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
