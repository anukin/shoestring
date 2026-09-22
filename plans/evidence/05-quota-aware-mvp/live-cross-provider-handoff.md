# Live cross-provider handoff, semantic continuation, and cancellation

Date: 2026-09-21. Branch `polly/iter45-live-verification`, base
`6f1653fed931d120d463676ec40e95e6b8ad7327`.

This is the bounded live-verification closeout for the two items iteration 5
left explicitly unmet — *no real cross-provider handoff* and *no real semantic
evidence* — plus an explicit owned-process cancellation, and the iteration-4
post-fix Codex turn recorded separately in
`plans/evidence/04-single-elf/harness-live-verification.md`.

**It does not declare iteration 5 complete, and it does not unlock iteration
6.** It closes two of the recorded gaps and opens three new ones. See
[§8](#8-what-is-still-unmet).

Claim labels follow this directory's `README.md` (`VERIFIED`,
`REPO-INSPECTION`, `SCHEMA-ONLY`, `UNVERIFIED`), plus
`OPERATOR-OBSERVED-NOT-CAPTURED` from `04-single-elf/README.md` §6 for claims
about a value that redaction removed.

---

## 1. Authorization, budget, and shape of the run

The operator explicitly authorized real Codex and Claude usage on
authenticated subscription accounts with no monetary cap, scoped to **one
disposable, self-contained Go CLI Tic-Tac-Toe goal** and only the turns the
acceptance items below require. No unrelated live call was made.

Everything ran through the real product surfaces — `Shoestring.Elves`,
`Shoestring.Cobbler.Handoffs` / `HandoffWorker`,
`Shoestring.Harness.DispatchWorker`, `Shoestring.Harness.Dispatch.ElfEffect`,
the real `CodexAppServer` and `ClaudeHeadless` adapters — driven by a
disposable operator script. **No provider CLI was invoked directly**; every
provider process was spawned, owned and reaped by an Elf.

Profile: `MIX_ENV=test` with an explicit `SHOESTRING_TEST_STATE_DIR` under the
platform temp root, so background dispatch/wakeup/handoff reconcilers and the
supervised capacity monitors stayed off and Oban executed nothing on its own.
Every worker invocation below is a deliberate, named call on the real worker
module with the real persisted job row.

The goal workspace was a throwaway git repository containing an empty Go
module (`example.com/tictactoe`, one baseline commit). Each run got its own
Shoestring-managed worktree; the receiver deliberately inherits the sender's
`workspace_ref`, so both providers worked in the *same* worktree.

The user's source checkout was never modified (VERIFIED: `git status --short`
in the checkout before and after shows only the two untracked paths that were
already there).

## 2. Live legs

| # | Leg | Provider | Terminal | Normalized events | Wall clock |
|---|---|---|---|---|---:|
| 1 | Sender: build the core `game` package | Codex (`codex_app_server_stdio`) | `completed` | 374 | 166 444 ms |
| 2 | Receiver, default policy | Claude (`claude_headless_stream_json`) | **none** — `run.suspended` at the lease boundary | 2 | see §6.3 |
| 3 | Receiver, operator policy | Claude (`claude_headless_stream_json`) | `completed` | 52 | 47 448 ms |
| 4 | Cancellation probe | Codex (`codex_app_server_stdio`) | `cancelled` | 2 | 123 ms to terminal |

All four VERIFIED from the run database. A second, earlier Codex sender turn
(345 normalized events, terminal `completed`) ran on a separate state
directory; it is recorded in the iteration-4 addendum as turn A.

After the final `Projector.project/1` pass every goal projects `:ok` and the
run rows read `completed` / `suspended` / `completed` / `cancelled`
respectively (VERIFIED).

## 3. The handoff itself

### 3.1 Boundary

The sender's terminal produced the Elf's own automatic recovery checkpoint
(`shoestring.elf:checkpoint_kind: "terminal"`, provenance
`checkpoint-fallback-v1`), carrying real repository evidence: worktree
identity, revision, dirty flag, the changed-file list, the run's recorded
command/tool identities with ordinals, the last safe boundary, and the
terminal pointer.

