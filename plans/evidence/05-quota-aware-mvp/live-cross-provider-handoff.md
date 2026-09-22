# Live cross-provider handoff, semantic continuation, and cancellation

Date: 2026-09-21. Branch `polly/iter45-live-verification`, base
`6f1653fed931d120d463676ec40e95e6b8ad7327`.

This is the bounded live-verification closeout for the two items iteration 5
left explicitly unmet — *no real cross-provider handoff* and *no real semantic
evidence* — plus an explicit owned-process cancellation, and the iteration-4
post-fix Codex turn recorded separately in
`plans/evidence/04-single-elf/harness-live-verification.md`.

**It does not declare iteration 5 complete, it closes no acceptance gate, and
it does not unlock iteration 6.**

Read [§0](#0-what-this-run-does-not-establish) before anything else. The live
transfer did not run on the production-configured observation path, so the
acceptance gate it bears on stays **OPEN**. A workaround is not a gate.

Claim labels follow this directory's `README.md` (`VERIFIED`,
`REPO-INSPECTION`, `SCHEMA-ONLY`, `UNVERIFIED`), plus
`OPERATOR-OBSERVED-NOT-CAPTURED` from `04-single-elf/README.md` §6 for claims
about a value that redaction removed.

---

## 0. What this run does NOT establish

Stated first, because the rest of the document is easy to read as more than
it is.

| Milestone gate | Status after this run |
|---|---|
| *"At least one real cross-provider handoff is evaluated…"* (acceptance 7) | **OPEN** |
| *"The semantic eval shows receiver behavior and handoff tax…"* (acceptance 8) | **OPEN** |
| Iteration-4 hard dependency: the post-fix Codex live turn | **Closed** |

**Acceptance 7 stays open even though a real Codex → Claude transfer ran.**
Two things in the transfer were not the production-configured path:

1. **The receiver observation did not come from the `:prod` probe.**
   `config/runtime.exs` wires `:handoff_observe` to
   `Shoestring.Cobbler.WakeupObserve`, which serves Observatory-ledger
   snapshots — and a ledger snapshot cannot be projected under a work goal
   (§7.2, still unfixed). The live legs took the observation from the real
   `ClaudeMonitor` capacity source directly. That is a real production
   source, but it is not what a deployed Shoestring would call, so this run
   says nothing about whether the deployed configuration works. It does not.
2. **The completing receiver leg did not go through `HandoffWorker`.** The
   default lease deadline stopped the first receiver leg mid-task (§6.3), and
   the worker has no channel for a per-transfer policy, so the completing leg
   called `Handoffs.perform/3` directly with an explicit operator policy. Its
   dispatch was still delivered by the real `DispatchWorker`, but the
   decision step bypassed the production consumer.

Either one on its own is enough to keep the gate open. **A gate is not closed
by demonstrating the thing works when the production wiring is replaced.**

**Acceptance 8 stays open** because only one arm ran live. The three-arm
ablation and the handoff-tax metrics the milestone specifies remain
fixture-authored in `ablation.md`; nothing here measures one arm against
another.

What the run *does* establish is recorded below and backed by committed,
redacted canonical material under `fixtures/live/`: the transfer mechanism,
the admission behaviour with and without an operator confirmation, real
receiver semantics on the trajectory-projection input, the terminal
classification of an explicit cancellation, and the iteration-4
file-change fix against real provider output.

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
  instruction inside a Go module. See §7.6;
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

A production Codex→Claude handoff needed two blockers cleared. One is a
defect this branch fixes; the other is a defect this branch **reports and
does not fix**, which is why §0 keeps the acceptance gate open.

**Fixed (§7.1):** `Shoestring.Cobbler.Handoffs.perform/3` read the operator's
confirmation only from `opts[:override]`, and
`Shoestring.Cobbler.HandoffWorker` — the only production consumer of a
handoff intent — passes no such option and had no channel for one. Because the
production Claude capacity source declares `support_tier:
:conservative_partial` unconditionally, **every** Claude receiver is
confirmation-class, so the transfer was unreachable in production no matter
what the operator decided. The confirmation now travels on the durable
`run.handoff` intent, validated where the intent is recorded, with its
attribution derived from a trusted context rather than accepted from the
request.

**Not fixed (§7.2):** the `:prod`-configured receiver probe yields a snapshot
the work goal's projector refuses. The live legs replaced that probe with a
direct read of the same capacity source. **That replacement is the reason
acceptance 7 is still open**, and it is the single most important caveat in
this document.

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

