# Deterministic scope evidence — 2026-10-13

## Scope

VERIFIED (user direction): continue iteration 7 on main without a PR or approval
stops between packages. Baseline: `ed3c50d1fe56a27ed9ee8f0ee71fe397d6a0cd33`.
No provider calls were made.

REPO-INSPECTION: `PlanIndependence` version 1 classifies declared file/symbol
scopes and actual changed-file sets. Unknown metadata/scopes, invalid paths,
symlink scopes, shared surfaces and overlapping files/directories default to
sequential execution. Shared declared symbols block otherwise disjoint file
hints. Path comparisons conservatively fold case and Unicode normalization;
component boundaries distinguish `lib/a` from `lib/ab.ex`.

REPO-INSPECTION: shared surfaces include dependency manifests/lockfiles,
configuration, migrations, generated directories, CI workflows, application
startup, routers and event registries. Tracked repository metadata also catches
broad scopes containing a shared file. A declared path remains a hint, never
an allocation or integration authorization. Actual changed-file overlap can
override an earlier eligible declaration. Empty actual changes are permitted;
missing actual repository evidence remains blocked. Results are bounded and
explicitly report incomplete blocker detail instead of declaring a truncated
analysis safe.

## Git evidence and CLI

REPO-INSPECTION: `ScopeEvidence` uses bounded local Git commands with NUL-delimited
paths. Repository evidence requires clean source state and HEAD equal to the
full accepted commit; moved/dirty state is refused. Unsupported tree entries
(including submodules), invalid paths, oversized output or command failure
fail closed. Tracked symlink modes are explicit. Actual change collection
includes committed/uncommitted changes against the base, deletions and
untracked non-ignored files; rename detection is disabled so both sides remain
visible. New filesystem symlinks are refused. No repository is modified.

REPO-INSPECTION: metadata calls have a **5-second / 1-MiB** bound each, with at
most **20,000** tracked entries. A policy call bounds **64** tasks, **4,096**
total paths and **1,024** actual paths per task. Up to **128** blocker details
are recorded, with the full blocker count and `evidence_complete` flag.

```sh
mix shoestring.execution check-scopes "$GOAL"
```

REPO-INSPECTION: this command records canonical
`cobbler.plan.independence.evaluated` evidence for approved, dependency-ready,
unstarted tasks. The event binds execution/revision/digest, accepted base,
repository observation and policy result. Identical evidence replays a stable
event. Plan authority and execution state are rechecked under the write
transaction after Git observation. Active or user-blocked execution stays
sequential. The command allocates no work, starts no provider and explicitly
reports `parallel_dispatch_enabled: false`.

REPO-INSPECTION: evidence is an observation, not a durable future permission.
The fan-out coordinator must recheck current execution, accepted base,
independence and reservation ownership before dispatch. Filesystem observation
cannot lock out subsequent human edits. Actual-scope policy and capture are
implemented as boundaries; acceptance/integration wiring for parallel children
is pending, so no production parallel acceptance guarantee is claimed here.

## Verification and corrections

VERIFIED: all tests use synthetic plans and temporary local Git repositories.
Fixtures are retained. No provider CLI/network, assertion retry, sleep or
cleanup behavior was added.

The first two focused runs used:

```text
mix test test/shoestring/cobbler/plan_independence_test.exs test/shoestring/cobbler/plan_scope_check_test.exs
```

Runs 3–4 also included `test/mix/tasks/shoestring_execution_test.exs`.

| Run | Exit | Actual result | Seed | Duration | Finding/change before next run |
| --- | --- | --- | --- | --- | --- |
| 1 | 1 | Test compilation failed; no test result | 180186 | Not reported | Corrected misplaced test `case` syntax; also corrected optional active-run boolean handling before execution |
| 2 | 0 | 12 tests, 0 failures | 867765 | 1.3s (0.1 async, 1.2 sync) | Scope policy and Git/recording checks passed |
| 3 | 2 | 23 tests, 1 failure | 244978 | 2.3s (0.1 async, 2.2 sync) | Amendment fixture incorrectly dropped approved task IDs; changed it to preserve identities |
| 4 | 0 | 23 tests, 0 failures | 151935 | 2.4s (0.1 async, 2.2 sync) | Shared symbols, tracked links, CLI, stale authority and legacy CLI checks passed |

VERIFIED: checks cover disjoint/overlapping/directory/case scopes, high-risk
surfaces, unknown/invalid/bounded inputs, shared symbols, actual overlap despite
eligible declarations, exact-base and dirty-source refusals, tracked/new
symlinks, NUL framing with a renamed path containing a space, replayable
canonical evidence, no new run/job allocation, and changed approval refusal.
The active-execution CLI check preserves the one existing run/job.

VERIFIED: `mix precommit` exited **0**: **4 doctests, 2020 tests, 0 failures,
1 skipped (6 excluded)**, seed **110343**, **200.6 seconds** (9.8 async,
190.7 sync), wall **207.245 seconds**. JavaScript passed **52/52** and **8/8**
with zero failures or skips. The foreground command had closed stdin and a
480-second bound; focused runs had a 180-second bound.

VERIFIED: **23 relative Markdown links** resolve across iteration-7 evidence,
milestone and CLI documentation. All **6 new artifacts** passed home-path and
authorship scans. The final staged diff passes `git diff --cached --check`.

REPO-INSPECTION: these are new-capability checks, not baseline regression locks;
the baseline has no scope policy, Git capture boundary or canonical CLI scope
check. The red runs were followed by corrections, not unchanged reruns until
green.

## Remaining integration

REPO-INSPECTION: independent sibling workspace binding, concurrent dispatch
ownership, actual-diff acceptance checks, durable child inbox/wakeups and
partial-failure recovery remain. The current sequential executor is unchanged.
Unknown ownership remains held, and automatic merge remains out of scope.

UNVERIFIED: no live provider, production fan-out, automatic integration,
arbitrary static dependency proof or distributed coordination was verified.
