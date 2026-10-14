# Atomic plan dispatch — 2026-10-13

REPO-INSPECTION addendum: [reservation continuations](reservation-continuations.md)
subsequently connected fresh wake/handoff ownership and terminal reconciliation
at plan advancement. Counts and limitations below describe this package's
implementation point; initial activation remains opt-in.

## Scope and activation

VERIFIED (user direction): continue iteration 7 directly on main without a PR,
overriding the standing worktree/PR workflow. Baseline:
`ecf5c5d660beec100ce6802d46cd9b25b787b4cc`. No provider calls were made.

REPO-INSPECTION: approved dependency-ready initial attempts can now opt into one
immediate transaction containing capacity ownership, prior-claim release,
new claim, trajectory task, run intent, canonical lease transitions, dispatch
record, Oban delivery job, and `cobbler.plan.task.dispatched`. Failure rolls
back the whole transaction. Admission observation and isolated workspace
preparation happen beforehand; their diagnostic evidence and worktree remain
available if the intent fails. No filesystem operation is claimed atomic
with the database.

REPO-INSPECTION: only trusted runtime configuration enables this path:
`:plan_reservation_policy` application configuration or a `reservation_policy:`
runtime option, containing a validated `ReservationPolicy` or its map. For
example, `%{}` selects version 1's conservative defaults of one. Planner and
CLI request payloads cannot supply this policy. Invalid configuration fails
closed. The production execution worker already forwards trusted runtime
options into the executor. The default configuration remains unset, preserving
the existing sequential path while continuation integration is unfinished.

REPO-INSPECTION: the global sequential claim remains enforced even if configured
reservation limits exceed one. This package enables no parallel production
execution. Per-task admission, approval/digest, budget, task lineage and effect
checks remain in the ordinary dispatcher. Reservation identity is deterministic
for the goal/task/attempt and records the selected canonical admission and its
snapshot, policy and lease bounds. It is held before the run intent exists.

## Event ordering and effect fences

REPO-INSPECTION: the explicit `writer_opts: [transaction_repo: repo]` append
path reuses the normal trajectory writer's payload validation, trusted-reference
ownership, idempotency and sequence assignment on the caller's connection.
It refuses callers outside a transaction and never invokes a second writer
process while the coordinator owns the write lock. Ordinary appends retain
their existing writer path.

REPO-INSPECTION: intermediate command/event notifications are suppressed;
new events are collected in sequence order and published after the coordinator
transaction commits. Notification failure does not erase committed intent.
If called within an enclosing transaction, the coordinator returns
`dispatch_events` and suppresses notification: that caller owns final commit
and publication. Returned events are pending until that outer commit succeeds.
Notifications remain ephemeral; durable child inbox/wakeup integration is a
later package, so this is not a claim of crash-safe PubSub delivery.

REPO-INSPECTION: run extensions bind the reservation ID. A marked run without
ownership is refused, as are changed reservation/execution/task/attempt
bindings. Lookup by run ID continues to guard earlier unmarked owners.
The ordinary `PlanBinding` boundary checks this at intent and effect admission.
Uncertain or settled owners cannot authorize fresh delivery. Reserved direct
resume remains refused. Inherited continuation extensions cannot authorize a
new run without its own reservation; fresh continuation coordination remains
pending rather than silently bypassing capacity ownership.

REPO-INSPECTION: the supervised local reservation writer serializes atomic
plan intent with explicit reconciliation, without SQL retries or cancellation.
SQLite transactions and uniqueness remain durable correctness boundaries;
the writer has no ownership state to lose on restart. The existing exclusive
claim is retained; distributed coordination and fairness are not claimed.

## Verification

VERIFIED: focused tests use Fake, synthetic identifiers, fixed clocks, local
commands and isolated databases. No provider CLI or network is used. Database
triggers inject failures at `run.requested`, `lease.active`,
`dispatch.requested` and `cobbler.plan.task.dispatched`. Each asserts that
reservation, run, lease projection, task, claim, dispatch and job are absent,
event counts are unchanged, and no notification escaped. A separate check
proves the previous claim is restored. Approval changes after selection,
capacity refusal, invalid policy, missing/forged/uncertain bindings and an
outer-transaction rollback are checked too.

