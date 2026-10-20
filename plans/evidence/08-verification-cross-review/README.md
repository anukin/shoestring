# Iteration 8: deterministic verification and cross-review — evidence

Milestone: `plans/milestones/08-verification-cross-review.md` (local plan; not
yet committed). Iteration 7 and 7A were accepted by the user on 2026-10-16.

## Work package 0: sandboxed checks

Date: 2026-10-16. Branch `iter8/sandboxed-checks` from `09ea714`, whose `lib`,
`test`, `config`, `mix.exs` and `mix.lock` are identical to `b94f477`
(VERIFIED: `git diff --stat b94f477 09ea714 -- lib test config mix.exs mix.lock`
printed nothing). Platform: macOS 15.7.7, Elixir 1.19.5, OTP 28, Python 3.12.

### What was built

- `Shoestring.Cobbler.GateSandbox`: wraps a trusted gate argv as
  `sandbox-exec -p <profile> env -i <allowlist> <argv>`. The profile is
  generated from Shoestring's own paths (`GitSandbox.policy/3` roots, the gate's
  temporary directory, the home directory), never from plan or model text:
  - reads: the home directory is denied except the worktree, its private Git
    storage and the gate's temporary directory; file metadata under home stays
    readable; everything outside home (the toolchain) is readable;
  - writes: only the worktree (not its `.git` link file), the temporary
    directory and the standard `/dev` sinks;
  - network: all outbound denied, including localhost; bind and inbound on
    localhost are allowed because Mix's cross-process compile lock and pubsub
    listen there;
  - environment: `PATH`, `LANG`/`LC_ALL`/`LC_CTYPE` when set, `HOME` and
    `TMPDIR` set to the gate's temporary directory, and the home-free Git
    variables Elves use; nothing else from the service.
- Fail closed: no mechanism (any platform but macOS, or no
  `/usr/bin/sandbox-exec`), a worktree that is not a registered private run
  worktree, an invalid binding, an executable installed under the home
  directory, or a path the profile cannot quote safely all return
  `{:error, {:gate_unavailable, %{reason: reason}}}`. The command never runs.
- `PlanGateRunner` runs every real gate through it and adds
  `sandbox: "macos_seatbelt:v1:sha256:<profile digest>"` to evidence; stored
  accepted evidence carries it as `"sandbox"`. Injected test runners carry
  `nil`.
- The executor records an unavailable gate as `cobbler.plan.task.gate_failed`
  with `retry_state` `needs_user` and the `gate_unavailable` reason, so it never
  spends another Elf attempt. `follow` prints "checks could not run in a
  sandbox (<gate>: <reason>); needs your decision", not "checks failed".
- `PlanWorkspace` passes the worktree root to the gate runner for task,
  global and integration gates.
- Timeout, output limit and process-group kill are unchanged: `sandbox-exec`
  and `env` exec in place, so the gate stays the owned group leader.

### Required evals (hermetic, `test/shoestring/cobbler/gate_sandbox_test.exs`)

Real `sandbox-exec` and `python3` gates over a registered private run worktree
that lives under a scratch home directory (itself under the real home
directory), with a localhost listener and a synthetic token owned by the test.

| Eval | Result on the branch | Against `b94f477` (VERIFIED, same test file) |
| --- | --- | --- |
| Read outside the worktree | pass: secret read and home listing denied, worktree file read | fails: the secret was read (`read_outside` = the secret) |
| Write outside the worktree | pass: outside file and `.git` link denied; worktree (ignored path) and temporary directory written | fails: `write_outside` = `written` |
| Network | pass: connect to the test's localhost listener denied; listener accepted nothing | fails: `connect` = `connected` |
| Environment | pass: synthetic token absent; `PATH` present; `HOME` = `TMPDIR` | fails: the token was visible |
| No mechanism | pass: unavailable, probe never ran | fails: the gate ran (`{:ok, ...}`) |
| Not a private run worktree | pass: unavailable, probe never ran | fails: the gate ran |
| Toolchain under home | pass: unavailable (`toolchain_under_home`) | fails: the gate ran (exit 99) |
| Sandbox identity | pass | fails on a missing `:sandbox` key: documents the new field, not a regression lock |
| Lifecycle: timeout | pass: `gate_timeout`, gate was its group leader, group (including a TERM-ignoring descendant) only zombies afterwards | passes (unchanged behaviour, as required) |
| Lifecycle: oversized output | pass: `gate_output_oversized` | passes |

Executor: `plan_executor_test.exs` "a gate that cannot be sandboxed stops for
the user instead of retrying" passes on the branch and fails against
`b94f477` with `retry_state` `"retry"`. `follow_test.exs` covers both the
unavailable line and the ordinary failed-checks line.

`plan_python_gate_test.exs` now runs its real Python reference gates in a
registered private worktree (a plain repository is refused by design) and
asserts the sandbox identity; its gate assertions are unchanged.

Linux: not implemented. CI is macOS-only (`macos-14`) and the support claim is
macOS, so no test is excluded; on another platform every real gate is
unavailable (fail closed). `bwrap` was not available to test here.

### Gate

VERIFIED: `mix precommit` exited 0: **4 doctests, 2221 tests, 0 failures,
1 skipped (6 excluded)**, seed 613961, 458.8 s. JavaScript **52/52** and
**8/8**.

### Full-loop rehearsal (no provider call)

VERIFIED: `tools/live_eval/iter7a_work_loop.exs` with `ITER7A_MODE=rehearsal`
and a new evaluation root under the home directory passed **1 of 1**: plan
approved, held task confirmed, Fake Elf run, task accepted, all checks passed,
result printed; fixture source unchanged; the printed merge in a clone passed
its tests; 68.2 s, 1 run, 1 planner attempt. The exported domain events
carry two sandbox identities, one for the task gate and one for the final
goal gate (`macos_seatbelt:v1:sha256:3d72fe8b…` and `…:ae6e8165…`).

### Manual probes (scratch, before the module was written)

VERIFIED, with a hand-written profile using the same rules:

- `python3 -B -m unittest` and `mix test` (a dependency-free Mix project, cold
  `_build`) pass under the profile with `HOME`/`TMPDIR` in a temporary
  directory.
- With all network denied, `mix test` fails at start: `Mix.Sync.PubSub`
  "failed to open a TCP socket ... reason: :eperm". Allowing only localhost
  bind and inbound fixes it; `MIX_OS_CONCURRENCY_LOCK` is not needed.
- Under those rules a process can listen on localhost but cannot connect to
  its own listener (`Operation not permitted`), while the same connection
  succeeds unsandboxed.
- Seatbelt matches resolved paths: a temporary directory given as
  `/var/folders/...` is refused for writes until resolved to `/private/var/...`.

### Limits

- macOS only; other platforms cannot run real gates at all.
- Gates whose tests need the network, a localhost service, or a client
  connection to a server they start themselves fail (recorded as failed, with
  their output).
- A toolchain installed under the home directory makes `mix`/`python3` gates
  unavailable; only the gate's own executable is checked, not what it loads
  (for example `elixir`/`erl` found by `mix`).
- File metadata (existence, size, times) under the home directory remains
  readable; contents and directory listings are not.
- Mach/XPC services are not restricted by the profile (UNVERIFIED what a gate
  could reach through them, for example Keychain items without access
  control).
- The gate's temporary directory under the system temporary directory is not
  removed after the gate; the OS purges it.
- Shoestring's own `git` checks around the gate (`rev-parse`, `status`) run
  unsandboxed, as before. REPO-INSPECTION: they read Git configuration from
  the private store, which neither the Elf nor the gate can write.
- "Unavailable" is a reason inside the existing `gate_failed` event with
  `needs_user`, not a separate event type; work package A owns the versioned
  gate result shape.
- Not done in this package: manual `/runs/new` runs remain unsandboxed, and
  sandboxed Claude Elves still inherit the service environment.
- The optional live probe (an Elf asked to read home and reach a public host)
  was not run; it needs separate authorization and a budget.

## Cross-review (packages C–G, first slice; A and B partly)