The handoff was then taken at an **operator-recorded boundary checkpoint**
written through `Shoestring.Harness.Checkpoints.record/3`, not at that
terminal checkpoint. This is a deliberate, disclosed choice:

- the terminal checkpoint's `next_action` is a deterministic per-class
  recovery instruction that hardcodes Shoestring's own gate —
  *"Verify the worktree with `mix precommit`, then continue from checkpoint
  …"* (VERIFIED from the persisted payload) — which is not a meaningful
  instruction inside a Go module. See §7.4;
- the boundary checkpoint's `evidence`, `repository_state` and
  `acceptance_contract` are derived from the sender run's own durable
  evidence and a real `git`/`go test` read of the worktree. The operator
  authored exactly two things: the `next_action` (the continuation
  instruction) and the `unresolved_issues` list. That is what an operator
  handing work over actually supplies, and §5 is careful to separate what
  Claude was told from what Claude worked out.

### 3.2 Receiver admission is honest, and it refuses by default

The receiver's capacity was observed from the real production capacity source
(`Shoestring.Harness.Capacity.ClaudeMonitor`, a `Capacity.Source`), which is
passive by design and consumes no model turn. Its honest reading:

    capacity_state: unknown        support_tier: conservative_partial
    compatibility_state: degraded  confidence: none
    reason: "rate_limits_absent_before_first_response_or_unsupported_subscription"

Against that reading (VERIFIED, both through `HandoffWorker.perform/1` on the
real persisted job):

| Intent | Decision | Reason code | Effects |
|---|---|---|---|
| no operator confirmation | `require_confirmation` | `support_tier_conservative_partial` | none: no `handoff.created`, no receiver run, no lease, no dispatch |
| attributable confirmation | `admit` | `confirmed_support_tier_conservative_partial` | the transfer |

The admitting decision records `override.valid: true`, the confirming
identity, the intent, and the target provider and scope. The explanation
states plainly that the admission was *not automatically safe*.

### 3.3 The transfer

`handoff.created` records `from_provider_id: codex_app_server_stdio`,
`to_provider_id: claude`, `contract_version: 1`, the boundary checkpoint id,
the authorized decision refs, the prior (sender) run id, the receiver run id
and the receiver's **own** lease grant id (VERIFIED). One durable dispatch row
plus one `dispatch` job followed; `Shoestring.Harness.DispatchWorker` then
turned that row into a supervised Elf through the production
`Shoestring.Harness.Dispatch.ElfEffect`. This module never called
`adapter.start/2`.

### 3.4 Privacy of the receiver's context

The receiver run's prompt is exactly
`Continuation.compose_handoff_prompt/2` output: the checkpoint pointer, the
`next_action`, the decision refs, the generic constraints line, and the
bounded checkpoint content sections (completed work, failure, constraints,
verification). VERIFIED by reading the persisted receiver `prompt` and
`continuation` columns:

- it contains no sender transcript text and no sender prompt;
- it contains no sender `provider_session_id`;
- the `continuation` column holds pointer keys only
  (`checkpoint_id`, `next_action`, `decision_refs`).

## 4. Why a fix was required before any of this could run

Two things had to be true for a production Codex→Claude handoff to happen at
all. One was a defect this branch fixes; the other is a defect this branch
**reports and does not fix**. Both are §7.

The fixed one, briefly: `Shoestring.Cobbler.Handoffs.perform/3` read the
operator's confirmation only from `opts[:override]`, and
`Shoestring.Cobbler.HandoffWorker` — the only production consumer of a
handoff intent — passes no such option and had no channel for one. Because the
production Claude capacity source declares `support_tier:
:conservative_partial` unconditionally, **every** Claude receiver is
confirmation-class, so the transfer was unreachable in production no matter
what the operator decided. The confirmation now travels on the durable
`run.handoff` intent, validated where the intent is recorded.

## 5. Semantic continuation: what Claude actually did

This is the acceptance item the milestone calls *"the semantic eval shows
receiver behavior … not only final pass"*. Everything quoted here is from
**canonical normalized events** (`harness.event_recorded`) of the receiver
run, not from raw provider output.

Claude started a fresh session with no transcript and only the projection
above. Its normalized outputs, in order (ordinals as persisted):