**Fix.** The durable `run.handoff` intent carries a `confirmation`, and the
caller states only THAT it confirms and for which capability — never who.

- `Shoestring.Cobbler.Command` accepts exactly one key, `intent`, allow-listed
  against the capability vocabulary (`supervised_execution`, `read_only`).
  A non-object, an unknown key, a missing/blank/non-string/overlong intent, or
  an intent outside the vocabulary is a **rejected command**, not a silently
  dropped field. `confirmed_by`, `target_provider_id` and `target_scope` are
  therefore unsupported fields: supplying any of them fails the request.
- `Shoestring.Cobbler.Commands` binds the attribution from a trusted context:
  `confirmed_by` is derived from the goal's durable `owner_id` as
  `"owner:<id>"`, and the target provider and scope from the same payload's
  receiver. **Fail-closed:** a goal whose owner is absent or is the protected
  Observatory principal is rejected as `handoff_confirmation_unattributable`
  rather than attributed to nobody.
- `Shoestring.Cobbler.Handoffs` prefers `opts[:override]` and falls back to
  the intent's confirmation, so every existing in-process caller is unchanged;
  and it refuses permanently
  (`{:handoff_confirmation_intent_mismatch, …}`, settled as `handoff.failed`)
  when the confirmed intent is not the capability admission is deciding.

**Why the identity is derived rather than accepted.** A `confirmed_by` string
in a request body is an assertion by the requester. Admission treats
`confirmed_by` as the attribution that lifts a confirmation-class refusal, so
accepting one from the payload would let any caller mint an operator — or a
`system:` principal — for itself. The goal's `owner_id` is the strongest
trusted context this application has: `Shoestring.Trajectory.Goal` documents
it as *"supplied by the authenticated application boundary"* and refuses it
from ordinary attribute maps.

**Honest limit (UNVERIFIED as a security property).** This application has no
accounts domain, no user table, and no per-request authenticated principal —
`current_scope` is `nil` in every LiveView today (REPO-INSPECTION). So
`owner:<goal owner>` attributes a confirmation to the goal's owner, **not to
the individual who pressed the button**, and this run does not establish that
a real authenticated principal exists to bind to. What it does establish is
that the identity is no longer caller-authored. `Commands.respond/4` still
accepts a caller-supplied `confirmed_by` for the `needs_user` recovery path;
that inconsistency is **left open and out of scope here** rather than changed
silently.

It authorizes nothing by itself: `AdmissionEvaluation` re-validates it and can
only lift a confirmation-class refusal. Every hard stop stays a hard stop
(§7.7).

**Regression test:** `test/shoestring/cobbler/handoff_confirmation_test.exs`,
27 tests, hermetic. Measured against base `6f1653f`: **14 fail there, for the
right behavioural reason** — base silently drops the `confirmation` key rather
than rejecting it, so the operator's decision is accepted and then ignored.
Base reports `27 tests, 14 failures`, comprising:

    the production worker admits a confirmation-class receiver …   handoff.created == []
    a matching intent is not blocked                                handoff.created == []
    confirmed_by is derived from the goal owner, not the request    no attribution to read
    a goal with no usable owner … is refused                        submit returns {:ok, …}
    a caller-authored confirmed_by is an unsupported field          submit returns {:ok, …}
    a forged system principal is rejected the same way              submit returns {:ok, …}
    a caller-chosen target provider or scope is rejected            submit returns {:ok, …}
    a confirmation that is not an object is rejected                submit returns {:ok, …}
    an intent outside the capability vocabulary is rejected         submit returns {:ok, …}
    a missing, blank, non-string or overlong intent is rejected     submit returns {:ok, …}
    an unknown key alongside a valid intent is still rejected       submit returns {:ok, …}
    re-submitting … with a different confirmation is a conflict     submit returns {:ok, …}
    adding a confirmation to an unconfirmed command id …            submit returns {:ok, …}
    a confirmation whose intent is not the requested capability …   perform returns {:ok, …}

The other 13 pass on base; the suite's moduledoc names each one as a control
(the refusal without a confirmation, the hard-stop twins, `:override`
precedence, identical replay, the unchanged unconfirmed payload, and the
schema fact that `goals.owner_id` is `NOT NULL`).

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

