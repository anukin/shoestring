# Iteration 7: live Claude Code fan-out

Date: 2026-10-15. Baseline: `52fceeb` (goal cancellation status). This closes
retained limit 1 of the [final acceptance packet](final-acceptance.md): "no live
Codex/Claude fan-out".

## Authorization and registered bound

VERIFIED (user direction): the user asked to "go ahead and do item 1 and 6".
That was in reply to a list in which item 1 was the live provider fan-out and
was described as needing a budgeted live run. For the iteration 6 live runs the
user said they have Codex and Claude Code subscriptions and not to worry about
budgets. The brief names no budget, so this registration sets a deliberately
small bound and treats it as binding:

- provider Claude Code (subscription), saved Worker role, model alias `opus`;
- one plan of three tasks, one attempt per task, no replacement; at most
  **three provider runs**, 300 s per task, 1,500 s charged per goal;
- reservation policy for this disposable node only: global 2,
  provider-account 2, goal 2, account units 2, task units 1;
- no second live attempt without asking the user again.

Direct-main development and push remain authorized for iteration 7. No
automated test calls a provider.

## Fixture and plan

REPO-INSPECTION: `tools/live_eval/iter7_claude_fanout.exs` creates a disposable
Python repository with three stub modules and their tests: `north.py`,
`south.py` and `join.py` (which imports both). The plan tasks are:

- `north` and `south`, independent, each with declared scope of its own module
  and test;
- `join`, depending on both.

Each task gate runs its named test with `python_unittest`. The goal gate runs
all three. The committed default stays fan-out off. The driver enables
`:plan_fanout` and the reservation policy only in its own node, with its own
state directory.

The driver runs as separate `MIX_ENV=prod mix run --no-start` boots, one per
phase (`setup`, `fanout`, `integrate`, `join`, `export`). Every phase is a
restart of the same state. The production `PlanExecutionWorker`,
`PlanFanoutDriver`, `DispatchWorker`, `PlanChildWorker`, Elf, real
`ExecutionAdmission` and `ClaudeHeadless` transport run through Oban queues.
Claude's passive monitor reports `conservative_partial` support, so each task
needs its own human capacity confirmation (`confirm-capacity`), as in
iteration 6. The driver acts as the human only for:

- the confirmations;
- merging the two retained private branches into the disposable fixture
  repository;
- recording that merge with `integrate`;
- `continue`.

Claude launches through the reviewed iteration 6 launcher
(`tools/live_eval/claude_fixture_launcher.py`, unchanged). The launcher
applies:

- safe and restricted mode, Bash as the only tool, an enforced sandbox and no
  network domains;
- writes confined to the run's own worktree and private store, with writes to
  the fixture source denied.

The launcher reads the fixture path from `ITER6_REPOSITORY`; the driver checks
it equals its own fixture.

## Registered acceptance

1. `north` and `south` are admitted, reserved and run concurrently in separate
   private stores. Two Elves are live at once, two reservations are
   outstanding, and their running intervals overlap. `dispatch_mode` is
   `fanout_v1`.
2. Both are accepted by their own gates and change only their own module. The
   fixture repository is untouched until the human merge.
3. `join` stays locked (`integration_required`) until the human records an
   integration commit. After `continue`, it runs from that commit and is
   accepted.
4. The execution completes with the goal gate at an integrated revision. The
   run count is exactly three, no reservation is left outstanding, and the
   goal row is `completed`.
5. The exported runtime identity reports the model and CLI version that
   actually ran. Provider usage fields (five-hour/seven-day utilization, cost
   and duration) are exported per run where Claude reports them.
6. Failures and configuration differences are retained. Only selected
   canonical facts, public answers, commands, diffs, gate results and safe
   numeric observations are exported. Paths are substituted with
   `$EVALUATION`/`$USER_HOME`. No raw frames, session/message identifiers,
   credentials or reasoning are exported.

## Pre-live rehearsal and the defect it found

VERIFIED: before any provider call, the same driver ran in `rehearsal` mode
with the Fake adapter, which makes no provider call, in a disposable directory.

The first rehearsal failed. Both children were admitted
(`confirmed_support_tier_conservative_partial`), but neither was dispatched,
and the worker step failed with `{:error, :fanout_execution_required}`. Oban
retried until the job was discarded. Each retry found the one-shot
confirmations consumed and recorded `require_confirmation`.

REPO-INSPECTION: root cause:

- `PlanExecutionWorker.options/1` pinned `now` once, before the step
  (`7c5fb06`).
- Real `ExecutionAdmission.admit/4` evaluates later, on the live clock.
- Since reservations (`e64687e`), `Reservations.acquire/4` requires
  `admission.evaluated_at <= now`, so every hold was refused with
  `reservation_admission_mismatch`.

This affects every production dispatch through the worker whenever a
reservation policy is configured. `PlanDispatch` reads
`:plan_reservation_policy` from configuration for the sequential executor too.
That covers fan-out, its sequential fallback, and dependents after
integration. Hermetic tests missed it because their admission stubs use the
same frozen clock.

The iteration 6 live run predates `e64687e`, and the default configuration
(no reservation policy) dispatches sequential work under the legacy claim,
which has no such check.

Fix:

- The worker passes its clock instead of a pinned instant.
- `PlanFanout`, `PlanExecutor` and `PlanSiblingWorkspace` read that clock when
  they need the time.

A reservation is therefore taken after its admission. Injected fixed clocks
stay deterministic.

VERIFIED: `test/shoestring/cobbler/plan_worker_admission_clock_regression_test.exs`
drives `PlanExecutionWorker.perform/1` with a clock that advances during
admission, as the real clock does. On `52fceeb` it exited 2 with **2 tests,
2 failures**:

- fan-out returned `{:error, :fanout_execution_required}` instead of
  dispatching two children;
- sequential dispatch with a configured policy returned
  `{:error, :reservation_admission_mismatch}`.

Both pass on the fix. The second rehearsal then failed only from rehearsal
configuration: the Fake override lacked `process_owner: :runner`, so both runs
ended as `os_pid_unavailable`. This is not a product defect.

VERIFIED: the third rehearsal completed through the production worker:

| Check | Result |
| --- | --- |
| Concurrency | max 2 live Elves, 2 outstanding reservations; north/south running intervals overlap |
| Fan-out | `dispatch_mode: fanout_v1`; both accepted; 0 reservations outstanding afterwards |
| Source | fixture HEAD unchanged and clean |
| Join | unlocked after both acceptances (no files changed, so integration was trivial), accepted, execution completed |
| Restarts | every phase a fresh boot of the same state |

VERIFIED (new finding): in the second and third rehearsals, one of the two
concurrent dispatch deliveries hit `Exqlite.Error Database busy`. It happened
while recording the effect outcome, after its Elf had launched; the busy
timeout is 2 s. The dispatch row stayed `effect_started` and its job became
retryable.

REPO-INSPECTION: the retry does not relaunch. `prepare_for_effect` skips an
`effect_started` dispatch and records `dispatch.effect_unknown`, and the
retried job was cancelled on attempt 2. The run itself completed and was
accepted. The consequence is a misleading diagnostic dispatch outcome, not a
duplicate or lost run. Which transaction held the write lock for over 2 s was
not identified; this is retained as a limit.

VERIFIED: `mix precommit` on the fix exited 0: **4 doctests, 2167 tests,
0 failures, 1 skipped (6 excluded)**, seed 542803, 433.9 s. JavaScript passed
**52/52** and **8/8**.

UNVERIFIED (at registration commit time): the live run is pending. Results
follow below once it has run.
