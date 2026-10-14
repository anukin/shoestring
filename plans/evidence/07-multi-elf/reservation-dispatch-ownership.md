# Reservation-owned dispatch boundary — 2026-10-14

## Scope

VERIFIED (user direction): continue iteration 7 directly on main, without a PR
or approval stops. This overrides the standing worktree/PR workflow. Baseline:
`f6c852657932761e37d498a01303224e97ee6674`. No provider calls were made.

REPO-INSPECTION: `Dispatcher.claim_reserved_and_gate/4` consumes one specific
reservation within an enclosing intent transaction. `Commands.submit_reserved/4`
records a canonical `reserved` result binding reservation, goal, execution,
task, attempt, run and admission. It does not insert a global task claim or
return a reservation ID mislabeled as a claim ID. The existing sequential
executor retains its legacy claim and now forwards its reservation identity.

REPO-INSPECTION: the internal path requires a held, unsettled root owner,
matching canonical admission, no active legacy claim, and exactly one command
per reservation. Gating compares the command cache with its canonical event,
checks current approval/execution, required task, satisfied dependencies and
attempt bounds, and binds the grant's run and plan extension to the owner.
Run replay must retain task, workspace, dispatch and extensions. Admission
decision reuse cannot replay a different child's lease.

REPO-INSPECTION: run, lease and dispatch persistence use the enclosing repository
transaction. Notifications are suppressed until `PlanDispatch` commits. The
callback persists intent only; the normal durable dispatch pipeline owns effects.
Generic command submission, inspection and the goal-wide direct dispatch guard
cannot turn a reservation-owned result into legacy claim authority.

## Legacy interlock

REPO-INSPECTION: a new legacy claim is refused while reservations are unresolved,
except the exact sole reservation of an atomic sequential dispatch. Re-gating a
replayed legacy command performs the same check. A foreign active legacy claim
blocks reservation acquisition inside the write transaction. A same-goal prior
claim may coexist with inert reservation preparation so the sequential executor
can release it in its atomic dispatch; the reservation-owned dispatch path still
refuses every active legacy claim. No release, expiry or cancellation was added.

REPO-INSPECTION: legacy kickoff now preserves a claim whose command ID already
belongs to the selected attempt. A duplicate kickoff previously released that
claim, then replayed the immutable acquisition command against a released owner,
potentially stranding both callers before run creation. Prior-attempt claims
still use explicit release. Commands now share the existing local FIFO writer
with reservations to avoid competing native SQLite busy waits starving active
transactions. There is no retry, sleep or new ownership state; enclosing
transactions retain their connection and SQLite remains authoritative.

## Verification

VERIFIED: three existing-API interlock regression tests were copied into a
retained temporary archive of the baseline commit. They produced **3 tests,
3 failures** (exit 2, seed 343052, 0.2s sync): an unrelated legacy claim was
acquired, a foreign reservation was acquired, and replay reached the
execution-disabled boundary rather than refusing reservation ownership. These
were behavioral failures, with no missing modules or changed signatures.

VERIFIED: an independent-connection race test also failed on that baseline:
**1 test, 1 failure, 28 excluded** (exit 2, seed 740651, 0.7s sync). Both competing owners
committed. On the implementation it permits only the reservation or the foreign
legacy claim to win. The race uses separate SQLite connections and a message
barrier, with no sleeps or assertion retries.

```text
mix test test/shoestring/cobbler/reservation_legacy_interlock_test.exs
mix test test/shoestring/cobbler/reservations_test.exs:972
```

VERIFIED: new-capability checks cover two independently reserved children,
global/goal limits across goals, same-goal legacy refusal, canonical rebuild,
zero-duplicate replay, rollback at run/grant/delivery writes, no premature
notification, wrong goal/admission/run/task/execution bindings, changed approval,
missing transaction/lease, uncertain and settled owners, command cache tampering,
duplicate decision identities, and workspace/delivery replay changes.

REPO-INSPECTION: these checks use synthetic plans and the Fake adapter. They
exercise durable intent and effect preparation, not concurrent live Elf execution
or automatic production coordination. The new-boundary tests are capability
tests, not claimed pre-fix regressions.

Focused commands:

```text
mix test test/shoestring/cobbler/reservation_dispatch_test.exs test/shoestring/cobbler/reservation_legacy_interlock_test.exs test/shoestring/cobbler/plan_dispatch_test.exs test/shoestring/cobbler/reservation_continuation_test.exs
mix test test/shoestring/cobbler/reservation_dispatch_test.exs test/shoestring/cobbler/reservation_legacy_interlock_test.exs test/shoestring/cobbler/plan_dispatch_test.exs test/shoestring/cobbler/reservation_continuation_test.exs test/shoestring/cobbler/reservations_test.exs
mix test test/shoestring/cobbler/task_claim_race_test.exs test/shoestring/cobbler/reservation_dispatch_test.exs test/shoestring/cobbler/reservation_legacy_interlock_test.exs test/shoestring/cobbler/plan_dispatch_test.exs test/shoestring/cobbler/reservation_continuation_test.exs test/shoestring/cobbler/reservations_test.exs
mix test test/shoestring/cobbler/plan_dispatch_claim_recovery_test.exs test/shoestring/cobbler/plan_executor_test.exs test/shoestring/cobbler/task_claim_race_test.exs test/shoestring/cobbler/reservation_dispatch_test.exs test/shoestring/cobbler/reservation_legacy_interlock_test.exs test/shoestring/cobbler/plan_dispatch_test.exs test/shoestring/cobbler/reservation_continuation_test.exs test/shoestring/cobbler/reservations_test.exs
mix test test/shoestring/cobbler/plan_dispatch_claim_recovery_test.exs test/shoestring/cobbler/plan_executor_test.exs test/shoestring/cobbler/commands_test.exs test/shoestring/cobbler/task_claim_race_test.exs test/shoestring/cobbler/reservation_dispatch_test.exs test/shoestring/cobbler/reservation_legacy_interlock_test.exs test/shoestring/cobbler/plan_dispatch_test.exs test/shoestring/cobbler/reservation_continuation_test.exs test/shoestring/cobbler/reservations_test.exs
```