### 7.3 FIXED — a launch failure before `run.starting` wedged the goal's projector

**Severity: high.**

If an Elf failed in `launch_fresh/1` *before* `append_starting/1` succeeded, it
still committed `run.failed`. The run row was then `requested`, and
`RunStateMachine` had no `requested --fail-->` edge, so the projector stopped
permanently:

    {:harness_projection_failed, 382,
     %Shoestring.Harness.Error{category: :invalid_transition,
       code: "run_transition_rejected",
       message: "run transition :fail is not legal from :requested"}, …}
    projector_position: {381, "failed"}

Observed live (VERIFIED from the first state directory's database: the run has
`run.failed` and no `run.starting`, and the goal's projector position is
`failed` at that sequence). A terminal the projector can never apply is worse
than a missing terminal, because it takes the whole goal's projection with it
— every later run, checkpoint and lease of that goal stops projecting too.

**The twin.** `Shoestring.Elves.cancel_run/2` on a run with no live Elf calls
`append_cancelled/2`, which appends `run.cancelling`/`run.cancelled` without
consulting the row's state. `requested --cancel-->` was missing as well, so
cancelling a run that never started wedged a goal in exactly the same way
(REPO-INSPECTION of `elves.ex`, then locked by test).

**Fix:** two edges in `Shoestring.Harness.RunStateMachine` —
`requested --fail--> failed` and `requested --cancel--> cancelling`. Both are
genuine lifecycle transitions: a run can end before it starts, and the Elf
already reports it that way. `requested --interrupt-->` was deliberately NOT
added: no production path was found that emits `run.interrupted` for a run
that never started, and an edge with no reachable producer is speculation.

**Regression test:**
`test/shoestring/harness/run_terminal_before_start_test.exs`, 6 tests,
hermetic. At base `6f1653f` the suite reports `6 tests, 5 failures`, every one
of them `run_transition_rejected` at the same surface:

    a requested run may fail                     RunStateMachine.transition/2 -> {:error, …}
    a requested run may be cancelled             RunStateMachine.transition/2 -> {:error, …}
    a launch failure before run.starting …       Projector.project/1 -> {:error, …}
    a cancellation before run.starting …         Projector.project/1 -> {:error, …}
    a goal keeps projecting after a pre-start …  Projector.project/1 -> {:error, …}

The sixth is the negative control (`complete`, `interrupt` and `started` are
still illegal from `requested`) and passes on base.

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

**Severity: medium. Reported, not fixed; the corresponding behaviour is
therefore an OPEN defect, not a closed one.**

After leg 2's lease decline (`run.suspended` persisted, the Claude OS process
gone), the Elf was still supervising when the operator's 25-minute
observation bound expired: `await: {:timeout, {:ok, nil}}` at 1 500 050 ms,
with no terminal and no further events (VERIFIED — the run's committed
lifecycle is in `fixtures/live/normalized-receiver-claude-lease-boundary.md`
and ends at `run.suspended`).

**Mechanism — hypothesis, REPO-INSPECTION only.** `Elf.finish_after_stream/1`
stops a declined run quietly only once `resolve_live_session/1` returns
`:none`. `decline_lease/2` does ask the session to stop, and
`ClaudeHeadless.Session.handle_call(:request_safe_stop, …)` kills the group
immediately **only when nothing is in flight**; with in-flight tool calls it
records `stop_requested: :safe_boundary` and waits for them to drain. A
process group that dies while a tool is in flight never delivers the
`tool_result` that would drain it, so the session would stay alive and the
Elf would keep waiting.

That chain is consistent with everything observed, and it is **not
verified**: I did not instrument the session registry or the in-flight set at
the moment of the timeout, and reproducing it needs either another live leg
(outside this task's authorization) or a scripted-transport harness that does
not exist for this path yet. **I am not fixing a mechanism I have not
confirmed**, and a fix aimed at the wrong drain condition would be worse than
the defect.

This does not affect explicit cancellation (§6.1), which terminates the group
directly and did so in 123 ms — including in the case where an Elf is
supervising a live group.

### 7.6 Observation — the Elf's checkpoint `next_action` hardcodes `mix precommit`

`Shoestring.Elves.TerminalCheckpoint` composes every per-class recovery
instruction around `mix precommit`, Shoestring's own gate, regardless of the
worktree's toolchain (REPO-INSPECTION: `next_action/4` and
`reactive_next_action/4`; VERIFIED in the persisted payload of this run's Go
worktree). For a self-hosted Shoestring goal this is right. For any other
repository it is an instruction that cannot be followed. Recorded as an
observation, not a defect of this slice; it is the reason §3.1 took the
handoff at an operator boundary.

