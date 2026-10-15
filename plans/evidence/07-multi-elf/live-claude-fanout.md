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

## Live attempt 1: failed, no task accepted

VERIFIED: the user ran the six phases themselves on 2026-10-15 (the
permission classifier had stopped the assistant's own invocation) under the
bound above. Redacted evidence is in
[live-claude-fanout/attempt-1](live-claude-fanout/attempt-1/): phase records,
the export phase (run afterwards, model-free) and the two launch settings with
`$EVALUATION`/`$USER_HOME` substituted. Message text is byte-identical to the
stored events.

| Check | Result |
| --- | --- |
| Provider runs | **2 of the 3 registered**: north and south, `claude-opus-5-5`, CLI 2.1.300, Bash only, `dontAsk` |
| Concurrency | both admitted after per-task confirmation, `dispatch_mode: fanout_v1`, both `run.running` within 1 ms of each other |
| Work | each Elf changed only its own module, and its named gate passed inside the sandbox (2 tests each) |
| Commit | **failed in both**: `fatal: unable to access '$HOME/.gitconfig': Operation not permitted` |
| Outcome | north `gate_failed` with `gate_worktree_dirty` (`task_failure`); the execution needs the user; south's run completed after the driver stopped the phase, so it stayed `awaiting_verification` |
| Source | fixture repository untouched (`98f7c38`, clean) |
| Usage | Claude-reported cost 0.085 and 0.094 USD (subscription), 15.0 s and 21.4 s; five-hour utilization 0.33→0.34, seven-day 0.56 |
| Diagnostics | both dispatches recorded `dispatch.effect_unknown` (see below) |

North then tried `GIT_CONFIG_GLOBAL=/dev/null`, and the `dontAsk` permission
mode denied the command. Neither Elf tried any other way round the sandbox.
The task brief asked for a clean committed worktree, so the gate was right to
refuse.

The user's second invocation of the phases on the same root failed at setup by
design (`identity.json` already existed); it made no provider call.

### Cause: Git cannot read its global config inside the sandbox

VERIFIED: the launcher denies reads under the home directory. Git exits 128
when its global config there is unreadable (not merely absent). A Seatbelt
profile that denies reads under the home directory reproduces the exact
message with `/usr/bin/git` 2.50.1 and no model call. With
`GIT_CONFIG_GLOBAL=/dev/null` alone, `git status` still warns that the default
excludes file is unreadable. Also pointing `core.excludesFile` and
`core.attributesFile` at `/dev/null` makes the commit succeed with no output.

UNVERIFIED: why iteration 6 committed under identical sandbox settings. That
run used Claude Code 2.1.296; this one used 2.1.300.

Fix (driver only; the reviewed launcher is unchanged):

- The Elf environment carries `GIT_CONFIG_GLOBAL=/dev/null` and, through
  `GIT_CONFIG_COUNT`, `core.excludesFile`/`core.attributesFile=/dev/null`.
  The private store already carries the fixture identity in its own config.
- The `preflight` phase commits in a throwaway repository under the same
  home-deny Seatbelt profile with that environment, before any provider call.
  Any Git warning or failure stops it. With the environment removed, the
  preflight fails at that check.

UNVERIFIED until a live run: that Claude Code's sandboxed Bash passes the
environment through to `git`.

### Dispatch completion lost to SQLite snapshot conflicts

The busy finding registered above is now root-caused for its common form.

VERIFIED: transaction telemetry on Fake rehearsals (diagnostic copy of the
driver, not committed) showed most `Database busy` errors returning after
**0 ms**, with no busy wait. The cause:

- `Dispatches.complete_effect/2` and `record_effect_outcome/3` opened
  *deferred* transactions that read the dispatch and then updated it.
- Under WAL, a writer committing between the read and the update makes SQLite
  fail the update at once (a stale read snapshot cannot be upgraded), and
  `busy_timeout` does not apply.
- With two Elves streaming events, that is likely. The launched run's
  completion raised, the job retried, the retry found `effect_started` and
  recorded `dispatch.effect_unknown`.

VERIFIED: in live attempt 1 both dispatch jobs carry exactly this error,
`Database busy` on `UPDATE harness_dispatches`, before `effect_unknown`.

The Cobbler stores already open their read-then-write transactions with
`mode: :immediate`. This fix does the same for both dispatch functions and for
the harness and trajectory projectors' apply/rebuild transactions, which showed
the same 0 ms busy on `projector_positions`. `PlanGoalStatus.sync/2` has the
same read-then-write shape; it runs only in startup repair and explicit sync,
and was changed after this section was written (below).

VERIFIED: `test/shoestring/harness/dispatch_effect_snapshot_regression_test.exs`
uses an independent WAL database with real pooled connections (no SQL
sandbox, which would turn the transaction into a savepoint). A telemetry hook
commits a second writer right after the transaction's read. In an archive of
`53a07ba` (the pre-fix commit), the user's checkout untouched, it failed
**2 tests, 2 failures**: both functions raised `Exqlite.Error` "Database busy"
on the `UPDATE`, in 0.1 s against a 5 s busy timeout. On the fix it passed
**2 tests, 0 failures** on seeds 1–6. The projector change is not
regression-locked: the projectors use the sandboxed application repository,
where no real second connection exists.

### Oban on SQLite: remaining busy and queue restarts

VERIFIED (rehearsals, Fake adapter, no provider call; counted from each
node's `oban_jobs.errors` and, where enabled, the diagnostic transaction log):

| Busy form | Before the fix (8 nodes) | After the fix (5 nodes: rehearsals 5, 6, 8, 9, 10) |
| --- | --- | --- |
| Instant `UPDATE harness_dispatches` busy (the fixed defect) | 5 (rehearsals 2, 3 and three diagnostic runs) | 0 |
| Waited busy: Oban ack `UPDATE oban_jobs`, or `database is locked` at `BEGIN IMMEDIATE` | 4 | 3 (rehearsals 5, 9, 10) |
| `dispatch.effect_unknown` recorded | 2 | 1 (rehearsal 9, two dispatches) |

Three pre-fix nodes stalled the driver to its deadline. One of them recorded
no busy error at all, only a restarted dispatch queue with orphaned rows; a
crashed producer's reason is not persisted. The fix removes the instant form
and does not reduce the waited form. The waited errors come after the full 2 s
busy timeout. Earlier telemetry showed a 2.1 s transaction whose plain
`SELECT` took 2.1 s. This matches the Exqlite 0.40 statement-destructor stall
diagnosed in iteration 6 (a write-lock holder blocks on another connection's
mutex while that connection busy-waits). The upstream fix belongs in Exqlite.

REPO-INSPECTION: two Oban 2.24 behaviours turn such a busy into a stall in
this driver:

- `Backoff.with_retry/1` retries `DBConnection.ConnectionError`,
  `Postgrex.Error` and `MyXQL.Error`, not `Exqlite.Error`. A busy during a job
  ack crashes the ack, and its fallback in the producer's `DOWN` handler is
  unprotected too. The row can stay `executing` with no process.
  Production's Lifeline rescues such rows after 5 minutes; the driver runs with
  `plugins: []`.
- A producer that crashes restarts with its configured pause state. The driver
  boots every queue paused so that each phase decides when work begins, so a
  restarted queue stayed paused.

Driver changes:

- Each wait poll resumes any phase queue found paused, and records it.
- `quiesce!` waits on the jobs actually running in the node, not on
  `executing` rows.
- Orphaned `executing` rows and queue restarts are exported in the `fanout`
  and `result` records.

VERIFIED: with these changes rehearsals 8, 9 and 10 passed end to end
(3 of 3); rehearsal 9 recorded one `plan_child_inbox` restart and two orphaned
rows. Rehearsal 6, before these driver changes, also passed. Rehearsal 5 failed
on a defect in the first version of the restart check (`check_queue/1` returns
`nil` while a producer restarts), which is itself evidence of a restart.

UNVERIFIED: the effect of the remaining busy on a live run, beyond misleading
`effect_unknown` diagnostics. No duplicate run was observed in any rehearsal.

### Unrelated stderr noise

REPO-INSPECTION: the `spawn: Could not cd to <checkout>/<run id>` lines in the
user's terminal come from Erlang's port spawner. `Worktrees.get/2` falls back
to treating a run ID with no record as a relative path and asks Git about a
directory that does not exist. The result is `:not_found`, which is correct.
The same lines appear in earlier gate logs. Nothing is created in the checkout.

### Verification after attempt 1

VERIFIED: `mix precommit` exited 0: **4 doctests, 2169 tests, 0 failures,
1 skipped (6 excluded)**, seed 940704, 442.0 s (9.5 s async, 432.4 s sync).
JavaScript passed **52/52** and **8/8**.

## After attempt 1: the remaining busy, fixed upstream

### Exqlite 0.40 → 0.42

REPO-INSPECTION: Exqlite 0.42.0's statement destructor no longer takes the
connection mutex when it is held: it `trylock`s and otherwise queues the
finalize, which the connection's holder drains after its SQLite call returns.
`release/2` does the same, locking the statement's own connection. The
Elixir-side changes from 0.40 are additive (an `:authorizer` connection
option). `ecto_sqlite3` 0.24.1 accepts it (`~> 0.22`). `mix.lock` is the only
dependency change; Oban and `ecto_sqlite3` are unchanged.

VERIFIED: `tools/diagnostics/exqlite_destructor_stall.exs` (raw Exqlite, no
application, no provider) reproduces the iteration 6 diagnosis. The lock
holder P has dropped a statement of connection B; the waiter Q busy-waits on
B; P collects garbage, writes and commits. Busy timeout 3 s, 12 runs each:

| Exqlite | Waiter locked out after the full timeout | Holder's insert |
| --- | --- | --- |
| 0.40.0 | **7 of 12** (`database is locked`, 3.2 s) | stalled 486–3154 ms in all 12 |
| 0.42.0 | **0 of 12** (lock granted in 121–127 ms) | 0 ms in all 12 |

Not regression-locked in the suite. Under `mix test` on 0.40.0 the probe's
own steps stalled the holder about 160 ms and the waiter got the lock (3 of 3);
two ExUnit drafts saw one lockout in 16 runs. Such a test would be
documentation, not a lock, so none was committed. The probe
is the evidence; rerun it after any Exqlite change.

VERIFIED (Fake rehearsals 11, 12 and 13 on 0.42.0, all phases, no provider
call): **3 of 3 passed**, with no job errors in any node, every dispatch
`effect_completed`, no queue restart and no orphaned `executing` row. Before
the upgrade the waited busy appeared in 3 of 5 rehearsals. Three clean runs
are evidence, not proof, that the waited form is gone. The Oban behaviours
above (no retry of `Exqlite.Error` during an ack, restart into the boot pause
state) are unchanged, and the driver keeps its handling for them.

### The same shape in `PlanGoalStatus.sync/2`

`sync/2` reads the goal and its plan history, then updates the goal row, in a
deferred transaction. It now takes the write lock at `BEGIN`, like the
dispatch functions. VERIFIED:
`test/shoestring/cobbler/plan_goal_status_snapshot_regression_test.exs` (same
independent WAL setup and racing writer as the dispatch test) failed **3 of 3**
seeds before the change with `Exqlite.Error` "Database busy" on
`UPDATE "goals"` (code of `abc4090`), and passed **6 of 6** seeds after it.

### The `spawn: Could not cd` noise

`Worktrees.get/2` falls back from a run ID to a path lookup, and the path
lookup asked Git about a directory that does not exist. It now returns
`:not_found` without spawning Git when the path is not a directory, which was
already the result. VERIFIED: a new case in `test/shoestring/worktrees_test.exs`
records the runner's commands. Before the change it received
`git rev-parse --git-dir` with `cd: <checkout>/run-unknown-5`; after it, none.
A real worktree path with no record still consults Git.

### Verification

VERIFIED: `mix precommit` exited 0: **4 doctests, 2171 tests, 0 failures,
1 skipped (6 excluded)**, seed 86046, 438.1 s (9.7 s async, 428.4 s sync).
JavaScript passed **52/52** and **8/8**. The log has one
`Exqlite.Connection ... failed to connect: database is locked` line from a
passing test; whether earlier gates logged the same line was not checked
(their logs are gone).

## Live attempt 2: authorization and bound

VERIFIED (user direction, 2026-10-15): "lets fi these issues. 3 more runs is
fine." This registers attempt 2:

- the attempt-1 bound, unchanged except that it allows **three more provider
  runs** (north, south, join), one attempt per task, no replacement;
- a fresh evaluation root, so no attempt-1 state is reused;
- no third attempt without asking the user again.

## Live attempt 2: passed, all three tasks accepted

VERIFIED: the assistant ran the six phases on 2026-10-15 from `8bb9139`
under the attempt-2 bound, on a fresh evaluation root. Redacted evidence is in
[live-claude-fanout/attempt-2](live-claude-fanout/attempt-2/): every phase
record, the export, and the three launch settings with
`$EVALUATION`/`$USER_HOME` substituted. A scan for home, temporary and
machine paths and for provider session/message identifiers found none.
Message text is byte-identical to the stored events.

| Registered check | Result |
| --- | --- |
| 1. Concurrency | north and south admitted after per-task confirmation, `dispatch_mode: fanout_v1`. `run.running` 0.25 ms apart; intervals 16.268–24.705 s and 16.268–28.047 s overlap. Peak 2 live Elves, 2 outstanding reservations (2 for the goal), 79 samples. Separate private stores (`.git-repositories/<run id>` in each launch setting) |
| 2. Own gates, own modules | both `accepted`. North changed only `north.py` (`f0b0336`), south only `south.py` (`1425f48`), each worktree clean. Fixture source head unchanged and clean after the phase |
| 3. Join waits for integration | join's confirmation, admission and dispatch all follow `cobbler.plan.integration.recorded` (human-recorded merge `4cf6109` of both accepted commits, no conflicts; at that commit north and south tests pass and join's fails). The `integration_required` reason is returned by the executor, not stored as an event, so the record shows the order but not the reason code |
| 4. Completion | join ran from `4cf6109`, changed only `join.py` (`764cfeb`) and was accepted. `cobbler.plan.execution.completed` carries the goal gate at `764cfeb`: all three test files, 6 tests, OK. Exactly 3 runs, 0 reservations outstanding, goal row `completed` |
| 5. Runtime and usage | `claude-opus-5-5`, CLI 2.1.301, Bash only, `dontAsk`, for all three. Claude-reported cost 0.0659, 0.0672 and 0.0655 USD (subscription); 11.6, 8.2 and 9.0 s; three turns each. Five-hour utilization 0.20→0.21, seven-day 0.62 |
| 6. Export | 32 events, 24 normalized (12 command, 6 lifecycle, 3 output, 3 result); no raw frames, reasoning or provider identifiers |

**Provider runs: 3 of the 3 authorized for attempt 2** (5 in total across both
attempts). No replacement, no retry.

The Git fix held: each Elf ran `git add` and `git commit` inside the sandbox,
and every command ended `is_error: false`. Claude Code also moved from 2.1.300
to 2.1.301 between the attempts, so this run does not separate the two
explanations for attempt 1's failure.

Diagnostics: no job errors in the node, no `Database busy`, every dispatch
`effect_completed`, no queue restart and no orphaned `executing` row.

Also recorded, as in attempt 1: each run has a `lease.expired` about 150 ms
before its `run.completed`. REPO-INSPECTION: this is the turn-outcome lease
renewal being refused after the turn has finished (`elf.ex`, the
`:expired` branch for a completed turn). The expiry marker stands and the
ordinary terminal path runs. Nothing was interrupted.

Join's public answer notes that it ran only its own test; the goal gate ran
all three.