- **2** — *"I'll start by looking at the existing `game` package to understand
  its API."*
- **11** — *"Now I'll write `main.go` with a testable `run` function, plus an
  end-to-end test."*
- **27** — *"The implementation behaves correctly, but the prompt lacked a
  trailing newline, so `invalid:` didn't actually begin a line — which the
  contract requires. Fixing the prompt"*
- **32** — *"Now a real end-to-end run of the actual binary, checking the
  final line and exit code"*
- **45** — *"No remote is configured, so I'll commit locally on the existing
  branch."*
- **51** — *"It reuses the existing `game` package (`game.New`, `Move`,
  `Winner`, `Full`, `Render`); no rules were reimplemented."*

Between them, 26 normalized `command` events record the tool invocations that
carried the work, and the `result` event records `status: completed`.

What this shows, and what it does not:

- **Understanding of the same goal (VERIFIED).** Ordinal 2 identifies the
  artifact the *previous provider* produced — a package Claude was told
  existed but never shown — and goes to read its API before writing anything.
- **Advancing rather than restarting (VERIFIED).** The delivered `main.go`
  imports `example.com/tictactoe/game` and calls `game.New/Move/Winner/Full/
  Render`. The `game` package is byte-unchanged from the sender leg. The
  checkpoint asked for reuse, and reuse is what the artifact shows.
- **Working the acceptance contract, not just the instruction (VERIFIED).**
  Ordinal 27 is the strongest single piece of evidence here: Claude found its
  own violation of a contract clause carried in the checkpoint (a line must
  *begin* with `invalid`), diagnosed the cause as a missing trailing newline,
  and fixed it — unprompted, and not something restated in the next action.
- **Completion (VERIFIED).** The run reached terminal `completed` and the
  goal's mechanical acceptance passes; §6.
- **Not a handoff-tax measurement (UNVERIFIED).** This is one live arm with
  the trajectory-projection input. The milestone's three-arm ablation
  (worktree-only / naive-summary / trajectory-projection) was **not** run
  live; it remains fixture-authored in `ablation.md`. Nothing here measures
  repeated investigation against a baseline.

## 6. Mechanical verification of the disposable Go project

Run against the shared worktree after the receiver leg
(`verify_go.sh <worktree>`; exact output kept with the run, summarized here).
All VERIFIED:

| Check | Result |
|---|---|
| `go vet ./...` | pass |
| `go test ./...` | pass — `ok example.com/tictactoe`, `ok example.com/tictactoe/game` |
| `go build .` | pass |
| X wins on the top row | final line exactly `X wins`, exit 0 |
| O wins on the middle column | final line exactly `O wins`, exit 0 |
| X wins on the main diagonal | final line exactly `X wins`, exit 0 |
| a full board draws | final line exactly `Draw`, exit 0 |
| invalid input | prints a line beginning `invalid`, re-prompts, the game then finishes `X wins` with exit 0 |

Summary line: `0 failure(s)`.

Both packages' tests pass, including `main_test.go`, which the receiver wrote
itself and which the checkpoint did not ask for.

## 6.1 Terminal classification, cancellation, and the owned process group

Acceptance: *exercise an explicit owned-process cancellation/crash path and
verify terminal classification without relying on staleness or timers.*

A fourth live leg started a Codex Elf on a deliberately long task in its own
goal and worktree, waited until the **owned process group was observed alive**
and the run had produced durable progress, then called
`Shoestring.Elves.cancel_run/1`. Nothing about this path consulted a timer, a
lease deadline, a heartbeat, or `Shoestring.Elves.Staleness`; the trigger was
the explicit operator call. VERIFIED:

| Assertion | Result |
|---|---|
| owned process group observed before cancellation | alive |
| `cancel_run/1` | `{:ok, :cancelled}` in 123 ms |
| terminal class | `cancelled` |
| durable terminal events for the run | exactly 1 (`run.cancelled`) |
| owned process group after cancellation | dead |
| Elf process after cancellation | gone |
| adapter session still registered | no |
| second `cancel_run/1` | `{:ok, :already_terminal}`, no new terminal event |
| run row after projection | `cancelled` |

