# Iteration 7: durable child inbox and wakeups

Implementation date: 2026-10-14. Baseline:
`ee133bb28b39ae7b665ae67493cdf4c4f026a1a1`.

## Implemented boundary

REPO-INSPECTION: the trajectory writer captures fan-out child source events in
the same immediate transaction as their inbox receipt and delivery job. The
allowlist covers normalized progress, lifecycle transitions, checkpoints,
suspension, quota refusal, failure, cancellation, completion and task verification
results. Capture also runs on source-event replay. Ordinary sequential/unplanned
runs do not receive inbox messages.

REPO-INSPECTION: each receipt stores only canonical event references and pinned
goal/execution/revision/digest/task/attempt/root/leaf identity. It copies no provider
session identifier, normalized output body, extensions, transcript or model
reasoning. Identity is checked against the canonical run request, current run
binding and durable reservation ancestry. Unknown identity fails closed. The
ancestry walk rejects cycles and chains exceeding 64 reservation owners.

REPO-INSPECTION: one durable job per pending receipt is selected under the write
transaction. Job IDs are disposable delivery references; a missing/discarded job
is replaced without deleting the old job, source event, worktree or owner. The
Lite engine's Job changeset is inserted through the repository so a repository-only
CLI writer does not require a running Oban process. The service's existing stager
discovers committed jobs; low-latency PubSub delivery is not required for safety.
The `plan_child_inbox` service queue has two consumers and five attempts per job.

REPO-INSPECTION: a child worker observes exactly the referenced canonical event.
A successful/failed terminal can invoke that child's existing gate boundary
without calling `advance`, the fan-out admission producer or a model. Another
child's blocker does not prevent healthy sibling acceptance. Quota, cancellation,
interruption, suspension and checkpoint messages remain distinct source facts;
they never authorize acceptance or replacement. Verified terminal process owners
are reconciled; missing/ambiguous process identity retains capacity. A successful
terminal awaiting stop evidence stays pending with `awaiting_quiescence`; a
delivery snooze rechecks evidence only, never interrupts or duplicates an Elf.

REPO-INSPECTION: `cobbler.plan.child.observed` version 1 is a bounded canonical
acknowledgement with a source parent reference and immutable child binding. Its
typed outcome and optional verification-event reference retain delivery results.
The acknowledgement and receipt update commit together; notification follows
commit. Nested transaction callers own notification. Replay and crash after
verification reuse accepted/gate-failed/scope-blocked results rather than granting
another task attempt. Delivery is at least once; verification may rerun if a
process crashes before its canonical result commits. Exactly-once OS gate
execution is not claimed.

REPO-INSPECTION: startup replay uses bounded 128-event pages and canonical run
requests, recreating historical receipts and repairing delivery caches from
acknowledgements. Failures are counted with at most 128 diagnostic references.
It performs no verification, provider admission or Elf action itself. Unexpected
repair exceptions are reported without crashing the reconciler or adding retry
timers; pending source/receipt/job evidence remains intact. Processing
may acknowledge older source facts after newer ones; source sequence remains
authoritative and an old progress observation never regresses task acceptance.

REPO-INSPECTION: execution status exposes pending/observed counts and at most 128
pending source references with a completeness flag. Full history remains in the
trajectory and inbox store. Production fan-out dispatch remains disabled.

The user's direct-main/no-PR authorization overrides the standing isolation/PR
workflow for this checkpoint. All verification uses Fake and local commands;
no provider run was made.

## Regression and focused verification

VERIFIED: the existing-API regression was copied into an independent archive of
the baseline commit with separate build and state, without resetting the source.
`mix test test/shoestring/cobbler/plan_child_delivery_regression_test.exs` exited
2: **1 test, 1 failure**, seed 283823, 1.8s sync, 5.770s wall. Its first assertion
finds no durable child worker job after a later sibling's committed completion.
The failure is the intended missing behavior, not a missing module/signature.

VERIFIED: first focused run exited 0: **34 tests, 0 failures**, seed 719304,
53.7s sync, 57.709s wall. It includes inbox capture/rollback/replay and existing
writer/coordinator contracts.

VERIFIED: second focused run exited 0: **42 tests, 0 failures**, seed 728524,
95.2s sync, 96.658s wall. It includes final scope, reserved continuation and CLI
contracts plus an isolated normal-SQLite lifecycle wrapper. The wrapper requires
its child's output to report **4 tests, 0 failures**. The scenarios verify queued
completion while a sibling runs, scope conflict retention, competing coordinator
intent/targeted cancellation, and startup repair of discarded terminal delivery.
The final scenario also observes targeted never-started cancellation while
retaining the accepted sibling. No process-group probe is injected in that node.

VERIFIED: third focused run exited 0: **14 tests, 0 failures**, seed 321626, 25.1s sync, 26.495s wall. It adds exact
settlement checks for stopped quota-refused, interrupted and cancelled children.

VERIFIED: the first `mix precommit` exited 0: **4 doctests, 2110 tests,
0 failures, 1 skipped, 6 excluded**, seed 461581, 331.5s (9.8s async, 321.7s sync),
335.167s wall. JavaScript passed **52/52** and **8/8**, with zero failures or skips.
This run preceded the final startup-exception guard and strengthened historical
fixture, which now includes a legal starting transition and full harness rebuild.
VERIFIED: focused location checks for startup failure isolation and historical
rebuild exited 0: **2 tests, 0 failures, 14 excluded**, seed 960363, 3.7s sync,
4.808s wall. A real SQLite job-insert refusal leaves the reconciler serving a
state request and preserves the pending receipt/discarded job. Historical
backfill retains the exact source event across full harness projection rebuild.
VERIFIED: final `mix precommit` exited 0: **4 doctests, 2111 tests, 0 failures,
1 skipped, 6 excluded**, seed 557277, 337.6s (10.0s async, 327.6s sync),
341.124s wall. Format checking and compilation with warnings-as-errors passed.
JavaScript passed **52/52** and **8/8**, with zero failures or skips. The full gate
includes the isolated lifecycle wrapper and its four child scenarios, the final
checkpoint/suspension checks and startup failure isolation. No code changed
after this gate; this verification result was recorded afterward.

VERIFIED: all **27** checked local documentation links resolve. Path, attribution
and literal credential-assignment scans passed all **18** changed/new artifacts.
`git diff --check` passed. Unrelated untracked hook/plugin directories were left
untouched and excluded from this checkpoint.

## Remaining work and limits

UNVERIFIED: production fan-out activation, explicit human conflict resolution,
bounded retry/replacement, live child/goal cancellation recovery, generic goal-row
synchronization, bounded public Claude output and complete verification-budget
accounting remain pending. This package performs no automatic merge or provider
continuation. Fan-out continuation inbox lineage is implemented but a live
continuation inbox run was not verified. Production worker functions were invoked on persisted jobs with test queues
disabled; automatic queue polling was not exercised. Large-history
throughput/fairness and a
populated on-disk upgrade were not verified; historical canonical backfill is
covered separately. Gate metadata time still requires budget integration before
production activation. Iteration 7 remains in progress.