### 7.7 Which hard stops a confirmation was proven unable to lift

`AdmissionEvaluation.check_hard_constraints/6` has eight unbypassable
constraints. Each is asserted with a VALID confirmation in hand, so the fix
cannot later be widened into one that lifts any of them (all VERIFIED by
`handoff_confirmation_test.exs`):

| Hard stop | Asserted through | Result with a valid confirmation |
|---|---|---|
| `incompatible_cli` | the production `HandoffWorker` path | refused, no effects |
| `unsupported_tier` | the production `HandoffWorker` path | refused, no effects |
| `snapshot_provider_mismatch` (foreign provider) | the production `HandoffWorker` path | refused, no effects |
| `snapshot_provider_mismatch` (foreign scope) | the production `HandoffWorker` path | refused, no effects |
| reserve breach (five-hour) | the production `HandoffWorker` path | refused, no effects |
| `scope_occupied` | `Handoffs.perform/3` with `occupancy: true` | `defer_until`, no effects |
| `scope_mismatch` | `AdmissionEvaluation.evaluate/5` directly | `reject`, override recorded `valid: true` and unused |
| `unsupported_capability` | `AdmissionEvaluation.evaluate/5` directly | `reject`, override recorded `valid: true` and unused |

The last two are asserted one layer down deliberately, and the reason is
itself worth recording: **they are structurally unreachable through
`Handoffs.perform/3`**, which builds the request scope and the candidate
scope from the same `intent["scope"]`, and the candidate's capability list
from the very capability it requests (`handoffs.ex`, `admit/8`). No handoff
input makes either side disagree. Driving them through the handoff path would
have meant asserting a shape production cannot produce; asserting them
against the evaluator that owns the rule tests the claim that actually
matters — a confirmation does not lift them.

A ninth constraint, a hard quota refusal from the provider
(`is_refused?/1`), is not covered here: constructing it needs a refused
snapshot shape this suite does not build, and it is listed as a gap rather
than quietly omitted.

## 8. What is still unmet

### Acceptance gates: both stay OPEN

| Gate | Status | Why |
|---|---|---|
| 7 — *at least one real cross-provider handoff is evaluated* | **OPEN** | The transfer ran, but not on the `:prod` observation path (§0, §7.2), and the completing leg bypassed the worker's decision step (§0, §6.3). |
| 8 — *the semantic eval shows receiver behavior and handoff tax* | **OPEN** | One live arm; the three-arm ablation and the tax metrics remain fixture-authored. |

Neither is closed by this run, and neither may be closed by the workarounds
this run used. **A gate is a statement about the production path.**

### Closed by this run

1. **The iteration-4 post-fix Codex live turn.** Two turns, both terminal
   `completed`, the file-change completion durably recorded with a scalar
   `changes[].kind` and contiguous, duplicate-free ordinals — backed by
   `fixtures/live/normalized-sender-codex.md` (ordinal 98).
2. **§7.1** — the production handoff intent now has an attributable
   confirmation channel, and the attribution is not caller-authored.
3. **§7.3** — a terminal that arrives before `run.starting`, from either the
   launch-failure or the cancel-without-Elf path, now projects instead of
   wedging the goal.

### Open defects

1. **The `:prod` receiver-observation wiring is broken** (§7.2). A handoff
   run with the configured production probe fails projection after its
   effects have committed and leaves the goal's projector position `failed`.
   Not fixed: the same-goal ownership boundary it collides with is a
   deliberate, committed decision, and choosing between the two designs is
   not this task's call.
2. **`HandoffWorker` has no per-transfer policy channel** (§6.3). The default
   300-second lease deadline is what stopped the first receiver leg, and
   there is no production way to hand a different one to a specific
   transfer. Not fixed: whether lease bounds should be per-transfer or purely
   deployment configuration is a design question, not a mechanical gap.
3. **A declined lease did not quiesce a ClaudeHeadless Elf** (§7.5). Not
   fixed: the mechanism is a hypothesis I could not confirm without another
   live leg.