The run's durable sequence is `run.requested` → `run.starting` →
`run.running` → `run.cancelling` → `checkpoint.created` → `run.cancelled`: the
Elf recorded a terminal recovery checkpoint before committing the terminal,
and reaped the group it owned.

## 6.2 The iteration-4 file-change gap, against real provider output

Recorded in full in the iteration-4 addendum. In summary, both live Codex
turns show the file-change **completion** durably recorded with
`codex-app-server:status: "completed"`, every `changes[]` entry carrying a
scalar `"kind"`, and a contiguous normalized ordinal sequence with no gaps and
no duplicates (VERIFIED) — the three symptoms the 2026-09-07 defect produced,
all absent.

## 6.3 The default lease deadline stopped the first receiver leg

Leg 2 is worth recording on its own, because it is the quota-aware machinery
behaving correctly and being inconvenient.

The receiver's lease is granted from the admitting decision's proposed bounds,
which come from `AdmissionPolicy.default()`: `deadline_seconds: 300`. Claude
reached that deadline mid-task. The durable sequence
(VERIFIED) is `lease.renewal_due` → `lease.expired` →
`lease.checkpoint_required` → a reactive `checkpoint.created` →
`run.pausing` → `run.suspended`. The run stopped at a safe boundary with a
recovery checkpoint and **no terminal** — which is exactly the contract: a
suspended run is not over.

Leg 3 therefore performed the transfer with an explicit operator policy
(`deadline_seconds: 2700`, `response_budget: 400`, `tool_budget: 1000`,
`checkpoint_cadence: 50`) passed as `Handoffs.perform/3`'s documented
`:policy` option. **This is a deviation worth stating plainly**: the default
policy is a deployment parameter rather than a property of the transfer, but
`HandoffWorker` has no channel for a per-transfer policy either, so leg 3 went
through `Handoffs.perform/3` directly instead of through the worker. Every
other element of the transfer — intent, boundary, observation, admission,
receiver run, lease grant, pointer, durable dispatch, `DispatchWorker`,
`ElfEffect`, Elf — was unchanged, and leg 3's dispatch *was* delivered by the
real `DispatchWorker`.

## 7. Defects and observations from this run

### 7.1 FIXED — the production handoff intent had no channel for the operator's confirmation

**Severity: blocking.** A confirmation-class receiver refusal could not be
answered in production. Since the Claude capacity source declares
`support_tier: :conservative_partial` unconditionally
(`lib/shoestring/harness/capacity/claude_monitor.ex`, `support_tier/0`;
REPO-INSPECTION), this covered every Claude receiver.

**Fix** (smallest in scope):

- `Shoestring.Cobbler.Command` accepts an optional `confirmation` object on a
  `run.handoff` payload and validates it *where the intent is recorded*:
  `confirmed_by` is required and never defaulted; `target_provider_id` and
  `target_scope` default to this payload's own receiver and scope and are
  rejected when they name anything else. A payload with no confirmation keeps
  byte-identical shape and digest, so previously submitted command ids still
  replay.
- `Shoestring.Cobbler.Commands` carries the field into the resolved
  `handoff_requested` result, which is what `perform/3` reads.
- `Shoestring.Cobbler.Handoffs` prefers `opts[:override]` and falls back to
  the intent's confirmation, so every existing in-process caller is unchanged.

It authorizes nothing by itself: `AdmissionEvaluation` re-validates it and can
only lift a confirmation-class refusal. A hard stop stays a hard stop.

**Regression test:** `test/shoestring/cobbler/handoff_confirmation_test.exs`,
9 tests, hermetic. Measured against base `6f1653f`: **5 fail there, for the
right behavioural reason** — base silently drops the `confirmation` key rather
than rejecting it, so the operator's decision is accepted and then ignored.
Exact base output:

    9 tests, 5 failures

    1) an unattributed confirmation is rejected at request time
       assert {:error, changeset} = submit(...)      right: {:ok, ...}
    2) re-submitting the same command id with a different confirmation is a conflict
       assert {:error, {:command_conflict, detail}}  right: {:ok, ...}
    3) a confirmation naming a different provider is rejected at request time
       assert {:error, changeset} = submit(...)      right: {:ok, ...}
    4) a confirmation naming a different scope is rejected at request time
       assert {:error, changeset} = submit(...)      right: {:ok, ...}
    5) the production worker admits a confirmation-class receiver when the
       intent carries one
       assert [pointer] = events(goal_id, "handoff.created")
       left: [pointer]   right: []

