# Iteration 7: final scope acceptance

Implementation date: 2026-10-14. Baseline:
`a47dc3bb68edfb86946f59adadb4388136c97584`.

## Scope and behavior

REPO-INSPECTION: internal fan-out task completion now requires a consumed/closed
reservation supported by terminal, absent-Elf and absent owned-process-group
evidence before running gates. A terminal event or elapsed deadline alone does
not authorize acceptance or release uncertain ownership. Ordinary sequential
completion retains its existing behavior.

REPO-INSPECTION: after every trusted gate passes, bounded Git observations bind
the actual changed files to the tested full commit and approved base in
`scope_json`. Worktree cleanliness and HEAD are checked around observation;
different commits across task gates are refused. Deletions and both endpoints
of renames count as changes. Changed symlinks, unsupported repository entries,
oversized scope and source/manifest/ownership uncertainty fail closed.

REPO-INSPECTION: final scope is compared with sibling observations using the
existing normalized overlap/shared-surface policy and declared-scope containment.
Accepted sibling branches must still match their tested immutable commits; later
mutable branch state cannot silently replace their accepted output. Running
sibling observations are provisional, not claims that those siblings have a
final commit. Their own final acceptance must repeat these checks.

REPO-INSPECTION: `cobbler.plan.task.scope_blocked` version 1 records the bound
run/attempt/revision, tested commit, passed gate evidence and bounded decision
JSON. If final file evidence cannot be established, the event explicitly records
incomplete evidence and a reason and omits `scope_json`. It does not fabricate a
file set. Blocked verification duration counts once in lifetime budgets.
Successful acceptance events remain version 1 with optional final scope JSON,
preserving older sequential events.

REPO-INSPECTION: projection exposes `scope_blockers`, `needs_user?` and the
`scope_blocked` child resolution separately from gate failures. Replayed completion
does not rerun gates or remove the blocker. Subsequent coordinator admission is
fenced before the admission producer runs. Complete evidence permits unrelated
siblings to retain acceptance; incomplete evidence remains conservative. Earlier
accepted siblings, files and branches are retained. No child is interrupted,
replaced, merged or deleted by this boundary.

REPO-INSPECTION: completion resolution appends under an immediate transaction
with a fresh resolution check, so competing completion writers cannot persist
both acceptance and a conflict for one attempt. Event notification follows the
outer commit; nested transaction callers own notification and receive the event
identifier. Continuation lineage, amendment boundary checks and bounded planner
evidence references recognize scope-blocked attempts as resolved results, never
as accepted dependencies. A proposed amendment still needs approval.

The user authorized work directly on main without a PR, overriding the standing
worktree/PR workflow for this implementation. No provider calls were made for this package; verification uses local Git,
trusted gates and Fake lifecycle fixtures.

## Regression proof

VERIFIED: the three tests in `plan_final_scope_regression_test.exs` were copied
into an independent archive of the baseline commit, with separate build/state
and the baseline helper APIs. The command
`mix test test/shoestring/cobbler/plan_final_scope_regression_test.exs` exited 2:
**3 tests, 3 failures**, seed 135472, 8.1s sync, 12.244s wall. Every failure is the intended
behavioral mismatch: the baseline reports `accepted` after a real format gate
for an out-of-scope file, shared configuration edit or unexpected sibling overlap.
There were no missing-module/signature failures or checkout resets.

## Verification history

VERIFIED: initial focused run exited 2: **30 tests, 2 failures**, seed 704928,
66.9s sync, 68.683s wall. Both failures exposed a synthetic lifecycle fixture
that omitted `run.starting` before `run.running`; projection rebuild correctly
rejected it. The fixture now records the full transition sequence. Assertions
and gate/process bounds were not weakened.

VERIFIED: the second focused run exited 0: **52 tests, 0 failures**, seed 554750,
67.3s sync, 68.993s wall, including existing duration and handoff tests. Two
nonexistent optional test paths in the first command and one in the second were
ignored by Mix; these counts do not claim coverage for those paths. Subsequent
commands validate each named test file exists.