4. **One launch failure's cause was not established** (§7.4), and
   `Elf.launch_fresh/1` still collapses every unrecognized launch reason to
   the `process_launch_failed` catch-all, so an operator reading that
   trajectory cannot tell what failed.
5. **A hard quota refusal was not covered** by the hard-stop matrix (§7.7).
6. **UI visual validation was still not performed** at any viewport.
   Unchanged from `integration-closeout.md` §7.
7. **Confirmation attribution binds to the goal's owner, not to a
   per-request authenticated principal**, because this application has none
   (§7.1). `Commands.respond/4` still accepts a caller-supplied
   `confirmed_by` on the `needs_user` path.

Package G's two audited acceptance blockers were closed in the base by PR #77
(REPO-INSPECTION of `adf8269`); this run did not re-audit them.

### Iteration 6 is not unlocked

`integration-closeout.md` recorded two live conditions for withholding
iteration 6: an incomplete iteration 4 and unmet eval gates. The iteration-4
item it named is closed. **Everything else still holds, and more of it than
before:**

- both acceptance gates above remain OPEN;
- seven defects are open, two of which (§7.2, §7.5) sit directly in the
  cross-provider path iteration 6 would build on, and one of which leaves a
  goal's projection permanently failed in the deployed configuration.

**Iteration 6 must not be started on the strength of this run.**

## 9. Committed evidence and redaction

### What is committed

Every `VERIFIED` claim above about event counts, kinds, ordinals, lifecycle
sequences, tool payloads, terminal classification or receiver semantics is
checkable against committed bytes under `fixtures/live/`:

| File | Backs |
|---|---|
| `normalized-sender-codex.md` | §6.2 and the iteration-4 addendum: 374 normalized events, contiguous ordinals, and at ordinal 98 the `fileChange` item with `status: "completed"` and scalar `"kind": "add"` |
| `normalized-receiver-claude-completed.md` | §5 (every quoted output line, with its ordinal) and §2's terminal |
| `normalized-receiver-claude-lease-boundary.md` | §6.3's lease sequence and §7.5's "no terminal" |
| `normalized-cancellation-codex.md` | §6.1's `run.cancelling` → `checkpoint.created` → `run.cancelled` sequence |
| `go-verification.txt` | §6, verbatim command output |
| `cross-provider-handoff-summary.json` | the derived counts and boolean assertions |

Each normalized file carries the run's full lifecycle/terminal event list and
one line per normalized event: ordinal, kind, and the bounded detail. Per-event
`provider_session_id` and `source_event_id` are **omitted rather than
substituted** — they add nothing the ordinal does not, and omission is the
safer choice — so the files prove counts, ordering, kinds, statuses and
payload shape, not session correlation.

### Redaction scheme

Deterministic, format-valid synthetic substitution, assigned in first-seen
order and applied 1:1, so the committed bytes still exercise real structure:

- Codex UUIDv7 identifiers (thread/turn) → `01950000-0000-7000-8000-…`,
  preserving version nibble `7` and variant nibble `8`;
- UUIDv4-shaped identifiers (Claude `session_id`, frame uuids, and
  Shoestring row ids, in separate series) → `aaaaaaaa-0000-4000-a000-…` and
  `55555555-0000-4000-9000-…`, preserving version `4` and a valid variant;
- prefixed provider ids (`exec-…`, `msg_…`) keep prefix, length and
  character class;
- OS process-group ids → a synthetic five-digit series;
- absolute paths → `$WORKSPACE` (worktree-relative tail preserved) or
  `$REDACTED_PATH`.

Nothing else is altered: the counts, ordinals, kinds, statuses, reason codes,
rate-limit telemetry and model output text are byte-faithful.

### What is deliberately absent

- no credential, token, header or cookie, anywhere;
- no real provider-generated identifier — not quoted, not abbreviated, not
  elided behind an ellipsis;
- no operator or machine path, and no real process-group id;
- **no hidden model reasoning.** The Claude legs emit `thinking_tokens`
  *lifecycle markers* carrying a frame type and nothing else; a scan of the
  receiver run's persisted payloads for `"thinking"`, `reasoning_text`,
  `chain_of_thought` and `scratchpad` returns 0 rows (VERIFIED). The export
  additionally drops `claude-headless:session_id` and `claude-headless:cwd`
  from lifecycle frames;
- the quoted receiver outputs in §5 are model **output**, not reasoning.