The remaining 4 tests pass on base; they are the both-directions controls
(refusal without a confirmation, a confirmation not lifting a hard stop,
`:override` precedence, unchanged payload shape), and the suite's moduledoc
records them as documentation rather than locks.

### 7.2 NOT FIXED — the production receiver probe produces a snapshot the work goal cannot project

**Severity: blocking for the production path. Reported, not fixed.**

`config/runtime.exs` wires `:handoff_observe` (and `:wakeup_observe`) to
`Shoestring.Cobbler.WakeupObserve.observe/1`, which serves snapshots out of
the Observatory ledger. Every ledger reading is persisted by
`Shoestring.Harness.Observatory.ingest/2` under the protected singleton
Observatory goal. `Handoffs.perform/3` then re-records that reading as
`capacity.snapshot_observed` under the **work** goal, and
`Shoestring.Harness.Projector` requires same-goal ownership, so the projection
fails.

Isolated reproduction (VERIFIED, hermetic, no model turn — only
`claude --version` from the monitor's version discovery):

    ledger_snapshot_record_owner: {"<snapshot id>", "00000000-0000-4000-8000-000000000cb0"}
    observatory_goal_id:          "00000000-0000-4000-8000-000000000cb0"
    work_goal_id:                 "<a different goal>"
    handoff_worker_result:
      {:error, {:harness_projection_failed, 16,
                {:capacity_snapshot_not_owned, "<snapshot id>"}, …}}
    projector_position: {15, "failed"}

Two consequences, both observed: the handoff worker fails after the pointer,
lease, receiver run and dispatch have already committed; and the work goal's
projector position is left `failed`, so **nothing else for that goal projects
either** until the position is repaired.

Past the first refusal there is a twin at
`Projector.persist_lease(…, :propose, …)`, which resolves the receiver
lease's `admitted_snapshot_id` by the same same-goal rule and fails with
`{:lease_dependency_not_found, …}` one event later (OPERATOR-OBSERVED: seen
while the first check was temporarily relaxed during diagnosis; the relaxation
was reverted and is not in this branch).

**Why this branch does not fix it.** The same-goal rule is a deliberate,
committed boundary, not an oversight:
`test/shoestring/harness/observatory_lease_reference_test.exs:120` is titled
*"user run CANNOT reference an observatory-owned capacity snapshot (strict
same-goal ownership enforced)"*. Relaxing the projector makes that test fail
(VERIFIED: it did, with the projection returning `{:ok, position}` where the
test asserts `{:error, {:harness_projection_failed, …}}`). Choosing between
"the ledger is the canonical owner and a work goal references it" and "a work
goal mints its own goal-scoped snapshot identity chained to the ledger
reading" is a design decision about identity and ownership, not a mechanical
fix, and it is not this task's to make unilaterally.

**Effect on this verification.** The live legs took the receiver observation
from the real `ClaudeMonitor` capacity source directly rather than through the
Observatory ledger, so the snapshot was goal-owned and projected normally.
That is a real production capacity source but **not** the `:prod`-configured
probe. The live handoff therefore demonstrates the transfer; it does not
demonstrate the `:prod` observation wiring, which remains broken.

### 7.3 NOT FIXED — a launch failure before `run.starting` wedges the goal's projector

**Severity: high. Reported, not fixed.**

If an Elf fails in `launch_fresh/1` *before* `append_starting/1` succeeds, it
still commits `run.failed`. The run row is then `requested`, and
`RunStateMachine` has no `requested --fail-->` transition, so the projector
stops permanently:

    {:harness_projection_failed, 382,
     %Shoestring.Harness.Error{category: :invalid_transition,
       code: "run_transition_rejected",
       message: "run transition :fail is not legal from :requested"}, …}
    projector_position: {381, "failed"}

