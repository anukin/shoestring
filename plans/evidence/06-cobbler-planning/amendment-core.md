# Approved manual amendment core — 2026-10-08

REPO-INSPECTION: pre-fix main `5b661c61e940ae27a86d41c30ad83243fd452828`.
Direct main implementation/commit/push follows the user's explicit authorization,
overriding standing worktree/PR isolation rules. No new branch, provider call,
quota budget or hidden reasoning. User-owned untracked directories stay untouched.

## Contract and implementation

REPO-INSPECTION: Plans now protects accepted task contracts and repository bindings
at proposal, approval and activation. Late accepted evidence is rechecked at each
boundary; rejection/replay keeps existing history intact. Execution activation
uses the plan store's immediate transaction, validating live revision/digest,
existing request payload, accepted evidence, unresolved task and a two-activation
lifetime ceiling (initial plus one amendment). Further approval cannot move an
exhausted execution authority to an ineligible revision.

REPO-INSPECTION: activation also refuses an unresolved durable plan-bound run
when its executor dispatch bookkeeping event has not yet committed. New run
intent creation checks plan authority in the same immediate write transaction;
existing identical intent recovery remains available after supersession. This
closes both orders of that window without cancelling existing work.

The latest activated revision drives remaining work. Accepted IDs/evidence and
attempt/gate-duration counters span the goal's prior execution history. Attempt
ordinals continue; deterministic run/dispatch/command IDs cannot reuse a spent
ordinal. Canonical accepted events are unchanged. Global gates and subsequent
worktrees use cumulative accepted commits across both execution revisions.

These are conservative manual amendment decisions: changed accepted work must
have a new ID while its original stays recorded; an unresolved run cannot be
silently retired/replaced. Explicit retirement and model-assisted replan remain
open. Existing initial-planner row/ledger/call/token ceilings are untouched;
this implementation provides no extra inference call or quota reservation.

## Behavioral and integration proof

VERIFIED: six tests at the pre-fix commit's source archive, using existing domain
APIs and only the new test file:

```
perl -e 'alarm 120; exec @ARGV' mix test test/shoestring/cobbler/plan_amendment_test.exs < /dev/null
```

6 tests, 6 failures, seed 844208, exit 2. Broken code accepts changed completed
contracts/late approval/late activation, accepts replacement of active work,
forgets to activate the new execution revision, and permits an exhausted further
approval. These are behavioral failures, not absent modules or changed signatures.
The supersession/carry test fails when status still reports revision 1 after the
new approved request; later assertions lock ordinal/duration/evidence preservation.

VERIFIED before the full gate exposed the canonical-lineage defect: the original
six-test file passes 6 tests, 0 failures, seed 785467.
The test additionally compares the original canonical accepted event unchanged
across activation and checks both refused completed changes and retained valid
remaining-task changes. Existing executor-focused tests passed 47 tests,
0 failures, seed 394152 before adding these six tests.

VERIFIED: extended real-worker/worktree/gate child-node integration: 1 test,
0 failures, seed 107974. Alpha passes real named gates; beta's outcome changes in
a new proposal. Activation is refused before exact human approval, then carries
alpha's acceptance/attempt/duration state into revision 2. Application restart
preserves it, and the normal Fake worker completes beta and global acceptance.
This is new composed proof; the source archive locks above are separate regressions.

VERIFIED: the final seven-test file fails on the same pre-fix source archive:
7 tests, 7 failures, seed 983669, exit 2. The added lineage test observes nil
canonical run/task columns on dispatched/accepted events. The final carry test
also stops at its strict run-scoped evidence query; the earlier six-test variant
independently verified failure to activate revision 2. No production APIs were
added to the archive. After the fixes, the amendment, executor and extended
integration files passed together: 28 tests, 0 failures, seed 884397, exit 0:

```
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_amendment_test.exs test/shoestring/cobbler/plan_executor_test.exs test/shoestring/cobbler/plan_executor_integration_test.exs < /dev/null
```