In the prose of this document, Shoestring row identifiers are referred to by
role rather than quoted, matching the convention the rest of this directory
follows. The only literal UUIDs here are the protected Observatory goal's
(a repository compile-time constant) and the synthetic patterns above.

Claims about what a redacted value *was* are labelled
`OPERATOR-OBSERVED-NOT-CAPTURED`, never `VERIFIED`, because the original is
deliberately absent from the committed bytes.

## 10. Gate

Exact command, run in this worktree with a fresh state directory under the
platform temp root each time:

    mix precommit

### This tree (the review-round head)

Five runs (VERIFIED). Run 5 is the last one, on the committed tree:

| Run | Elixir | Node | Exit |
|---|---|---|---:|
| 1 | 1335 tests, 0 failures, 1 skipped (6 excluded) | 52 pass, 0 fail | 0 |
| 2 | 1335 tests, 0 failures, 1 skipped (6 excluded) | 52 pass, 0 fail | 0 |
| 3 | 1335 tests, **1 failure**, 1 skipped (6 excluded) | 52 pass, 0 fail | 2 |
| 4 | 1335 tests, 0 failures, 1 skipped (6 excluded) | 52 pass, 0 fail | 0 |
| 5 | 1335 tests, 0 failures, 1 skipped (6 excluded) | 52 pass, 0 fail | 0 |

**Reported as intermittent: 1 failure in 5 runs.** Run 3's failure:

    1) test fast-exiting children never fail spawn (already-exited reconciliation)
       (Shoestring.Harness.ClaudeHeadless.TransportTest)
       test/shoestring/harness/claude_headless/transport_test.exs:71
       left:  {:ok, pid}
       right: {:error, :group_leader_unverifiable}

This is the load-sensitive spawn/reap race that `elf-flake-fix.md` already
characterises for this repository, in a test whose whole subject is that
reconciliation, in code this branch does not touch. Isolated it does not
reproduce: **0 failures in 10 isolated runs on this branch and 0 in 10 at
base** (VERIFIED). **Cause not established**, and the failing run is
reported rather than discarded.

### Previous round (the pre-review head of this branch)

Also five runs, also one failure, a *different* one:

    1) test an admitted claim issues a lease and commits proposed→granted→active
       (Shoestring.Cobbler.LeaseGrantTest)
       test/shoestring/cobbler/lease_grant_test.exs:39
       ** (Exqlite.Error) Database busy   — in setup, INSERT INTO "goals"

Also a contention failure in an unrelated suite's `setup`, also not
reproduced at base, also unexplained. Recorded here so the branch's history
is not read as one flake rather than two.

### Base comparison

`mix precommit` at base `6f1653f`, five runs: `1302 tests, 0 failures,
1 skipped (6 excluded)` every time (VERIFIED). Base runs a smaller suite, so
this is not evidence that base is less flaky — only that neither observed
failure reproduced there.

### Test-count accounting

Base 1302 + 27 (`handoff_confirmation_test.exs`) + 6
(`run_terminal_before_start_test.exs`) = **1335**. No other test file gained
or lost a test; `state_machine_test.exs` gained two rows in its
`@run_transitions` spec map, which the existing tests iterate rather than
count separately.

### Base-regression results for the two locks

| Suite | On this tree | At base `6f1653f` |
|---|---|---|
| `handoff_confirmation_test.exs` | 27 tests, 0 failures | 27 tests, **14 failures** |
| `run_terminal_before_start_test.exs` | 6 tests, 0 failures | 6 tests, **5 failures** |

Every base failure is at the same surface and for the intended behavioural
reason; the per-test breakdown is in §7.1 and §7.3, and each suite's
moduledoc names its controls separately from its locks.

### Focused suites

`mix test test/shoestring/cobbler/ test/shoestring/harness/ test/shoestring/elves/`
→ **989 tests, 0 failures, 1 skipped (6 excluded)** (VERIFIED). This range
covers every module this branch changed plus the suites that specify them:
`observatory_lease_reference_test.exs` (the ownership boundary §7.2 declines
to move), `state_machine_test.exs` (the exhaustive transition spec), and the
whole Elf and Cobbler surface.

### What the gate does not run

The 1 skipped is the designed capability-appropriate skip in
`Shoestring.Harness.ClaudeHeadlessContractTest`; the 6 excluded are the
`@tag :live` provider smoke tests, which were **not** run. The live provider
work in this document ran outside the gate, through a disposable operator
script.