VERIFIED: an isolated child node uses an ordinary connection pool rather than
the SQL sandbox. It checks post-commit notification visibility, restart after
intent, two real Fake worker/Elf completions, actual format gates, explicit
production-probe settlement, dependency advance, distinct private worktrees
and an unchanged source checkout. A second child test starts four concurrent
coordinators and asserts exactly one reservation, run, canonical task dispatch,
dispatch row and delivery job. The outer test requires **2 child tests,
0 failures**; the full gate counts this as one outer test.

VERIFIED: the focused command initially used these files:

```text
mix test test/shoestring/cobbler/plan_dispatch_test.exs test/shoestring/cobbler/plan_executor_test.exs test/shoestring/cobbler/reservation_runtime_test.exs
```

The integration file was added from run 3 onward:
`test/shoestring/cobbler/plan_dispatch_integration_test.exs`.

| Run | Exit | Actual result | Seed | Test duration | Finding/change before next run |
| --- | --- | --- | --- | --- | --- |
| 1 | 2 | 32 tests, 8 failures | 192199 | 9.1s sync | Transaction writer options did not reach lease issuance; propagated them |
| 2 | 2 | 32 tests, 1 failure | 243608 | 1.2s sync | Test used nonexistent `oban_job_id`; corrected to existing `job_id` |
| 3 | 2 | 33 tests, 1 failure | 439472 | 2.7s sync | Dispatch notification observer also handled earlier execution-request notification; attached it only to dispatch |
| 4 | 0 | 33 tests, 0 failures | 988159 | 8.4s sync | Lifecycle, restart, four-caller convergence and rollback checks passed |
| 5 | 0 | 36 tests, 0 failures | 272319 | 10.6s sync | Added outer rollback, transaction-required append and late approval-change checks |

VERIFIED: the first `mix precommit` exited **1** after **0.934 seconds** at
format checking, before running tests. The formatter required another pass
for multiline test calls; no assertion or timeout was changed. No unchanged
rerun was used to hide an intermittent failure.

VERIFIED: the final `mix precommit` exited **0**: **4 doctests, 1980 tests,
0 failures, 1 skipped (6 excluded)**, seed **779323**, **191.7 seconds**
(9.4 async, 182.2 sync), wall **195.189 seconds**. JavaScript passed **52/52**
and **8/8**, with zero failures or skips. Mix commands ran in the foreground,
with stdin closed; focused runs had a 180-second bound and the full gate
had a 480-second bound. The isolated child has its own 90-second bound.

VERIFIED: all **11 relative Markdown links** across the iteration-7 milestone
and evidence documents resolve. New artifacts contain no absolute home paths,
credential patterns or authorship trailers. The final staged diff passes
`git diff --cached --check`.

REPO-INSPECTION: these are new-capability checks. No baseline regression lock
is claimed: the baseline has no atomic reservation coordinator or explicit
transaction-local append API. Existing sequential, trajectory and continuation
tests remain part of the full gate.

## Remaining work

REPO-INSPECTION: before enabling reservation-backed execution by default,
connect canonical terminal settlement and fresh reservation admission to
quota wake/handoff/continuation paths, and prove cancellation/release for
existing never-started or ambiguous intents. Add CLI inspection/reconciliation.
The acceptance gate still requires independent sibling bases, overlap policy,
durable child inbox/wakeups and partial-failure handling before fan-out.
Iteration-6 goal-status, public-output and verification-budget follow-ups remain.

UNVERIFIED: I did not verify live providers, parallel execution, distributed
workers, fairness, crash-safe notifications or release of every ambiguous
launch state. The hermetic lifecycle deliberately calls explicit reconciliation
between tasks; automatic settlement is not claimed.
