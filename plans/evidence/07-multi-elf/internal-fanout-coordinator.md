# Internal fan-out coordinator — 2026-10-14

## Scope

VERIFIED (user direction): continue iteration 7 directly on main, without a PR
or approval stops. This overrides the standing worktree/PR workflow. Baseline:
`28892a0956c6a76f1cd0da47dda88935674f708c`. No live provider calls were made.

REPO-INSPECTION: `PlanFanout.dispatch_ready/2` coordinates initial attempts,
requiring trusted `fanout_enabled: true`, an explicit reservation policy and
per-task admission callback. Plans cannot activate it. Production workers and
CLI do not select it yet. It neither retries failed tasks, merges branches nor
completes the parent goal. Queue policy version 1 visits ready tasks in declared
topological order and skips blocked admission/capacity candidates.

## Ownership, workspaces and inputs

REPO-INSPECTION: each child commits reservation, command, run, lease, delivery
and task lineage in one immediate transaction. Earlier sibling transactions
survive a later failure. Approval, execution, required-task/dependency/attempt
authority, admission, scope, manifest and budget are rechecked at dispatch.
Allocation follows capacity/budget checks inside the serialized intent boundary,
preventing competing coordinators from racing to allocate the same sibling.

REPO-INSPECTION: private Git stores start at the exact approved full base.
Manifest bindings include goal, execution, revision, digest, task, attempt, base,
branch and private paths. Existing root/continuation ownership is checked before
more dispatch. Unknown owners stay held. Database rollback cannot roll back Git
allocation: surviving files/manifests are retained for safe replay or inspection.
No cleanup, reset, branch deletion or timer was added.

REPO-INSPECTION: declared scopes must be known and disjoint. Bounded actual-file
observations refuse overlaps, shared/symlink surfaces and edits outside hints
before additional dispatch. These are live observations, not proof that a
running child will remain in scope. Final actual-diff acceptance remains pending.
Dependent inputs must be ancestors of the reviewed base. Divergent output blocks
dependent dispatch and is retained. Ordinary sequential amendments also require
their selected base to contain every accepted commit before allocating a
successor; selecting the last sibling branch cannot discard the other output.
Ordinary execution refuses inert/dirty sibling storage rather than adopting it.

## Duration, projection and scope transport

REPO-INSPECTION: duration admission reserves remaining configured task allowance
for each held owner plus configured command timeouts for all global acceptance
gates. Fresh lease bounds must fit the task contract. An unresolved owner past
its task duration blocks new allowance rather than becoming zero future work.
No deadline interrupts useful work. These are conservative configured bounds,
not provider usage forecasts. Whole-lifecycle verification budgeting, including
metadata-check overhead, remains an activation check.

REPO-INSPECTION: status retains all children, active children, continuation chains,
per-child resolutions/retry states and accepted evidence. Compatibility fields
identify the first active child. An exhausted child remains visibly blocked for
an operator while another runs. Restart processing handles every resolvable
terminal and preserves a successful sibling even if another workspace is
unavailable. Canonical fan-out mode fences ordinary advancement/recovery from
silently continuing on one branch; generic options cannot select sibling mode.

REPO-INSPECTION: scope-event version 2 stores canonical `decision_json`, bounded
to 65,536 bytes and validated against known decision/blocker/path fields and safe
leaf content. Version 1 remains readable. CLI responses keep decoded evidence.
This fixes nested/list safety-bound failures without weakening trajectory guards.
A 1,024-blocker fixture retains the count, 128 blockers and explicit
`evidence_complete: false`; oversized evidence is refused, not silently cut.

## Baseline regression proof

VERIFIED: existing-API tests were copied with their synthetic helper into a
retained archive of the baseline. No source reset/stash or provider/network call
was used. Failures were behavioral, not missing modules or changed signatures.

```text
mix test test/shoestring/cobbler/plan_scope_recording_regression_test.exs test/shoestring/cobbler/plan_children_projection_regression_test.exs
mix test test/shoestring/cobbler/plan_sibling_adoption_regression_test.exs
```

| Baseline run | Exit | Actual result | Seed | Duration |
| --- | --- | --- | --- | --- |
| Scope/child projection | 2 | 4 tests, 4 failures | 49046 | 0.9s sync |
| Dirty sibling adoption | 2 | 1 test, 1 failure | 297591 | 0.8s sync |