Date: 2026-10-17. Branch `iter8/cross-review`, stacked on
`iter8/sandboxed-checks` (`c92c9ac`). No provider call was made; every
reviewer below is the deterministic fixture or a scripted stand-in.

### Decisions taken without a human answer (conservative readings; revisit)

- **Off by default.** `config :shoestring, :plan_review, enabled: false`, as
  for fan-out. Review policy comes from configuration and the execution's
  immutable agent revision (its `Reviewer` role), never from the plan or a
  model.
- **"Different provider"** means a different provider family: `claude`
  (Anthropic) and `codex` (OpenAI). Two models of one vendor are the same
  provider. An unknown implementer family is unavailable, not trusted.
- **Reviewer unavailable** (no Reviewer role, the implementer's provider, an
  unusable packet, a failed or lost call): nothing is accepted; the task waits
  for a human `accept` (a recorded waiver), `reject` or `retry`. There is no
  "no cross-review" mode while review is enabled, and no self-approval.
- **Bounds:** at most `max_rounds` reviews per task (default 2, at most 3); at
  most two calls per review (one automatic, one human `retry`); repairs spend
  the task's ordinary attempt budget. A repeated blocking finding (same path
  and violated contract) or the last round escalates to the human.
- **Isolation by construction:** the reviewer gets a packet and an empty
  working directory, no worktree and no tools, so there is no review copy to
  mutate. The implementation worktree is checked (same `HEAD`, clean) before
  and after the call; a change discards the review as failed.
- **Admission:** each call is a `read_only` admission on the reviewer's
  provider and scope. Claude and Codex reviewers are `conservative_partial`,
  so each call needs one human confirmation (asked by `follow`) until their
  capacity can be read; a hard stop such as refused capacity is never
  bypassed by a confirmation. Review calls do not take the global task claim.

### What was built

- `Review.Configuration`, `Review.Packet` (content-addressed; contract, plan
  revision, base and reviewed commits, complete diff up to 200 kB, changed and
  tracked files, gate evidence with labelled output tails, rubric, output
  schema; never a transcript), `Review.Findings` (strict schema; supported /
  unsupported / path-free references; deterministic outcome; fingerprints),
  `Review.Events` (strict validation; recorded findings replay to their
  outcome and blocking count) and the `plan_reviews` record.
