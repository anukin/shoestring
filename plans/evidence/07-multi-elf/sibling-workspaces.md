# Pinned sibling workspace boundary — 2026-10-13

## Scope

VERIFIED (user direction): continue iteration 7 on main without a PR or approval
stops between packages. Baseline: `5ad9cd4eae21b895b2eaf1e6e84d52ebde96a719`.
No provider calls were made.

REPO-INSPECTION: `PlanSiblingWorkspace.prepare/5` creates an inert independent
workspace from the exact accepted plan base. It validates current approval,
execution identity, required task, satisfied dependencies, attempt bounds and
deterministic run identity before allocation. The existing sequential executor
uses the same extracted run-ID helper; its UUID derivation is unchanged.

REPO-INSPECTION: each sibling uses per-run private Git storage rather than a
previous sibling's output commit. Metadata binds goal, execution, revision,
digest, task, attempt and accepted base. The canonical
`cobbler.plan.workspace.prepared` event records that lineage, branch and
relative workspace reference. Approval is rechecked before recording. Preparation
creates no run, lease, reservation, delivery job or provider effect.

## Preservation and replay

REPO-INSPECTION: new allocation requires clean source state at the full accepted
base. Existing manifests must match exact metadata, base, private Git location,
workspace location and recorded branch. Foreign or mismatched records are
refused. An unowned allocation must remain clean at that base to replay; dirty
or independently committed work is refused and retained for inspection.

REPO-INSPECTION: an existing persisted run with matching goal, plan binding and
workspace reference may replay its own allocation while dirty, preserving useful
work. No reset, cleanup, expiry, branch deletion or replacement was introduced.
An authority/event failure after filesystem allocation leaves the allocation
available; filesystem state is not claimed atomic with SQLite. Parallel dispatch
must connect this boundary to reservation/intent ownership in the next package.

## Verification

VERIFIED: focused tests use temporary local Git repositories and synthetic
plans. They commit output in one private sibling, then allocate another from
the original accepted base. The second contains none of the first's output;
both stores/paths are distinct, both have no remotes, and the source HEAD,
working tree, branches and `.git/worktrees` metadata remain untouched.

VERIFIED: checks cover clean manifest/event replay, dirty and committed unowned
allocation refusal with files/commit/manifest preserved, changed source,
stale digest, foreign execution, skipped attempt, foreign manifest refusal,
and same-run dirty-work preservation. Existing sequential executor tests verify
its identities and behavior alongside the new boundary. Fixtures are retained;
no provider, network, sleep, assertion retry or cleanup was added.

```text
mix test test/shoestring/cobbler/plan_sibling_workspace_test.exs test/shoestring/cobbler/plan_executor_test.exs
```

| Run | Exit | Actual result | Seed | Duration |
| --- | --- | --- | --- | --- |
| 1 | 0 | 25 tests, 0 failures | 610647 | 4.9s sync |
| 2 | 0 | 27 tests, 0 failures | 200683 | 5.6s sync |

REPO-INSPECTION: run 2 adds execution/attempt fences and same-run dirty replay.
Two patch attempts initially had a mistyped file path or stale formatted
context and were rejected before applying; corrected patches were then applied.
Those were editing-tool failures, not test passes or test results.

VERIFIED: `mix precommit` exited **0**: **4 doctests, 2027 tests, 0 failures,
1 skipped (6 excluded)**, seed **921734**, **202.8 seconds** (9.5 async,
193.2 sync), wall **206.304 seconds**. JavaScript passed **52/52** and **8/8**
with zero failures or skips. The command ran in the foreground with stdin
closed and a 480-second bound; focused runs had a 180-second bound.

REPO-INSPECTION: these are new-capability checks, not baseline regression locks;
the baseline has no sibling plan-binding boundary. Existing private Git storage
and sequential execution remain covered by the full gate.

## Remaining integration

REPO-INSPECTION: coordinator dispatch wiring, per-run parallel authority,
actual-scope acceptance checks, durable child inbox/wakeups and partial-failure
handling remain. This is an internal boundary, not a new CLI allocation command
or an enabled fan-out path. It does not merge sibling commits or invent an
integrated base for dependent tasks.

UNVERIFIED: live providers, concurrent sibling execution, parallel scheduling,
distributed filesystem coordination and automatic integration were not verified
in this package.