| Run | Exit | Actual result | Seed | Duration |
| --- | --- | --- | --- | --- |
| 1, first command | 0 | 37 tests, 0 failures | 8531 | 1.2s sync |
| 2, expanded command | 0 | 72 tests, 0 failures | 978694 | 3.7s sync |
| 3, expanded command | 0 | 75 tests, 0 failures | 927832 | 3.4s sync |
| 4, with legacy race fixture | 0 | 78 tests, 0 failures | 437218 | 3.5s sync |
| 5, with kickoff regression/executor | 2 | 99 tests, 1 failure | 868933 | 9.2s sync |
| 6, both kickoff modes and commands | 0 | 126 tests, 0 failures | 745811 | 3.6s sync |

VERIFIED: first full `mix precommit` exited 2: **4 doctests, 2052 tests,
2 failures, 1 skipped, 6 excluded**, seed 818223, 214.1s (10.9s async,
203.1s sync), 217.612s wall. JavaScript suites passed **52/52** and **8/8**,
both with zero failures/skips. Both failures were the legacy claim-race fixture's
scratch schema missing the newly required reservation tables. Its migration list
now includes reservation, settlement and parent ownership migrations; assertions
were unchanged. Focused run 4 verifies that fixture and the affected boundaries.
This was a concrete fixture defect, not an intermittent assertion failure.

VERIFIED: second full `mix precommit` exited 2: **4 doctests, 2052 tests,
1 failure, 1 skipped, 6 excluded**, seed 444768, 198.6s (9.2s async,
189.3s sync), 202.125s wall. Both JavaScript suites again passed 52/52 and
8/8, with zero failures/skips. The concurrent kickoff assertion observed zero
runs instead of one: intermittent, **1 of 2 full runs** before the claim fix.

VERIFIED: a deterministic already-accepted-claim regression reproduced
`no_active_claim` on both the in-progress implementation (1 test, 1 failure,
seed 906448) and the baseline (1 test, 1 failure, seed 209689), each in 0.1s.
The final two-mode regression file also failed on the baseline with **2 tests,
2 failures**, seed 166297, in 0.1s. Both failures were the same lost-claim behavior, not
missing APIs. Focused run 6 passes both legacy and reserved kickoff modes while
asserting the claim stays identical and exactly one run/delivery/job exists.

VERIFIED: focused run 5 failed on a native SQLite `BEGIN IMMEDIATE` busy error
in the new competing-owner test: intermittent, **1 of 4 expanded focused runs**
(runs 2–5). Command transactions now use the existing reservation FIFO writer;
run 6 verifies command responses, competing claims and reservations together.
Assertions, timeouts and retry policy were unchanged. Separate-process writer
contention outside the local queue was not verified by this checkpoint.

VERIFIED: final full `mix precommit` exited 0: **4 doctests, 2054 tests,
0 failures, 1 skipped, 6 excluded**, seed 254700, 199.6s (9.9s async,
189.7s sync), 203.168s wall. JavaScript suites passed **52/52** and **8/8**,
both with zero failures/skips. Format checking and compilation with
warnings-as-errors passed. No assertion was skipped, widened, slept or retried
to pass the new checks.

VERIFIED: local documentation link validation passed all 17 links. Sensitive
path/credential/attribution scans passed all five new artifacts, and
`git diff --check` passed. Existing untracked hook/plugin directories were
left untouched and excluded from this checkpoint.

VERIFIED: initial sandboxed `mix help format` and `mix help test` both exited 1
because Mix could not open its local PubSub socket. Both help commands and
subsequent formatting/tests succeeded with the required sandbox escalation.

## Remaining integration

REPO-INSPECTION: follow-up [internal coordinator evidence](internal-fanout-coordinator.md)
records initial sibling dispatch integration and concurrent supervised Fake
proof. The remaining statements below describe this boundary's original
checkpoint; production activation and full lifecycle/conflict work remain pending.

UNVERIFIED: production fan-out remains disabled. The coordinator must select
safe ready candidates, bind prepared sibling workspaces, apply lifetime budgets
across all children, record task dispatch lineage and preserve successful sibling
branches without automatic merging. Actual-diff acceptance, durable child
inbox/wakeups, partial-failure recovery and full concurrent lifecycle evals remain
pending. Generic goal status synchronization, global gate budgeting and bounded
public Claude output are still prerequisites. This checkpoint does not close
iteration 7 or broaden goal-wide dispatch permission.
