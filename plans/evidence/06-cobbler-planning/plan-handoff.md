# Explicit saved-role plan handoff

REPO-INSPECTION: this successor closes the cross-provider plan-continuation
limitation recorded in `quota-continuation.md` and `duration-budgets.md`.
Historical evidence remains unchanged. The user explicitly authorized work on
main without another branch or PR; this overrides the standing isolation/PR
workflow for this work. No live provider run was authorized or performed.

## Authority and effects

REPO-INSPECTION: a plan-bound `run.handoff` must name `receiver_role`. It resolves
against the sender's immutable saved agent revision and digest, selecting an
explicit model on another provider. Unknown roles, defaults, missing roles and
provider/adapter mismatches are rejected before a handoff delivery job is queued.
Legacy unplanned handoffs retain their existing payload/result shape; adding a
saved role to an unplanned run is rejected.

REPO-INSPECTION: the canonical accepted command reserves the receiver dispatch
identity and full saved-role binding. Worker delivery checks that canonical fact
against the command cache and immutable configuration before observing receiver
capacity. Run creation, dispatch authorization and pure lineage reconstruction
also require that exact command; fabricated handoff metadata cannot authorize a
provider/profile change. Approval, worktree, task and attempt bindings stay exact.

REPO-INSPECTION: the parent needs a definitive owned Elf terminal, identified by
`elf-terminal:<dispatch_id>`, for quota refusal, interruption or cancellation.
A suspension request remains retryable until definitive termination; it cannot
cause transfer even through direct run creation. Live ownership, stale approval,
resolved attempts, competing lineage and exhausted duration refuse transfer.
No timer or staleness signal interrupts a provider.

REPO-INSPECTION: fresh receiver admission still owns its decision and lease.
Refusal creates no receiver or fallback. The receiver starts a fresh session with
bounded checkpoint context plus the pinned saved instructions; sender transcripts
and provider session-resume hints do not carry over. A receiver continuation
keeps the selected model/role and original plan attempt. Task acceptance unlocks
the dependent under the original execution role; handoff creates no extra task or
automatic cross-provider review stage.

REPO-INSPECTION: `mix shoestring.execution handoff` queues only, with exact
execution/run/checkpoint/decision references, receiver role/scope, command ID,
reason and human attribution. Read-only status exposes the current checkpoint,
exact decision references and active saved role/provider. It offers no
provider/model override. An optional
capacity confirmation is scoped and attributed to the goal's durable owner; all
hard admission stops remain enforced. Identical replay after delivery converges;
changed references or role conflict. Startup repairs a discarded delivery from
the same standing intent.

## Verification

VERIFIED: the final focused command was:

```sh
MIX_ENV=test mix test test/shoestring/cobbler/plan_handoff_test.exs test/mix/tasks/shoestring_execution_handoff_test.exs test/shoestring/cobbler/handoff_production_test.exs test/shoestring/cobbler/handoff_crash_window_test.exs test/shoestring/cobbler/plan_continuation_test.exs test/shoestring/cobbler/execution_profile_test.exs test/mix/tasks/shoestring_execution_test.exs
```

VERIFIED: **90 tests, 0 failures**, seed **964083**, **3.2 seconds**. The new
files contribute 19 tests. The worker test runs the normal HandoffWorker and
DispatchWorker with a supervised Fake/local `cat`, verifies the exact receiver
model despite a conflicting runtime option, waits for owned process termination,
and records task acceptance. It does not contact a provider. A fixture requiring
both quota windows initially lacked weekly data; the admission refusal was
correct and the synthetic fixture was fixed. Pause fixtures were corrected to
follow `starting → running → pausing → suspended`. CLI JSON serialization and
its test's changing reference list were corrected before the final run. The
observed SQLite client-exit diagnostic did not fail that run.

VERIFIED: against pre-fix commit
`e70ce7585e8c497c41a0e04d32766a1fe08edcba`, an isolated archived checkout with
copied test/support files ran:

```sh
MIX_ENV=test mix test test/shoestring/cobbler/plan_handoff_test.exs --only plan_handoff_regression
```

VERIFIED: **2 tests, 2 failures, 14 excluded**, seed **736368**, **0.5 seconds**.
The explicit receiver test failed at transfer with
`{:handoff_run_failed, :invalid_execution_profile}`. The missing-role test
expected rejection but the old code resolved and queued the implicit handoff.
These are behavioral failures at existing APIs, not missing-module/signature
failures. The other tests specify the new capability and are not claimed as
independently verified pre-fix regression locks.

VERIFIED: an initial `mix precommit` attempt stopped at format checking before
any tests; the helper formatting was corrected. The next `mix precommit` exited
0 with **4 doctests, 1889 tests, 0 failures, 1 skipped, 6 excluded**, seed
**940951**, **173.6 seconds** (9.1 async / 164.4 sync), and JavaScript suites
**52/52** and **8/8**. Read-only continuation status and malformed-run validation
were then added. The final **`mix precommit`** exited **0** with **4 doctests,
1889 tests, 0 failures, 1 skipped, 6 excluded**, seed **198460**, **173.6 seconds**
(9.5 async / 164.0 sync), and JavaScript suites **52/52** and **8/8**. No handoff test was
skipped or relaxed, and no retry wrapper was added to obtain these results. Existing expected failure
scenario diagnostics appeared in the gate output; the completed gate reported
zero test failures.

## Limits and next work

UNVERIFIED: no live provider behavior, quota consumption or model-generated plan
quality was verified. Worker delivery here uses Fake; material Git worktree/gate
and application-restart behavior has separate executor evidence. The composed
planner/edit/approval/execution/restart demo and repository-goal semantic planner
evaluation remain iteration-6 work. This record does not declare the iteration
complete.