Observed once (VERIFIED from the first state directory's database: the run has
`run.failed` and no `run.starting`, and the goal's projector position is
`failed` at that sequence). A terminal the projector can never apply is worse
than a missing terminal, because it takes the whole goal's projection with it.

### 7.4 NOT FIXED — one launch failure whose cause was swallowed

**Honest unknown.** The launch failure that produced §7.3 was recorded as
`transport/process_launch_failed`, which `Elf.launch_code/1` returns for any
reason it does not recognize. `launch_fresh/1`'s `with` swallows the concrete
reason, so the trajectory records only the catch-all. The same configuration
— the same receiver prompt, the same shared worktree, the same adapter — was
then run twice more under local-function return tracing and **launched
successfully both times**, so the failure did not reproduce.

**I did not establish the cause, and I am not going to guess at one.** What is
established is the consequence (§7.3) and the diagnosability gap: an operator
reading that trajectory cannot tell what failed.

### 7.5 NOT FIXED — a declined lease did not quiesce a ClaudeHeadless Elf

**Severity: medium. Reported, not fixed.**

After leg 2's lease decline (`run.suspended` persisted, the Claude OS process
gone), the Elf was still supervising when the operator's 25-minute observation
bound expired: `await: {:timeout, {:ok, nil}}` at 1 500 050 ms, with no
terminal and no further events (VERIFIED).

`Elf.finish_after_stream/1` stops a declined run quietly only once
`resolve_live_session/1` returns `:none`, and Claude has no safe-stop
capability (`Elves.request_stop/2` returns `{:error, :safe_stop_unsupported}`
for the Claude adapter; REPO-INSPECTION), so nothing on the decline path winds
the session down. That is consistent with what was observed, but the causal
chain is **REPO-INSPECTION, not VERIFIED** — I did not instrument the session
registry at the moment of the timeout.

This does not affect explicit cancellation (§6.1), which terminates the group
directly and did so in 123 ms.

### 7.6 Observation — the Elf's checkpoint `next_action` hardcodes `mix precommit`

`Shoestring.Elves.TerminalCheckpoint` composes every per-class recovery
instruction around `mix precommit`, Shoestring's own gate, regardless of the
worktree's toolchain (REPO-INSPECTION: `next_action/4` and
`reactive_next_action/4`; VERIFIED in the persisted payload of this run's Go
worktree). For a self-hosted Shoestring goal this is right. For any other
repository it is an instruction that cannot be followed. Recorded as an
observation, not a defect of this slice; it is the reason §3.1 took the
handoff at an operator boundary.

## 8. What is still unmet

Closed by this run:

1. **A real cross-provider handoff has been evaluated** (acceptance gate item
   7). Codex → Claude, live, through the durable intent, real admission, the
   receiver's own lease, the canonical pointer and the durable dispatch
   pipeline.
2. **The iteration-4 post-fix Codex turn has been run** and the file-change
   normalization confirmed against real provider output.
3. **Real receiver behaviour is evidenced** for the trajectory-projection
   input (§5).

Still unmet:

1. **The semantic ablation is still fixture-authored.** One live arm is not
   the three-arm comparison the milestone specifies, and nothing here measures
   handoff tax against a baseline.
2. **The `:prod` receiver-observation wiring is broken** (§7.2). A handoff
   run with the configured production probe fails projection and wedges the
   goal. The live legs worked around it.
3. **A launch failure before `run.starting` can wedge a goal's projection**
   (§7.3), and its cause was not established (§7.4).
4. **A declined lease did not quiesce a ClaudeHeadless Elf** (§7.5).
5. **UI visual validation was still not performed** at any viewport. Unchanged
   from `integration-closeout.md` §7.
6. Package G's two audited acceptance blockers were closed in the base by
   PR #77 (REPO-INSPECTION of `adf8269`); this run did not re-audit them.

### Iteration 6 is not unlocked

`integration-closeout.md` recorded two live conditions for withholding
iteration 6: an incomplete iteration 4 and unmet eval gates. The first of
those — the open iteration-4 live turn — is now closed. The eval gate is
**not**: the semantic ablation remains fixture-authored. And this run added
three production defects in the very path iteration 6 would build on, two of
which leave a goal's projection permanently failed.