REPO-INSPECTION: executor task evidence now sets canonical run/task lineage from
the durable RunRecord in addition to payload references. Historical events are
not rewritten. The carry test retains an exact comparison of the original event.

UNVERIFIED: no live providers, model amendment inference, explicit retirement,
quota wake/handoff continuation, immutable agent/model dispatch binding, CLI
execution entrypoint, or full elapsed run-duration accounting. The fixture is
not a multi-task source-code integration proof. Full iteration 6 remains open.

## Full gate

VERIFIED: the first full gate returned exit 2: 4 doctests, 1794 tests, 2 failures,
1 skipped (6 excluded), seed 29622, 179.6 seconds. Node suites passed 52/52 and
8/8. The failures were the missing canonical lineage described above and the
existing approval-race fixture losing its lock owner to a connection timeout.

VERIFIED: the unchanged approval-race test also fails at pre-fix main with two
dirty I/O schedulers: 1 test, 1 failure (2 excluded), seed 627496, exit 2.
SQLite lock waits occupy dirty I/O slots while the lock-owning connection times
out. The fixture's 15-second lock-wait bound matched its 15-second connection
timeout. It now uses production's 2-second lock wait. Four concurrent writers and
the exact one-decision/event/authority assertions remain unchanged; there are no
retries, sleeps or widened assertions. The same constrained command then passed:
1 test, 0 failures (2 excluded), seed 317257, exit 0:

```
perl -e 'alarm 120; exec @ARGV' env 'ERL_FLAGS=+SDio 2' mix test test/shoestring/cobbler/plan_approval_race_test.exs:199 < /dev/null
```

The existing approval-race fixture was additionally changed to resolve this
gate failure. Its production concurrency contract remains enforced.

VERIFIED: that gate passed before the additional durable-intent protection:
4 doctests, 1795 tests, 0 failures, 1 skipped (6 excluded), seed 762614,
164.1 seconds, exit 0; Node suites passed 52/52 and 8/8. This intermediate gate
does not verify the subsequently added intent protection.

VERIFIED: the final nine-test amendment file fails at the same pre-fix commit:
9 tests, 9 failures, seed 601056, exit 2. The new tests observe activation while
a plan-bound durable intent lacks executor bookkeeping and creation of a new
superseded intent; recovery of an existing identical intent remains asserted.
The first focused implementation check found a nil/boolean guard error:
62 tests, 22 failures, exit 2. After correcting that guard, the amendment,
executor, integration, Runs and Dispatches files passed together: 62 tests,
0 failures, seed 90935, exit 0:

```
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_amendment_test.exs test/shoestring/cobbler/plan_executor_test.exs test/shoestring/cobbler/plan_executor_integration_test.exs test/shoestring/harness/runs_test.exs test/shoestring/harness/dispatches_test.exs < /dev/null
```

VERIFIED: the publication gate with the first intent-protection implementation
returned exit 2: 4 doctests, 1797 tests, 5 failures, 1 skipped (6 excluded),
seed 593025, 166.3 seconds. Node suites passed 52/52 and 8/8. All five failures
were unplanned handoff crash fixtures whose injected repository deliberately
has no transaction function; its existing run-insert crash seam was obscured.
The added transaction now applies only to plan-bound intents, preserving the
original unplanned path. No fixture assertions or crash injection were changed.

VERIFIED: the handoff crash-window, amendment and Runs files then passed together:
30 tests, 0 failures, seed 797044, exit 0:

```
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/handoff_crash_window_test.exs test/shoestring/cobbler/plan_amendment_test.exs test/shoestring/harness/runs_test.exs < /dev/null
```

VERIFIED: final publication gate:

```
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null
```

Exit 0: 4 doctests, 1797 tests, 0 failures, 1 skipped (6 excluded), seed 272431,
167.3 seconds (11.9 seconds async, 155.4 seconds sync). Node suites passed
52/52 and 8/8. No functional changes followed this gate. The failure history above
records different implementation versions and their fixes, not retries of an
unchanged failing test until it passed.