VERIFIED: old behavior rejected nested/large overlap evidence, omitted the second
child from status, failed to accept a later terminal while the first remained
unresolved, and dispatched into dirty unowned sibling storage. Other new checks
are capability tests, not claimed pre-fix regression locks.

## Focused verification

VERIFIED: runs progressively selected coordinator, scope/child/adoption
regressions, scope transport, existing scope/executor/amendment/sibling workspace
and reservation dispatch tests. Runs 6–7 selected the coordinator and existing
executor after the final per-child status and duration additions.

| Run | Exit | Actual result | Seed | Duration |
| --- | --- | --- | --- | --- |
| 1 | 2 | 53 tests, 1 failure | 504317 | 23.5s sync |
| 2 | 0 | 64 tests, 0 failures | 792960 | 20.1s sync |
| 3 | 0 | 78 tests, 0 failures | 1814 | 23.0s: 0.4 async, 22.6 sync |
| 4 | 0 | 87 tests, 0 failures | 700567 | 29.1s: 0.4 async, 28.7 sync |
| 5 | 2 | 88 tests, 1 failure | 262937 | 31.1s: 0.4 async, 30.6 sync |
| 6 | 0 | 37 tests, 0 failures | 113487 | 24.6s sync |
| 7 | 0 | 39 tests, 0 failures | 548758 | 26.5s sync |

VERIFIED: run 1 exposed the nested scope-event defect. Run 5 used a synthetic
`run.failed` fixture missing required category/code fields; it now uses a
format-valid transport failure. Assertions, timeouts and retry policy were
unchanged. These were concrete defects, not assertions rerun until green.

## Concurrent lifecycle proof

VERIFIED: the isolated test node uses normal pooled SQLite, production dispatch
workers, supervising Elves, Fake streaming behind a message barrier and trivial
local `sleep` commands owned by the existing process-group runner. Intent survives
service restart before effects. Both children are observed running concurrently
in separate private stores. One completes, is gated/accepted and settles while
the other remains active. The dependent is admitted only after both acceptances
and input-base checks. No assertion uses sleep-based synchronization or retries.

VERIFIED: four competing coordinators produce exactly two child intents. Explicit
never-started cancellation of one leaves the other requested/reserved, preserving
both manifests. Final canonical child state survives another restart. Global
completion deliberately stays false behind the activation fence. Fake output
commits equal the base; nonempty divergent output is separately tested as blocked,
not automatically integrated. Live provider concurrency was not verified.

| Lifecycle run | Exit | Actual result | Seed | Duration |
| --- | --- | --- | --- | --- |
| Wrapper 1 | 2 | 1 test, 1 failure; child 2 tests, 2 failures | 387913; child 0 | 3.8s; child 2.6s |
| Wrapper 2 | 2 | 1 test, 1 failure; child 2 tests, 1 failure | 591314; child 0 | 9.8s; child 8.6s |
| Wrapper 3 | 0 | 1 test, 0 failures | 127551 | 13.8s sync |
| Direct child 4 | 0 | 2 tests, 0 failures | 0 | 8.0s sync |

VERIFIED: the first two lifecycle runs assumed projected run rows were already
current immediately after committed running/cancellation events. The fixture now
explicitly projects those events before read-model assertions. The first run's
later capacity failure followed its aborted fixture retaining the first owners.
Concurrency, exact counts, cancellation and process-monitor assertions remained.

## Full gate and remaining work

VERIFIED: first `mix precommit` exited 1 before tests: one call layout still
required a second formatter pass (0.945s wall). That layout is now normalized.
VERIFIED: final `mix precommit` exited 0: **4 doctests, 2081 tests, 0 failures,
1 skipped, 6 excluded**, seed 365390, 236.7s (9.3s async, 227.4s sync),
240.212s wall. JavaScript suites passed **52/52** and **8/8**, with zero failures
or skips. Format checking and compilation with warnings-as-errors passed.
The gate includes the isolated lifecycle wrapper and its two child scenarios.

VERIFIED: all 22 local documentation links checked were valid. Sensitive
path/credential/attribution scans passed all 10 new artifacts, and
`git diff --check` passed. Unrelated untracked hook/plugin directories were
left untouched and excluded from this checkpoint.

UNVERIFIED: production activation remains disabled. Next work includes final
actual-diff acceptance/conflicts, durable child inbox/wakeups, bounded replacement
and live child/goal cancellation recovery, generic goal-row synchronization,
bounded public Claude output retention and whole-lifecycle verification budgeting.
Iteration 7 remains in progress. Automatic branch merging remains out of scope.