**Iteration 6 should not be started on the strength of this run.**

## 9. Redaction

Everything in this document is either a count, a classification, a reason
code, a command, or prose. Deliberately absent, per `04-single-elf/README.md`
and this directory's `README.md`:

- provider-generated identifiers — Codex `thread_id`/`turn_id`/`item_id`,
  Claude `session_id`, frame uuids — are not quoted, not abbreviated, and not
  elided behind an ellipsis; they are referred to by role;
- Shoestring-generated row identifiers (goal, task, run, checkpoint, decision,
  lease, dispatch) are likewise referred to by role, matching the convention
  the rest of this directory already follows — the only literal UUID in this
  document is the protected Observatory goal's, which is a compile-time
  constant in the repository, not an observation;
- OS process-group ids and operator/machine paths are absent; the one
  structural path shown is the Go module's own relative layout;
- no credential, token, header or cookie appears anywhere;
- no hidden model reasoning is persisted or reproduced. The Claude legs emit
  `thinking_tokens` **lifecycle markers** carrying a frame type and nothing
  else; a scan of the receiver run's persisted payloads for `"thinking"`,
  `reasoning_text`, `chain_of_thought` and `scratchpad` returns 0 rows
  (VERIFIED);
- the quoted receiver outputs in §5 are model output, not reasoning, and are
  quoted from canonical normalized events.

The committed summary under `fixtures/live/` carries derived counts,
classifications and boolean assertions only.

Claims about what a redacted value *was* are labelled
`OPERATOR-OBSERVED-NOT-CAPTURED`, never `VERIFIED`, because the original is
deliberately absent from the committed bytes.

## 10. Gate

Exact command, run in this worktree with a fresh state directory under the
platform temp root:

    mix precommit

Exact result, five runs (VERIFIED). Run 5 is the last one, on the exact tree
that is committed:

| Run | Elixir | Node | Exit |
|---|---|---|---:|
| 1 | 1311 tests, 1 failure, 1 skipped (6 excluded) | — | 2 |
| 2 | 1311 tests, 0 failures, 1 skipped (6 excluded) | 52 pass, 0 fail | 0 |
| 3 | 1311 tests, 0 failures, 1 skipped (6 excluded) | 52 pass, 0 fail | 0 |
| 4 | 1311 tests, 0 failures, 1 skipped (6 excluded) | 52 pass, 0 fail | 0 |
| 5 | 1311 tests, 0 failures, 1 skipped (6 excluded) | 52 pass, 0 fail | 0 |

One earlier invocation is deliberately **not** in this table: its Node stage
passed but its Elixir line was lost to a mistake in the operator's capture
command, so its result is unknown and is excluded rather than assumed. A
run before that one failed at the `format --check-formatted` stage and never
reached the tests; the formatting was fixed and it is likewise not counted as
a test run.

**Reported as intermittent: 1 failure in 5 runs.** The failure was not in the
code this branch touches:

    1) test an admitted claim issues a lease and commits proposed→granted→active
       (Shoestring.Cobbler.LeaseGrantTest)
       test/shoestring/cobbler/lease_grant_test.exs:39
       ** (Exqlite.Error) Database busy
       INSERT INTO "goals" …
       stacktrace: … test/shoestring/cobbler/lease_grant_test.exs:32 (setup)

It is a SQLite write-contention failure in an unrelated suite's `setup`, whose
accompanying log shows a concurrent `Elf` terminal-checkpoint write from
another test holding the connection. Three runs of `mix precommit` at base
`6f1653f` (1302 tests, 0 failures, 1 skipped, 6 excluded each) did not
reproduce it, so I cannot label it pre-existing either. **Cause not
established.** It was not re-run until green: every run is reported, the
failing one first.

Test-count accounting: base 1302 + the 9 tests of
`handoff_confirmation_test.exs` = 1311. No other test file changed.

The 1 skipped is the designed capability-appropriate skip in
`Shoestring.Harness.ClaudeHeadlessContractTest`; the 6 excluded are the
`@tag :live` provider smoke tests, which were **not** run by the gate. The
live provider work in this document ran outside the gate, through the
operator script.