- Adapters: `Review.CodexExec` (`codex exec` with the flag set of the reviewed
  isolated capture `tools/planner_eval/codex_proposal.py`: ephemeral, user
  config and rules ignored, read-only sandbox, no approvals or web search, 22
  features disabled (every tool, plus unbounded retries), `--output-schema`), `Review.ClaudeHeadless` (the
  planner's tool-free call, now shared as `Harness.ClaudeHeadless.OneShot`),
  `Review.Fixture` (seeded `REVIEW-DEFECT:` markers become blocking findings).
- `PlanReview`: the stage between passing gates and acceptance, for sequential
  and fan-out children alike (`complete_task_run`). Events:
  `cobbler.plan.task.review_requested`, `cobbler.plan.review.confirmed`,
  `cobbler.plan.review.attempt.started`, `cobbler.plan.task.reviewed`,
  `cobbler.plan.review.decided`, and the resolution
  `cobbler.plan.task.review_blocked` (added to every resolution list). Accepted
  tasks carry a `review` summary.
- Repair: the next attempt of a sequential task starts from the reviewed
  commit in a new private store and its prompt carries the blocking findings
  as review data; its gates and review run again.
- CLI: `follow` prints review progress, confirms one held review call, and
  names the `shoestring review` command when a review needs you;
  `shoestring review list|show|accept|reject|retry`; `result` prints every
  review round and its blocking findings.

### Required evals (hermetic)

| Eval | Result | Test |
| --- | --- | --- |
| Gate pass | Exact commit, command and result stored, now with the sandbox identity (package 0) and, under review, the review summary | `plan_review_test` approve |
| Gate failure | A failing gate records no review | `plan_review_test` "a failing gate never reaches review" |
| Stale evidence | The reviewed commit moving before the call fails the review; nothing is reviewed or accepted | `plan_review_test` stale evidence |
| Reviewer self | Same provider family is unavailable, cannot be confirmed, needs a human waiver | `plan_review_test`, `review_contract_test` |
| Reviewer write | A reviewer that changes the implementation fails the review; nothing approved | `plan_review_test` |
| Hallucinated file | Unsupported reference, never blocks | `plan_review_test`, `review_contract_test` |
| Blocking repair | `review_blocked` with `retry`; attempt 2 of the same task gets the findings and the reviewed commit | `plan_review_test` |
| Repeated finding | Escalated, no re-dispatch, human dismissal recorded with the acceptance | `plan_review_test` |
| Capacity exhausted | Held; a confirmation cannot bypass refused capacity; no call | `plan_review_test` |
| Restart | A lost (`running`) call is never re-sent by time; a human `retry` makes exactly one more call; then final | `plan_review_test` |

Also: packet contents and digest, review off unchanged, known capacity admits
without confirmation, human reject, the `shoestring review` command, the Codex
and Claude adapters against stand-ins (flags, empty working directory, schema
file, tools / extra messages / failures / limits / overrun killing the
group), the fixture rule, findings schema refusals, and follow's review lines
and prompts.

These are new-functionality tests: at the base commit the modules do not
exist, so they cannot fail there for a behavioural reason and are not
regression locks.

### Gate

VERIFIED: `mix precommit` exited 0: **4 doctests, 2253 tests, 0 failures,
1 skipped (6 excluded)**, seed 552440, 478.5 s. JavaScript **52/52** and
**8/8**.

### Rehearsal (no provider call)

VERIFIED: `tools/live_eval/iter7a_work_loop.exs` with `ITER7A_MODE=rehearsal`
and `ITER7A_REVIEW=fixture` passed 1 of 1 in a service node: checks passed,
cross-review requested, held for capacity, `follow` asked and the scripted
terminal confirmed, review approved, task accepted, final checks passed, and
`result` printed `Review: add attempt 1 by fixture:fixture-reviewer -> approved`.
Fake Elves change no files, so the reviewed diff was empty: this proves the
loop, not a review of a real change (the repair path is the hermetic test).

### Not done or not verified

- **Live review**: no Claude or Codex review call has been made. That
  `--output-schema` holds Codex to the findings schema on 0.163.0, and the
  result shape of a Claude review, are UNVERIFIED. A live check needs
  authorization and a budget.
- **Review-quality eval** (seeded-defect recall, false blocking rate, …):
  not built; it needs live reviewer calls and human labels.
- **Fan-out with review**: the stage is shared, but no test runs fan-out with
  review enabled; a fan-out replacement starts from the approved base with the
  findings (its prompt says so), not from the reviewed commit.
- **Package A**: no versioned gate specification (ids, versions,
  required/optional, artifact policy) and no project-approved gate commands
  yet; "unavailable" is still a reason inside `gate_failed`.
- **Package B**: no gate start/completion events, no streaming output
  artifacts, no cheap-first ordering beyond the plan's order.
- Review call time is charged as verification overhead; there is no separate
  review budget class beyond the call and round bounds.

## Live verification of cross-review (authorized)

The user authorized live runs on 2026-10-17 ("i ahve authorized you and budget
is free for now as i have subscription"). Because subscription windows still
bound use, the run was capped at four Codex review calls, two Claude review
calls, two planner calls and two Claude Elf runs. Used: **three Codex review
calls, two Claude review calls, one planner call, one Elf run**. Claude Code
2.1.302, codex-cli 0.163.0, models `gpt-6-luna` (Codex) and `opus` (Claude).

### Reviewer adapters, direct (`tools/live_eval/iter8_review_probe.exs`)

Outside the service (no admission or records), like the earlier Codex capture.
The fixture's only test is `add(2, 2) == 4`; "seeded" implements `a * b`
(the gate passes, the contract is violated), "clean" implements `a + b`.

VERIFIED ([probe-1](live-review-probe/probe-1.json),
[probe-2](live-review-probe/probe-2.json)): every answer passed
`Review.Findings` unchanged.

| Reviewer | Seeded | Clean |
| --- | --- | --- |
| Codex `gpt-6-luna` | changes requested: 1 blocking, `calc.py:2`, "returns the product instead of the sum" (5.1 s, 175 output tokens) | approved (2.9 s, 47 tokens) |
| Claude `opus` | changes requested: 1 blocking, `calc.py:2`; 1 non-blocking on `test/test_calc.py` ("the existing test does not catch the product-for-sum mistake") (6.8 s, 693 tokens) | approved (5.0 s, 264 tokens) |

This closes the two UNVERIFIED adapter questions: `--output-schema` held
Codex to the findings schema, and the Claude review result arrived as
`structured_output`. Four cases on one tiny fixture say nothing about review
quality at large; the review-quality eval is still not built.

### Full loop with a Codex reviewer ([live-loop](live-loop/))

VERIFIED: `tools/live_eval/iter7a_work_loop.exs` with `ITER7A_MODE=live` and
`ITER7A_REVIEW=codex`, in a service node, on a new fixture under the home
directory:

- One Claude planner call (812 output tokens): one task `fix-add`, 2 attempts;
  approved as shown.
- The task was held for capacity, confirmed, and one sandboxed Claude Elf run
  (5 turns, 15.2 s, 0.0927 USD reported by the CLI) replaced
  `raise NotImplementedError` with the sum.
- The gate passed in the sandbox (`macos_seatbelt:v1:sha256:f9bb9af2…`), the
  review was requested, held (`unknown_capacity`: Codex capacity cannot be
  read yet), `follow` asked, the scripted terminal confirmed, and **one Codex
  call approved it** (51 output tokens, 2.5 s; [review events](live-loop/review-events.json)).
- The task was accepted with the review summary, the final gate passed, and
  `result` printed the review. The fixture source was unchanged; the printed
  fetch and merge in a clone gave passing tests. 95.2 s from request to
  result.
- Claude reported `allowed_warning`, five-hour utilization 0.72, seven-day
  0.84.

### Blocking review and repair, live ([live-repair](live-repair/))

The user asked for this path next ("can go ahead with this"). Cap for the run:
one planner call, two Claude Elf runs, three Codex review calls. Used: **one
planner call, two Elf runs, two Codex calls**.

The defect was **seeded**, not found in the wild: with `ITER7A_SEED_DEFECT=1`
the fixture's only test is `add(2, 2) == 4`, and the agent's instructions tell
the worker to implement `a * b` when its prompt has no cross-review section
and to fix the findings when it has one. The plan was edited once so the task
had exactly two attempts. The driver's logic was rehearsed first without a
provider (fixture reviewer, Fake Elves).

VERIFIED (`transcript.json`, `domain-events.json`, `result.json`):

- Attempt 1: one sandboxed Claude Elf run committed `return a * b`
  (`af72ab3`); the gate passed (the weak test).
- Round 1: held, confirmed, one Codex call: **1 blocking finding**, `calc.py:3`
  "add(a, b) multiplies its arguments instead of returning their sum"
  (3.8 s). The attempt was resolved `review_blocked` with `retry`.
- Attempt 2: held and confirmed like any attempt; its private worktree was
  created **from the reviewed commit `af72ab3`** (not the base `86e8f04`), and
  its prompt carried the "Cross-review of attempt 1" section with the finding.
  One Elf run committed `return a + b` (`6c07702`); the gate passed.
- Round 2 reviewed the whole task change from the original base `86e8f04`:
  held, confirmed, one Codex call: **approved** (2.5 s).
- The task was accepted at `6c07702` with the review summary; the final gate
  passed; `result` printed both rounds and the round-1 finding. Fixture source
  unchanged; the printed merge in a clone passed its tests. 203.3 s overall.
- Claude: 5 turns per run, 0.0865 and 0.0787 USD reported by the CLI;
  five-hour utilization 0.82 → 0.83 (`allowed_warning`).

The same path is now also covered hermetically with real worktrees and real
sandboxed gates (`plan_review_test` "the repair runs in a real worktree
started from the reviewed commit"), which the earlier tests skipped by
injecting the gate runner.

### Escalation and a human decision, live ([live-escalation](live-escalation/))

The user said "go ahead" with the remaining paths. Cap for the run: one
planner call, **one** Elf run, one Codex call. Used: one planner call, **two
Elf runs (one over the cap)**, one Codex call. Seeded as above, with
`ITER7A_REVIEW_MAX_ROUNDS=1` and `ITER7A_REVIEW_DECISION=accept`.

- Attempt 1: the Elf committed `a * b` but left `__pycache__/` and
  `test/__pycache__/` untracked (it ran the tests without `-B`). The gate
  refused the dirty worktree (`gate_worktree_dirty`) and the executor retried
  automatically, which is what spent the second, uncapped Elf run. This is
  pre-existing behaviour, not caused by review (the 7A live Elf happened to
  clean up). Not fixed here; a likely fix is `PYTHONDONTWRITEBYTECODE=1` in
  the Elf sandbox environment.
- Attempt 2: `a * b` committed cleanly; the gate passed; round 1: held,
  confirmed, one Codex call: 1 blocking finding at `calc.py:3`. With one round
  allowed it **escalated**: `follow` stopped and named the command.
- The driver then ran, as the human, `shoestring review list`, `show` (the
  finding and its correction) and `accept ... --reason ... --by human:user`.
  `follow` re-attached; the service applied the decision; the task was
  accepted with the review `waived` and `blocking_count` 1, and `result`
  printed the dismissed finding. The accepted commit still multiplies: that
  is what dismissing a finding means, and why it is a recorded human act.
- Claude: 4 and 5 turns, 0.0766 and 0.0840 USD reported by the CLI;
  five-hour utilization 0.90 → 0.91. Live calls stopped there.

The decision step was rehearsed first without a provider (a Claude reviewer
for the Claude Worker is unavailable, so no call is made). That rehearsal
found a real defect: right after a decision was recorded, status still
reported `needs_user?`, so a re-attached `follow` stopped again until the
service had applied it. Fixed: a review with a recorded, not yet applied
decision no longer needs the user (`decision_pending?` in the status view).
`plan_review_test` "a reviewer of the implementer's provider..." now checks
it, and fails on the unfixed code (`needs_user?` true), verified by reverting
the fix locally.

### Fan-out with review (hermetic)

`plan_fanout_review_test`: two sibling children in real worktrees with real
sandboxed `mix format` gates; each is reviewed alone (its packet holds only its
own file), the approved sibling is accepted, the blocked one is resolved
`review_blocked`/`retry` without needing the user, and the coordinator
replaces only that child: attempt 2 from the approved base, with the findings
and a prompt that says it does not start from the reviewed commit.

### Still not verified

- A defect the worker makes on its own (every live block here was seeded).
- A Claude reviewer inside the loop: it needs a Codex worker, and iteration 5
  recorded that Codex workers cannot commit in a Shoestring worktree
  (codex-cli 0.158/0.159, `05-quota-aware-mvp/live-closeout-post85.md`); not
  retried on 0.163. The Claude reviewer adapter itself was verified directly.
- A human `reject` or `retry` live (both hermetic), a held review on known
  capacity, and fan-out with review live.

## Work packages A and B: gate contracts and records

Date: 2026-10-17. Branch `iter8/gate-contracts`, stacked on
`iter8/cross-review` (`74e4679`). The user said "continue on the work and do
not wait for me".

### What was built

- **Versioned specification** (`Cobbler.GateSpec`): gate, version, source
  (`builtin` or `configuration`), kind and run order, the exact argv,
  working directory, environment allowlist (`GateSandbox.environment_names/0`),
  timeout, output limit, exit semantics (`exit_status_zero`), required, and
  artifact policy. Its identity, `<gate>@<version>:sha256:<canonical JSON
  digest>`, is recorded with every run, in acceptance evidence and in the
  review packet. Changing argv, parameters or timeout changes the identity.
- **Project-approved gates** (`config :shoestring, :project_gates`): the user,
  never a plan or model, approves extra argument-array commands with a kind,
  an optional `required: false` and timeout (at most 300 s). A plan cites
  `project:NAME` with no parameters. Entries with a path as program, an
  empty or NUL argument, a secret-looking argument, an unknown kind or key, or
  a timeout over the cap are left out. `shoestring do --gate project:NAME`
  needs the name configured at intake; a cited name no longer configured at
  run time is **unavailable** (`retry_state` `needs_user`, nothing runs),
  never passed or skipped.
- **Order and results:** gates run cheap kinds first (status, format,
  compile/lint/typecheck, build, test, precommit; plan order within a kind).
  A failed optional gate is recorded (`result` `failed`, `required` false)
  and does not block; when all of a task's gates are optional they are all
  treated as required. A failing required gate stops the run and the
  `gate_failed` event lists the gates not run (`skipped`) and a distinct
  `result` (`failed`, `timeout`, `output_oversized`, `unavailable`, `error`);
  the registry refuses a failure that claims `passed`.
- **Records** (`Cobbler.PlanGateLog`): `cobbler.plan.gate.started` and
  `cobbler.plan.gate.completed` per invocation (task and final gates), with
  spec identity, position, exact result, exit status, commit, duration,
  sandbox identity and an output artifact (`ArtifactStore`, redacted text,
  SHA-256 and size in the event). The registry refuses a completion that
  says `passed` with a nonzero exit, `failed` with exit 0, a spec of another
  gate or a short digest, an unknown gate, an artifact without digest and
  size, or task fields on a final-gate record. On a timeout or the output
  limit the output that arrived before the bound is kept (at most the cap,
  marked cut), and never enters the reason string.
- **CLI:** `follow` prints each check's start and result; `result` marks
  optional checks and names `shoestring checks GOAL`, which lists every
  invocation (task and attempt or final, kind, required, result, exit,
  duration, commit, spec) and prints one invocation's stored output with
  `--output N`.

### Defects found and fixed on the way

- **A secret-looking line in gate output made acceptance impossible.**
  Acceptance evidence stored the gate output verbatim and the event scan
  refuses secret-looking text, so a test printing `password=...` left the
  task unacceptable (`executor_append_failed`, "must not contain secrets").
  The same output went unredacted into the review packet sent to the other
  provider. Both now go through `GateOutput.redact/1` (trajectory redaction,
  then any line the stricter scan still flags is withheld, then all of it if
  needed). `plan_gate_contract_test` "gate output that looks like a secret…"
  and `plan_review_test` "gate output is redacted before…" each fail on the
  unfixed line (VERIFIED by reverting it locally: `executor_append_failed`,
  and the packet `refute`).
- **`__pycache__` left by workers** (the over-budget run above). Sandboxed
  Claude Elves, plan-run Codex Elves and gates now run with
  `PYTHONDONTWRITEBYTECODE=1`. The Codex launch test fails without the change
  (`env` nil; VERIFIED by reverting it). The Claude side is asserted on the
  sandbox's environment list only (documents the setting; no live Elf run
  since). The live Codex run below predates the Codex change and shows the
  problem: the worker removed the `__pycache__` it created by itself.

### Tests (hermetic)

`gate_spec_test` (specification fields and identity, ordering, configured
gates and refusals, all-optional rule), `plan_gate_contract_test` (real
sandboxed gates through the executor: cheap-first order, events, artifact
digest and redaction, CLI listing, optional failure, skipped gates, timeout
with partial output, unconfigured gate, registry refusals, secret-looking
output), `gate_process_test` (partial output bounds), `plan_run_env_test`,
and `review_quality_cases_test`. Apart from the two regression locks above
these are new-functionality tests and do not fail at the base commit for a
behavioural reason.

### Rehearsals (no provider call)

VERIFIED: `iter7a_work_loop.exs` rehearsal with the fixture reviewer passed
(1 of 1): `follow` printed "Running check python_unittest." and "Check
python_unittest: passed in 0.2 s." for the task and the final check, and
`mix shoestring.checks` against that state listed both invocations and
printed the stored output. The same with `ITER7A_WORKER=codex` first hung:
the driver had disabled the Codex capacity monitor, so admission had no
Codex observation; the execution job snoozed every 60 s and recorded
nothing, and `follow` printed nothing. Enabling the monitor (the product
default) fixed the driver. **Found, not fixed:** an admission that fails
before a decision (no capacity observation for the provider) is silent to
`follow`.

### Limits

- The original implementation wrote output only when the gate ended.
  The streaming follow-up below closes that deviation: a restart mid-gate
  retains recorded chunks without completion; a rerun is a new invocation.
- No built-in repository-status, lint, typecheck or build gate was added;
  those come from configured project gates. The Mix built-ins are unchanged.
- The specification's environment is the variable names, not values
  (`PATH` and the locale come from the service).
- The planner schema still offers only the built-in names; project gates
  come from the user at intake (or a human plan edit).

## Review-quality eval (live, authorized)

Cases: `tools/live_eval/review_quality/cases.json`, 13 cases on small Python
fixtures, **8 seeded defects** (correctness: exclusive range, floor-division
mean; tests: a deleted out-of-range test with the check missing; security:
path traversal, shell injection; concurrency: lost update; scope: an
unowned settings file; error handling: swallowed errors) and **5 clean
controls** for the same contracts. Every case's tests pass (so only review
can tell them apart), checked hermetically by `review_quality_cases_test`.
Labels were written with the cases, by construction, by the agent. The user
confirmed all 13 labels on 2026-10-19 (see the human acceptance record below). Driver:
`tools/live_eval/iter8_review_quality.exs`, one call per (reviewer, case),
outside the service, with a hard call budget.

Budget: 13 Codex and 13 Claude calls. Used: **13 Codex calls, 13 Claude
calls**, every answer schema-valid.

VERIFIED ([codex](review-quality/codex/summary.json),
[claude](review-quality/claude/summary.json), per call `results.json`):

| Reviewer | Defects found at the labelled path (and line ±2) | Clean controls blocked | Findings with a valid reference | Non-blocking findings | Output tokens | Time |
| --- | --- | --- | --- | --- | --- | --- |
| Codex `gpt-6-luna` | 8 / 8 (8 / 8) | 0 / 5 | 9 / 9 | 0 | 2 090 (261 per found defect) | 49.5 s |
| Claude `opus` | 8 / 8 (8 / 8) | 0 / 5 | 23 / 23 | 8 | 11 098 (1 387 per found defect) | 130.3 s |

What this does and does not show: each contract states the requirement the
defect breaks in plain words, and every fixture is a few lines. So this
measures whether a reviewer checks a small diff against an explicit
contract, which both did perfectly, not recall on subtle or unstated defects
or on large diffs. On 2026-10-19 the user explicitly labelled all 8 Claude
non-blocking findings and 5 suggestions useful. [Human labels](review-quality/human-labels.json)
record **8/8 useful non-blocking findings**, **5/5 useful suggestions**,
**13/13 combined**; the original entries have `useful: true`. This is human
judgment on these entries, not an LLM judge or a general precision estimate.
The budgeted follow-up below expands the original single repair sample.

## A Claude reviewer in the full loop (live)

The Codex commit block from iteration 5 was re-probed first without a model
call (codex-cli 0.163.0, `codex sandbox` in workspace-write mode, from a
Shoestring private-storage worktree): `git commit` is **denied** without
extra writable roots (`index.lock: Operation not permitted`, as in iteration
5) and **succeeds** with the roots Shoestring gives plan runs
(`CodexAppServer.GitSandbox`: the worktree's git dir, objects and refs),
with a warning about `packed-refs.lock`. Manual `/runs/new` Codex runs share
Git storage, get no such roots, and were not re-tested.

Then one live loop ([live-claude-reviewer](live-claude-reviewer/)), with
`ITER7A_MODE=live ITER7A_WORKER=codex ITER7A_REVIEW=claude`. Cap: one
planner call, at most two Codex Elf runs and two Claude review calls (the
driver approves at most two attempts). Used: **one planner call (Claude, 815
output tokens), one Codex Elf run, one Claude review call**.

VERIFIED (`transcript.json`, `domain-events.json`, `codex-worker.json`,
`result.json`):

- The plan was edited once by the driver's rule (attempts capped) and
  approved; the task was held for capacity (Codex confidence medium),
  confirmed, and **one Codex Elf run (`gpt-6-luna`) committed** the change
  itself (`git add calc.py && git commit -m "Implement calc.add"`, exit 0) in
  its private worktree. It also created `__pycache__/` and removed it before
  finishing.
- The gate passed in the sandbox with its spec identity
  (`python_unittest@1:sha256:20ea1e63…`); review was requested, held
  (`support_tier_conservative_partial`), confirmed, and **one Claude `opus`
  call approved it** (236 output tokens, 3.6 s).
- The task was accepted at `a627eee`, the final gate passed, `result` printed
  the review; the fixture source was unchanged and the printed merge in a
  clone passed its tests. 126.3 s overall.

This closes "a Claude reviewer inside the loop" and shows a Codex Worker
committing in a plan worktree at 0.163.0 for one small task.

### Still not verified

- A defect the worker makes on its own: every live block was seeded, and
  this loop's worker made none.
- A human `reject` or `retry` live, a held review on known capacity, and
  fan-out with review live.
- Linux gates (fail closed), streaming gate output, and the review-quality
  numbers beyond these 13 small, explicit cases.

## Fixes after the user's review (2026-10-17)

The user asked to fix the two found issues ("fix the issues. Linux can be
solved later").

- **Silent wait on admission.** When `ExecutionAdmission.admit/4` fails
  before any decision (no capacity reading for the provider, or the reading
  cannot be localized), it now records `cobbler.plan.admission.waiting`
  once per attempt and reason (idempotency key), and `follow` prints "Task
  T is waiting: no capacity reading for P yet ... check that the P CLI is
  installed and signed in and that its capacity monitor is enabled". The
  job still retries every 60 s; nothing is admitted without a reading.
  `execution_admission_waiting_test` fails on the unfixed code (no event;
  VERIFIED by reverting the call locally).
- **Manual `/runs/new` runs.** Claude and Codex manual runs now create their
  worktree with private per-run Git storage (recording the source
  repository in the worktree metadata), so Codex gets the Git roots it needs
  to commit (probed above) and a manual Claude run in such storage is
  launched with the same sandbox as a plan run (`ElfEffect`). Runs in shared
  storage (Fake manual runs, and runs created before this change) keep their
  previous launch, because the sandbox refuses them. The goal page shows the
  source repository, the private copy and the `git fetch` to take the
  commits. `run_new_private_storage_test` fails on the unfixed `/runs/new`
  (no private storage; VERIFIED by restoring the previous file locally).
  Not verified live: no manual Claude or Codex run was started.

## Acceptance follow-up (2026-10-19)

VERIFIED: the admission/manual-run fix round passed
`timeout 590 mix precommit < /dev/null`: **4 doctests, 2277 tests, 0 failures,
1 skipped, 6 excluded**, seed **124889**, 523.4 s for ExUnit. JavaScript:
**52/52** Gate 0A tests and **8/8** UI tests. This replaces the stale
2275-test gate figure for the fix round; it does not verify the later
streaming implementation.

VERIFIED against the `e79fc8d` versions of `execution_admission.ex` and
`run_new_live.ex`, with both new tests present: **2 tests, 2 failures**, seed
790774. The waiting test fails because no waiting event exists (`right: []`);
the manual-run test fails because the source metadata is absent (`left:
nil`). The fixed files were restored byte-for-byte afterward, and the same
two files passed: **2 tests, 0 failures**, seed 108170.

VERIFIED (human decision in this handover): the user confirmed all four
defaults originally recorded as conservative readings above:

- Review stays off by default (`config :shoestring, :plan_review`).
- Different provider means a different provider family: Claude and Codex;
  two models from the same vendor do not count.
- Unavailable review waits for a human waiver, rejection or retry. No
  self-approval or silent bypass is allowed while review is enabled.
- The default review-round bound is 2 (maximum 3), with at most 2 calls per
  review; repairs spend the task's ordinary attempt budget.

VERIFIED (human decision in this handover): the user confirmed the 13
review-quality case labels (8 seeded defects and 5 clean controls) as written.
This supplies human confirmation of those labels, not evidence that the
small fixtures measure general review quality.

VERIFIED (live authorization): the user authorized a hard ceiling of
**4 planner calls, 12 worker runs (including manual runs), and 16 reviewer
calls** for this follow-up. A local, process-safe executable wrapper charges
before launch and refuses exhausted or unclassified calls. Its hermetic
probe admitted exactly 1 of 6 concurrent fake worker invocations, refused
the other 5, and checked planner/reviewer classification and the shared
cross-provider reviewer ceiling. No live calls were used by that probe.

VERIFIED (human labels): the user explicitly answered "Yes, mark all 13
useful" for the Claude advisory entries. Only their `useful` fields changed;
the captured claims and evidence remain unchanged. Codex has no entries to
label. The following live records close reject/retry, sibling fan-out,
additional repair measurements and both post-fix manual runs. The narrower
unseeded blocking-review check is recorded separately below.

Linux remains deferred and fails closed. Built-in worker checks do not
accept a task; Shoestring's recorded gates do, with other project commands
configured through `:project_gates` and cited as `project:NAME`.

### Streaming implementation

REPO-INSPECTION: real gate output now goes through an incremental,
line-buffered redactor into immutable `ArtifactStore` chunks as it arrives.
`cobbler.plan.gate.output` v1 links each chunk to its invocation, scope,
specification and ordered chunk number, recording artifact id, size and
SHA-256. Incomplete lines and credential labels wait for more bytes or the
end of the invocation, preventing secrets split across chunks or newlines
from being persisted. Invalid UTF-8 is withheld. The existing raw byte cap,
timeout and owned process-group termination remain in force; a chunk write
failure fails the gate rather than accepting without its output.

`shoestring checks GOAL --output N` reads the recorded chunks before
completion (explicitly marked partial) and the complete artifact afterward.
An interrupted invocation retains its chunks without claiming completion;
the next invocation has a new id and separate output. This supersedes the
earlier package B streaming deviation once its full gate passes.

VERIFIED: targeted hermetic coverage passed **23 tests, 0 failures**, seed
318568. It covers a real sandboxed task gate held open while its artifact
and CLI output are inspected, the final-gate twin, interrupted invocation
output, strict chunk event validation, artifact failure, timeout and
overflow flushing, every credential split point and bytewise UTF-8 input.
The manual-run suite now also checks Codex private roots and Fake shared
storage using resolved macOS paths.

VERIFIED regression lock against the `0cfaa08` library source versions:
the before-completion integration test failed because no
`cobbler.plan.gate.output` event arrived while the gate was held open
(**1 test, 1 failure, 10 excluded**, seed 130597). The streaming sources
were restored byte-for-byte afterward. The first full-gate invocation then
stopped at formatting (two test files; no tests ran); those exact formatter
changes were applied before the next full gate.

VERIFIED: the streaming implementation passed
`timeout 590 mix precommit < /dev/null`: **4 doctests, 2288 tests, 0 failures,
1 skipped, 6 excluded**, seed **195766**, ExUnit **534.6 s**. JavaScript:
**52/52** Gate 0A tests and **8/8** UI tests. The package B streaming
deviation is now closed; partial-line buffering remains an explicit
redaction constraint.

### Budgeted live follow-up

VERIFIED: [live-budget.json](live-budget.json) records **4/4 planner calls,
12/12 worker runs, 10/16 reviewer calls**. The failed reviewer delivery and
failed worker are charged. No further worker run is authorized by this
budget. Installed versions were Claude Code **2.1.303** and Codex **0.163.0**.

- **Manual runs:** [Claude](live-manual-postfix/claude.json) and
  [Codex](live-manual-postfix/codex.json) each completed, made one commit in
  private Git storage, and passed the reference test. Each source remained
  unchanged. These invoke the real `/runs/new` event handler programmatically,
  without expert bypass or a plan binding; browser interaction was not part
  of this live probe. Claude requested the product sandbox; Codex committed
  using the five private Git roots.
- **Retry:** [events](live-human-retry/domain-events.json) and
  [transcript](live-human-retry/transcript.json) show one planner, one worker,
  and two reviewer invocations. The first real Codex response was deliberately
  discarded by the quota wrapper to inject a delivery failure. The failed
  review accepted nothing; the scripted, user-authorized `human:user` operator
  recorded `retry`, confirmed the next call, and the second call approved.
  Task and final gates passed; source unchanged and the integration clone's
  test passed. The injected failure is not an unseeded review defect.
- **Reject:** [events](live-human-reject/domain-events.json) and
  [transcript](live-human-reject/transcript.json) show one planner, one worker
  and one review. Codex blocked the seeded multiplication defect. The
  user-authorized operator recorded `reject`; the review became rejected,
  the task remained unaccepted and the goal needed a decision. No merge or
  replacement worker followed.
- **Repair samples:** [sample 1](live-repair-sample-1/result.json) and
  [sample 2](live-repair-sample-2/result.json) each used one planner, two
  workers and two reviews: seeded defect blocked, repaired from its reviewed
  commit, approved in round 2, final gate and clone test passed, source
  unchanged. Together with the previously recorded loop,
  [repair-rates.json](repair-rates.json) measures **3/3 successful repairs**
  and **0/3 repeated blockers** in rereview, using **607 review output
  tokens**. These are three small seeded `calc.add` trials, not an estimate
  for general defects.

### Unseeded fan-out failure and session-index ownership

VERIFIED: the first live review-enabled fan-out
([failure event](live-fanout-before-fix/failure-event.json)) failed with
`transport/session_not_found` for one child after the sibling completed.
The failed trial is retained as a failure. A read-only process-group probe
confirmed that neither owned worker group remained live afterward; no
cleanup or duplicate run was started against that state.

REPO-INSPECTION: both Claude and Codex created their named ETS session
index in whichever caller reached it first. That caller's normal exit
deleted the whole index, hiding other live sessions. The fix introduces
`Harness.SessionTables`, supervised before the execution workers, to own
both indexes independently of callers. Confirmed-dead session PIDs are
reported missing; live missing sessions still fail closed. No timer,
eviction, cancellation, automatic replacement or provider backfill was added.

VERIFIED: the final ownership regressions against the `6248bf7` application
and adapter source versions fail for the behavioral reason above:
**2 tests, 2 failures**, seed **644969**, each returning
`session_not_found` while its session still answers. Fixed sources were
restored byte-for-byte. Focused ownership, missing-session, startup and
isolation coverage passed **11 tests, 0 failures**, seed **377349**.

VERIFIED: a fresh post-fix [sibling fan-out](live-fanout-after-fix/fanout.json)
had **2 live Elves concurrently**, two separate approved Codex reviews,
both `north` and `south` accepted, an unchanged source and **0 outstanding
reservations**. [Scope](live-fanout-after-fix/scope.json): the join phase was
not run after the 12-worker ceiling was reached; the fixture goal is not
reported completed. This new post-fix trial is separate from the retained
failed trial.

The session-index defect was found naturally by the live run and reproduced
without providers. It is a runtime defect, not a blocking cross-review
finding after green gates. That narrower item is now verified separately
below by the authorized tool-free review of the real streaming diff.
Automatic approval review initially rejected that call pending permission
for its particular real-code payload and Claude destination. The user then
explicitly authorized this exact packet; it was sent once after that answer.
The user also supplied all 13 advisory usefulness labels.

VERIFIED: after the ownership fix, `timeout 590 mix precommit < /dev/null`
passed **4 doctests, 2293 tests, 0 failures, 1 skipped, 6 excluded**, seed
**140493**, ExUnit **524.4 s**; JavaScript **52/52** and **8/8**. Earlier,
before that fix, the live-tool gate passed **2291 tests**, seed **704030**,
**529.1 s**, with the same doctest, failure, skip, exclusion and JavaScript
counts. A preceding tool-gate invocation stopped at one formatter change
before tests; that exact change was applied and checked separately.

Follow-up evidence identifiers: UUIDs are substituted consistently across
the new exports with synthetic UUIDs preserving their version and variant.
Apart from those identifier substitutions, exported captures are byte-for-byte
unchanged. The drivers already replace their own root and home with
`$EVALUATION` and `$USER_HOME`; native local evidence is retained. No provider
frames or reasoning are included. The reusable quota guard and live drivers
are under `tools/live_eval/`; the guard's fake-executable coverage passed
**3 tests, 0 failures**, seed **724750**.

### Collector bounds and integration command quoting

REPO-INSPECTION: streaming initially invoked artifact storage in the raw
port collector. A stalled sink could prevent it enforcing the execution
deadline and byte cap. A supervised task now serializes sink writes, with
queued raw bytes bounded by the same output cap. The collector keeps
checking its deadline between port messages, stops the owned command before
waiting for persistence, and requires sink completion before success. A
failed command gets at most 500 ms to drain partial chunks, then its sink
is stopped; no sink failure can accept a task.

REPO-INSPECTION: fetch instructions on the manual goal page and cd/fetch
instructions in `shoestring result` now share POSIX argument quoting.
Spaces, apostrophes, metacharacters and empty arguments round-trip as one
argument; safe branch names remain readable.

VERIFIED: focused streaming, shell, goal-page and gate-contract coverage
passed **37 tests, 0 failures**, seed **876187**. The first focused run
failed one newly added CLI fixture because the low-level execution request
omitted the repository path that production persists; that fixture was
corrected, without changing the CLI assertion. The four final regressions
against the `967c72a` GateProcess, CLI Result and goal template source
versions then failed behaviorally: **4 tests, 4 failures, 32 excluded**,
seed **848779**. Both held callbacks prevented a bound result, and both
displayed commands lacked quotes. The fixed sources were restored
byte-for-byte.

### Unseeded review after green gates

VERIFIED: the user authorized the exact [packet](live-unseeded-review/packet.json),
digest `43bb3b09a9d0657b3b57fd87bad40ddfcee579c135266745288874929a130c2b`,
for one external Claude Opus review. It contains the real `0cfaa08` →
`6248bf7` streaming change and its green gate evidence, with no seeded
mutation and no implementation transcript. The exported packet is
byte-identical to the input. The [validated result](live-unseeded-review/result.json)
records **1 blocking finding**, 2 non-blocking findings and 1 suggestion,
**7063 output tokens**, **68845 ms**, `changes_requested`. The tool-free,
empty-directory call used `opus`, high effort, no MCP servers or session
persistence, closed stdin and the shared budget fence. A local wrapper
required exactly one `structured_output` object before the product findings
validator ran; no prose fallback or raw provider frames were retained.

The Claude Opus review skill was applied with the user's narrower contract:
only the authorized packet was exposed, no repository tools; the product's
findings schema and severities were retained. No additional code or live
worker call was sent. The reviewer was an independent source of hypotheses,
not the final authority on those findings.

- **F1 VERIFIED, fixed:** invalid UTF-8 in complete lines bypassed the
  credential-label hold, losing the label before its value arrived in a later
  artifact. The hold now uses the byte-mode regex even on invalid UTF-8.
- **F2 independently checked, adjacent fix:** neither existing whole-output
  redactor recognizes PEM blocks, so the specific PEM example does not show
  a new regression. Inspection did identify a real recognized cross-line
  pattern omitted by streaming: Basic authentication. `Basic` is now held
  like `Bearer`. Tests check all split points, invalid-byte prefixes and
  the absence of values while preserving safe text on both sides.
- **F3 evidence scope:** the frozen diff predates the committed budget guard,
  guard tests, dated human confirmation and live ledger now present on this
  branch. The standing contract also permits command output from this run
  as evidence. This did not establish a code defect. The captured review is
  retained unchanged, and the human record now has an explicit date/source.
- **F4 not reproduced:** `field_type/2` defaults to `:string`, and Ecto
  rejects non-string SHA values before the regex clause. The malformed-chunk
  test now exercises integer, nil, list and map digests; all fail closed.

VERIFIED regressions against the unchanged `967c72a` streaming-redactor
source: **2 tests, 2 failures, 3 excluded**, seed **198040**, each leaking the
synthetic value for the expected behavioral reason. After the two fixes,
focused coverage passed **42 tests, 0 failures**, seed **209148**. The full
final gate is recorded below. This is one unseeded review
sample, not a recall estimate. The fix was implemented and verified
hermetically; no additional live repair worker or rereview was claimed.

### Final gate and publication

VERIFIED: `timeout 590 mix precommit < /dev/null` passed: 4 doctests, 2300 tests, 0 failures, 1 skipped, 6 excluded, seed 830891; ExUnit 548.5 s. JavaScript Gate 0A 52/52, UI 8/8.

The human decisions, seeded case labels and 13 advisory usefulness labels
are complete. Remaining scope limits are explicit: Linux is deferred and
fails closed; the live sibling fan-out did not run its join after the worker
ceiling; three seeded repairs and one unseeded review are small samples.
The local milestone completion record is updated in this isolated worktree
and remains gitignored by design. Acceptance and merges remain human work,
in order #93 → #94 → #95 → #96.

Publication follows the brief: the PR uses its explicitly requested Claude
Code footer; Git commit messages have no attribution trailers.

### Explicit Linux deferral and merge authorization (2026-10-19)

VERIFIED (human decisions): the user explicitly deferred Linux acceptance-gate
sandbox implementation beyond iteration 8, then authorized the agent to merge
the stack. Linux support is not an iteration 8 acceptance blocker. The
[deferral plan](linux-sandbox-deferred.md) records its scope, resumption
trigger and future verification requirements. No later milestone or delivery
date is assigned. Linux continues to fail closed; no Linux backend or Linux
verification is claimed.

The explicit merge request supersedes the earlier human-only merge rule for
PRs #93 → #94 → #95 → #96. It does not authorize bypassing required checks,
change other acceptance limits or increase the provider-call budget.

### macOS CI environment repair

VERIFIED: the [pre-repair GitHub CI run](https://github.com/anukin/shoestring/actions/runs/39302660537)
for `2252326` reported **4 doctests,
2300 tests, 35 failures, 1 skipped, 6 excluded**, seed **189491**, **544.4 s**.
This was a macOS run, not a consequence of deferring Linux. Most failing
acceptance paths reported `toolchain_under_home`; the streaming test also
failed with `enoent` because GNU `timeout` was absent. The local passing gate
above is not a claim that this CI run passed.

REPO-INSPECTION: setup-beam installs into `RUNNER_TEMP/.setup-beam`, which
defaults under the runner's home. GitHub reserves `RUNNER_TEMP`, so CI copies
the installed macOS toolchains to a fresh temporary root outside home and
selects the runner image's existing Homebrew Python. It
checks the resolved executable locations before running the full precommit
gate, including both JavaScript suites. The streaming test uses Python's
bounded subprocess call to release its FIFO, retaining the two-second bound
without a GNU coreutils dependency. No sandbox permission is relaxed.

The official [setup-beam source](https://github.com/erlef/setup-beam/blob/v1/src/setup-beam.js)
and [runner image Python setup](https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/install-python.sh)
define those installation boundaries; GitHub's [variable rules](https://docs.github.com/en/actions/reference/workflows-and-actions/variables)
explain why the runner's temporary-directory variable is retained. The
relocated versions are checked before the gate. Results of the repaired workflow are
recorded on PR #96; they must be observed before claiming CI success.

VERIFIED local repair validation: `timeout 590 mix precommit < /dev/null`: 4 doctests, 2300 tests, 0 failures, 1 skipped, 6 excluded, seed 110814; ExUnit 522.7 s. JavaScript Gate 0A 52/52, UI 8/8. Focused sandbox and streaming
coverage passed **22 tests, 0 failures**, seed **600343**. Workflow YAML, shell
and embedded Python syntax checks passed. [Local gate record](ci-repair-local-gate.json)
is distinct from GitHub runner verification.

VERIFIED GitHub repair trial on `e579d80`: the
[push run](https://github.com/anukin/shoestring/actions/runs/39336019762)
passed the full gate and production release: **4 doctests, 2300 tests,
0 failures, 1 skipped, 6 excluded**, seed **4367**, ExUnit **662.7 s**.
The [pull-request run](https://github.com/anukin/shoestring/actions/runs/39336027270)
hit the outer **12-minute CI step limit**, seed **477618**, before an
ExUnit completion summary. No complete test counts are claimed for it.
The step-duration failure was **intermittent, 1 of 2 runs**; it is not
reported as a passing run or as a known test flake. Cold compilation plus
the successful suite used almost the entire 12-minute allowance.

REPO-INSPECTION: the CI step now has a **20-minute** outer budget within
the existing **30-minute** job bound. Application code, test assertions,
per-test timeouts and product-gate deadlines are unchanged. This corrects
the CI execution budget; the old job is retained rather than rerun until
green. Verification of the new workflow head is recorded on PR #96.


### Deterministic setup for the two intermittent CI failures

VERIFIED on `e2e5b4e`: the [push job](https://github.com/anukin/shoestring/actions/runs/39337742681)
passed 4 doctests, 2300 tests, 0 failures, 1 skipped, 6 excluded, seed
695985, ExUnit 833.0 s, JavaScript 52/52 and 8/8, and the production release.
The [PR job](https://github.com/anukin/shoestring/actions/runs/39337748902)
completed with 4 doctests, 2300 tests, 2 failures, 1 skipped, 6 excluded,
seed 116119, ExUnit 935.5 s; JavaScript 52/52 and 8/8 passed, release skipped.
Intermittent, 1 of 2 current-head runs. No failed job was rerun until green.
The user requested fixes for both failures before proceeding with merges.

REPO-INSPECTION: the planner test raced reservation/database work and adapter
startup against a 100 ms readiness-message assertion. Its domain assertions
now execute in the fixture's inference task after reservation commits; the
outer test requires both a completion marker and the ready result. The
same/other-goal global-claim twin uses this boundary too. Existing lost-result
restart tests retain their separate await/kill protocol. Real provider
adapters are unchanged; this is a trusted hermetic fixture response.

REPO-INSPECTION: the Observatory test polled the shared SQL connection during
Elf launch and granted its lease after event consumption had begun. It now
enqueues intent and grants/projects the lease before starting the Elf, then
waits for the committed `run.running` event through PubSub. The event supplies
the owned process group for existing teardown without a teardown SQL query.
Renewal, completion, checkpoint, projector and ledger assertions are retained.
No timeout value is increased, no sleep or retry is added, and no test is
skipped.

VERIFIED: the focused planner/amendment/Observatory suite passed 52 tests,
0 failures, seed 116119 (4.3 s) after the setup refactor. Completion-marker
assertions were then added and are covered by the full gate below. API-compatible
mutation checks on the `e2e5b4e` application source still fail for the intended
behavior: removing the in-flight amendment guard records an amendment during
initial inference (1 test, 1 failure, 12 excluded); bypassing snapshot
localization causes zero renewals and a failed terminal projection (1 test,
1 failure, 9 excluded). Both used seed 116119. Modules were restored before
the full gate. These are mutation checks, not claims of reproducing the CI
scheduler/load defect against a pre-fix commit.

An initial whole-module check using the historical `d3fa152` renewal module
was rejected as regression evidence because it lacks the current Elf's
`renew_only/3` API. The compatible localization mutation replaces that check.
UNVERIFIED: the original GitHub scheduler/SQL load was not reproduced
locally. [Exact CI outcomes, setup changes and defense checks](deterministic-ci-tests.json)
retain that limit. Full-gate and current-head CI results follow when observed.

VERIFIED: `timeout 590 mix precommit < /dev/null` passed: 4 doctests, 2300 tests, 0 failures, 1 skipped, 6 excluded, seed 726040; ExUnit 523.5 s. JavaScript Gate 0A 52/52, UI 8/8.
New-head GitHub verification and the authorized stack merges remain pending.


### Isolated CLI continuation integration investigation

VERIFIED on `d59f0b6`: [push CI](https://github.com/anukin/shoestring/actions/runs/39342344422)
passed the full gate and production release: 4 doctests, 2300 tests, 0 failures,
1 skipped, 6 excluded, seed 475512, ExUnit 727.2 s; JavaScript 52/52 and 8/8.
[PR CI](https://github.com/anukin/shoestring/actions/runs/39342348533)
reported 4 doctests, 2300 tests, 1 failure, 1 skipped, 6 excluded, seed 705933,
ExUnit 743.3 s; JavaScript 52/52 and 8/8 passed, release skipped. Both earlier
planner/Observatory failures passed. Intermittent, 1 of 2 current-head CI runs.

The remaining failure is the isolated CLI integration: the resumed task
should leave alpha accepted before restart, but the accepted list was empty.
UNVERIFIED: the original log does not show the terminal/gate reason. No root
cause or production fix is claimed by this diagnostic change.

VERIFIED local investigation: one instrumented child run passed 2 tests,
0 failures, seed 0 (8.9 s), showing a completed continuation, passing gate and
accepted alpha. Three predefined, concurrently isolated scheduler-pressure
trials each passed their one outer test, seed 705933 (11.4, 11.4, 11.5 s).
The new failure-evidence assertions passed one outer test, seed 705933
(10.1 s). These are diagnostic runs, not retry-until-green acceptance or
proof that the original failure is resolved.

The test now checks continuation completion and dispatch of beta explicitly,
retains its alpha acceptance assertion, and attaches the scoped canonical
terminal/gate events and already-recorded output to any failure. A deliberately
wrong fixture greeting assertion made the real gate fail (exit 2), retried
alpha, and printed that gate output and retry evidence: one outer test,
one failure, seed 705933. The fixture mutation was restored. This validates
the diagnostics; it is not a reproduction of the original CI defect.
No timeout is increased, and no sleep, retry or skipped test is added.

[Investigation record](integration-diagnosis.json) preserves all outcomes.
A full `mix precommit` with the failed CI seed configured through the Erlang
application environment is running at diagnostic publication. No merge is
claimed while investigation and verification remain open.


### Lost-inference restart twin follow-up

VERIFIED on diagnostic head `d514ffa`: local full gate with the failed
integration seed (`ERL_FLAGS='-ex_unit seed 705933' timeout 590 mix precommit < /dev/null`)
passed 4 doctests, 2300 tests, 0 failures, 1 skipped, 6 excluded, seed 705933;
ExUnit 540.4 s; JavaScript 52/52 and 8/8.
[Push CI](https://github.com/anukin/shoestring/actions/runs/39348799091)
passed the same counts, seed 505749, ExUnit 621.0 s, both JavaScript suites
and the release. [PR CI](https://github.com/anukin/shoestring/actions/runs/39348803521)
reported 4 doctests, 2300 tests, 1 failure, 1 skipped, 6 excluded, seed 860663,
ExUnit 652.5 s; JavaScript 52/52 and 8/8 passed, release skipped. The
integration scenario passed in both runs. Its original root cause remains
UNVERIFIED; passing diagnostics are not a production fix.

The PR failure was another planner readiness race: the lost-amendment restart
test still waited 100 ms for the fixture to start. Intermittent, 1 of 2 runs
on that head. The previous fixture-boundary fix had left the two restart
protocols unchanged. Both are now synchronized on actual caller loss:
the fixture kills the inference caller after reservation, the test awaits
its exit, verifies the adapter remains supervised, and then stops/restarts
the adapter supervisor. Lifetime charge, request state, active claim, replay,
adapter shutdown and exactly-one-inference checks remain. No readiness timer
is widened; Task's existing default wait bounds the lifecycle synchronization.
No sleep, retry or skipped test is added.

VERIFIED: focused planner/amendment/integration coverage passed 43 tests,
0 failures, seed 860663 (13.2 s). Making a running request start inference
again on the `d514ffa` planner source fails both exact restart tests:
2 tests, 2 failures, 40 excluded, seed 860663 (0.7 s), returning `finished`
instead of `replayed`. The module was restored. This is a behavioral mutation
check of the retained guards, not a reproduction of scheduler timing against
a pre-fix commit. An earlier line-selector probe selected the preceding tests
and is excluded from that claim. Full-gate and new-head CI verification are
pending at publication; merges remain unclaimed.


### Approved writer idle-test wait exception

VERIFIED on `89d2273`: the local full gate with seed 860663 passed
4 doctests, 2300 tests, 0 failures, 1 skipped, 6 excluded (539.2 s);
JavaScript 52/52 and 8/8.
[Push CI](https://github.com/anukin/shoestring/actions/runs/39370825238)
passed the same counts, seed 674399 (697.8 s), both JavaScript suites and
the production release.
[PR CI](https://github.com/anukin/shoestring/actions/runs/39370829648)
reported 4 doctests, 2300 tests, 1 failure, 1 skipped, 6 excluded,
seed 221128 (773.3 s); JavaScript 52/52 and 8/8 passed, release skipped.
Planner restart and isolated integration scenarios passed in both runs.
The original integration root cause remains UNVERIFIED.

The sole PR failure found the writer's matching normal-exit notification
just after its 100 ms assertion deadline: intermittent, 1 of 2 CI runs.
The user explicitly approved “Allow the 1-second test wait”, overriding
the global prohibition on widening assertions for this single assertion.
Only that wait changes to 1,000 ms. The product idle timer stays at zero;
normal exit and registry unregistration remain required. No product behavior,
other timeout, retry, sleep or skipped test changes.

VERIFIED focused check: `timeout 120 mix test test/shoestring/trajectory/writer_test.exs --seed 221128 < /dev/null`
passed 5 tests, 0 failures, seed 221128 (0.1 s). This is verification of the
approved test tolerance, not a production regression fix or reproduction
of GitHub scheduler load. [Exact preceding CI and approval record](writer-idle-wait.json).
The full gate and new-head CI remain pending at publication.


### Post-merge writer monitor race

VERIFIED: PRs #93, #94, #95 and #96 merged in order into `main` after
the local full gate and both current-head CI runs passed. Main `265937f`
had exactly the tested `3b6b483` tree. Local: 4 doctests, 2300 tests,
0 failures, 1 skipped, 6 excluded, seed 221128 (529.9 s), JavaScript
52/52 and 8/8. Push CI 39372626890 passed the same counts, seed 367701
(532.2 s); PR CI 39372633293 passed, seed 818134 (659.8 s); both
JavaScript suites and production releases passed. Merge messages were
inspected without attribution trailers. The user's explicit merge request
overrides the standing human-only rule for this iteration's delivery.

VERIFIED: [post-merge main CI](https://github.com/anukin/shoestring/actions/runs/39373948837)
failed: 4 doctests, 2300 tests, 1 failure, 1 skipped, 6 excluded,
seed 383203 (585.9 s); JavaScript 52/52 and 8/8 passed, release skipped.
The sole failure is the writer lifecycle test: its monitor received
`:noproc`, proving that monitoring started after the writer had exited.
Intermittent, 1 of 3 CI runs on that tree (two pre-merge, one post-merge).
This differs from the preceding late-normal-notification failure. Increasing
the wait again would not address it.

The test now starts the supervised writer with its timer disabled, installs
the monitor, sets that test writer's idle interval to zero, and performs a
normal append to arm the real timer. Normal exit and registry unregistration
remain required; the user's approved 1,000 ms wait is retained unchanged.
No production code, retry, sleep, skipped test or further timeout extension
is introduced. The append idle-disappearance/recovery twin was also checked.

VERIFIED focused lifecycle coverage: 18 tests, 0 failures, seed 383203
(0.4 s). On the `265937f` production source, mutating the valid idle handler
to ignore expiry made the exact test fail: 1 test, 1 failure, 4 excluded,
seed 383203 (1.1 s). The mutation was restored. This defends the retained
real-idle shutdown assertion; it is a test setup correction, not a new
production regression lock or reproduction of scheduler timing.
[Exact outcomes and limits](writer-monitor-race.json).
Full-gate and follow-up PR CI verification remain pending at publication.
The original isolated integration root cause remains UNVERIFIED.