VERIFIED: the third focused run exited 2: **72 tests, 1 failure**, seed 746076,
82.9s (0.5s async, 82.3s sync), 84.832s wall. Its failed isolated wrapper
contained **3 child tests, 3 failures**, seed 0, 11.3s sync: a newly subscribed
test process stayed linked to PubSub during the deliberate service restart and
received shutdown; the stopped application then caused two setup failures. The
fixture now unsubscribes after checking the notification and before restart.
No application recovery behavior or assertion was relaxed.

VERIFIED: the corrected isolated command
`mix test test/shoestring/cobbler/plan_fanout_integration_test.exs` exited 0:
**1 wrapper test, 0 failures**, seed 440514, 19.3s sync, 20.390s wall. The wrapper
requires its child's actual output to report **3 tests, 0 failures**. It uses
normal pooled SQLite connections, production dispatch workers, real supervising
Elves and Fake streaming behind message barriers with trivial local commands.
There is no injected process-group probe in these lifecycle fixtures. The three
scenarios establish concurrent completion/dependency admission, conflict while a
sibling keeps running and later accepts, and competing dispatch/targeted unstarted
cancellation. Conflicting files, source/base cleanliness, exact run count,
reservation closure and accepted/blocking state are checked across service restart.
The notification assertion checks a persisted accepted event with final scope
binding through the default PubSub path.

VERIFIED: the first `mix precommit` exited 1 before tests, 0.953s wall: one
regression-fixture call layout needed a second formatter pass. The reported
layout was normalized before rerunning the full gate.

VERIFIED: the second `mix precommit` exited 2: **4 doctests, 2093 tests,
1 failure, 1 skipped, 6 excluded**, seed 683935, 292.0s (9.6s async, 282.3s sync),
295.521s wall. Both JavaScript suites passed **52/52** and **8/8**, with zero
failures or skips. The sole failure was a pre-existing exact event-count
assertion expecting seven executor event types. It now requires exactly eight
and explicitly requires the new scope-blocked type; the unplanned-goal behavior
assertion is unchanged. This gate preceded the final long-path test/guard.

REPO-INSPECTION: file-count bounds alone do not guarantee a recordable combined
scope decision. Final acceptance now checks the decision's JSON byte bound
before persistence. Overflow retains passed gates in an explicitly incomplete,
bounded scope-blocked event instead of failing the event append or truncating
file evidence.

VERIFIED: focused location checks for the long-path overflow and event contract
exited 0: **2 tests, 0 failures, 28 excluded**, seed 457245, 4.0s sync, 5.156s
wall. The long-path case uses 260 local committed files and asserts the exact
`scope_evidence_oversized` reason, retained successful gate evidence and omitted
unverified file evidence. An initial test-location selection script stopped
before invoking Mix because it matched the describe text rather than the test
name; it was corrected before this run.

VERIFIED: final `mix precommit` exited 0: **4 doctests, 2094 tests, 0 failures,
1 skipped, 6 excluded**, seed 470360, 291.6s (9.4s async, 282.1s sync),
295.090s wall. Format checking and compilation with warnings-as-errors passed.
JavaScript suites passed **52/52** and **8/8**, with zero failures or skips.
The full gate includes the isolated lifecycle wrapper and its three child
scenarios. No code changed after this gate; only this result was recorded.

VERIFIED: all **24** local documentation links checked resolve. Path, attribution
and literal credential-assignment scans passed all **21** changed/new artifacts;
the explicitly synthetic credential-marker filename is confined to its negative
validation test. `git diff --check` passed. Unrelated untracked hook/plugin
directories were left untouched and excluded from this checkpoint.

## Remaining work

UNVERIFIED: production fan-out is still disabled. Explicit human conflict
resolution, durable child inbox/wakeups, bounded replacement, live child/goal
cancellation recovery, generic goal-row synchronization, bounded public Claude
output retention and whole-lifecycle verification budgeting remain pending.
Scope metadata/Git-observation time is bounded per command but is not yet charged
as verification overhead; this remains an activation prerequisite. Provider
concurrency was not verified. Automatic branch merging remains out of scope.

REPO-INSPECTION: the final policy is conservative file-level evidence; it does
not prove semantic independence across otherwise disjoint files. Iteration 7
remains in progress.
