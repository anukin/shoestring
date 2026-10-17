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

Not verified live: a blocking review in the loop and the repair that follows
(the Elf made a correct change, so there was nothing to send back), a Claude
reviewer inside the loop, a held review on known capacity, and fan-out with
review.
