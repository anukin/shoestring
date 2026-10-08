# The Cobbler plan contract

**Status:** package A and the durable revision/approval foundation are merged.
Package B adds the separate [planner boundary](planner-boundary.md), which can
produce a candidate but cannot author or approve a revision. REPO-INSPECTION:
package C exposes human review/edit/approve/reject through the
[CLI plan review interface](cli-plan-review.md). Package D now has an integrated domain executor and a hermetic worker/worktree/gate
restart proof. CLI execution, saved-agent binding, quota continuation and package E
remain pending; see the current integration evidence.

A plan is a goal acceptance contract plus a validated task DAG. It is a
*proposal* until a human approves one exact revision at one exact content
digest. Proposing, editing, approving and rejecting remain inert. Execution
requires an explicit request followed by the sequential executor entrypoints.

## Modules

| Module | Role |
| --- | --- |
| `Shoestring.Cobbler.PlanGate` | the closed registry of named trusted acceptance gates |
| `Shoestring.Cobbler.PlanGraph` | dependency validation and deterministic ordering |
| `Shoestring.Cobbler.PlanContract` | the strict versioned plan value, canonical rendering, digest |
| `Shoestring.Cobbler.Plans` | durable revisions, decisions, authority, rebuild |
| `Shoestring.Cobbler.PlanGateRunner` | bounded supervised gate execution with bound evidence |
| `Shoestring.Cobbler.PlanExecutor` | durable sequential approved-plan dispatch and acceptance |
| `Shoestring.Cobbler` | the facade: `build_plan/1`, `propose_plan/3`, `approve_plan/3`, `reject_plan/3`, `plan_authority/2`, `rebuild_plans/2`, `request_plan_execution/3`, `advance_plan_execution/2`, `complete_plan_task_run/3`, `resume_plan_execution/2`, `plan_execution_status/2`, `run_plan_gate/3` |

Every one of these is reachable without a LiveView. REPO-INSPECTION:
`mix shoestring.plans` exposes this domain through the CLI, following the
accepted product direction that the web UI contains configuration and usage.

## Plan shape (version 1)

```
version                                1
goal.statement                         bounded text, <= 2000
goal.repository.base_revision          resolved hex git revision, 7..40 chars
goal.repository.remote_ref             optional simple ref name
goal.constraints                       <= 16 bounded texts
goal.non_goals                         <= 16 bounded texts
goal.acceptance.gates                  1..4 trusted gate references
goal.acceptance.evidence               1..8 bounded texts
budget.max_total_attempts              1..200
budget.max_total_duration_seconds      1..86400
tasks                                  1..32 task contracts
planner.identity / .version            optional provenance
planner.source_context_refs            <= 16 bounded references
```

Each task:

```
id                                     stable slug, [a-z0-9][a-z0-9_-]{0,62}
title                                  bounded text, <= 200
outcome                                bounded, non-empty text, <= 1000
depends_on                             <= 16 stable task ids
inputs                                 <= 16 bounded texts
expected_artifacts                     <= 16 bounded texts
hints.files                            <= 32 repository-relative paths
hints.symbols                          <= 32 bounded texts
acceptance_criteria                    1..8 bounded texts
gates                                  1..4 trusted gate references
checkpoint.condition                   bounded text, <= 500
checkpoint.evidence                    1..8 bounded texts
risks                                  <= 8 bounded texts
execution.max_attempts                 1..20
execution.max_duration_seconds         1..14400
```

The whole canonical document is capped at 65 536 bytes.
`budget.max_total_attempts` must cover the sum of the tasks' attempts and
`budget.max_total_duration_seconds` the sum of their durations, because
initial execution is sequential.

## What fails closed

Everything. There is no partial plan that can be stored or approved.

- an unknown field, at the top level or inside any object
- a plan version this contract does not implement
- an empty or oversized text field — rejected, never truncated
- a document or an input term over its size bound
- a task with no execution bounds, or bounds outside their range
- a task id that is not a stable slug
- a dependency on an id no task declares
- a self-dependency, a duplicate id, a repeated edge, a cycle
- a budget smaller than what its tasks reserve
- an acceptance gate not in the trusted registry, or a gate parameter the
  named gate does not accept
- a task or goal acceptance contract citing no gate at all
- a moving ref (`main`, `HEAD`, `origin/main`) where a resolved base
  revision belongs
- a file hint or test path that escapes the repository

## No embedded commands

A plan never carries a shell string. A key named `command`, `commands`,
`cmd`, `argv`, `shell`, `script`, `exec`, `entrypoint`, `run_command`,
`bash`, `sh`, `eval`, `system`, or `spawn` — at any depth, under any parent
— rejects the plan and reports its path.

Acceptance is expressed only as references into `PlanGate`:

| Gate | Resolves to | Parameters |
| --- | --- | --- |
| `mix_precommit` | `mix precommit` | none |
| `mix_test` | `mix test` | `test_paths`: <= 16 repository-relative `test/**_test.exs` paths |
| `mix_format_check` | `mix format --check-formatted` | none |
| `mix_compile_strict` | `mix compile --warnings-as-errors` | none |

The registry — not the plan, and never a model — owns the argv a name
resolves to. **Model self-report is never acceptance**, which is why every
task must cite at least one trusted gate.

## Deterministic ordering

`PlanGraph.validate/1` runs Kahn's algorithm with the ready set broken by
*declared* index, so the order is a pure function of the plan content and is
identical on every machine and every replay. A cycle returns a witness —
the actual list of ids on the cycle — not just "a cycle exists".

## Deterministic digest

`PlanContract.canonical_json/1` renders normalized content with every object
key sorted, and `digest/1` is the SHA-256 of that rendering. Two
structurally identical plans produce byte-identical JSON regardless of map
iteration order. Normalization also makes optional list fields always
present and empty, so "no constraints" has exactly one representation.

## Revisions, decisions, authority

- **Creation and editing both produce a new revision.** `propose/3` is the
  only way content enters. Revision 1 stands alone; every later revision
  must name the `parent_revision_number` it was edited from, and that parent
  must belong to the same goal.
- **Revisions are immutable.** Content, digest, and lineage are written once.
  Only `status` moves: `proposed -> approved | rejected`, and
  `approved -> superseded`.
- **Approval binds a revision AND a digest.** An approval that carries a
  digest the named revision does not have is stale and is refused, so an
  operator cannot authorize content they never read.
- **Only humans decide.** `authored_by` and `decided_by` must be
  `human:`-prefixed. A planner may be recorded inside the plan as
  provenance; it cannot author a revision and cannot approve one.
- **Rejection carries a bounded reason** (<= 500 characters), required.
- **One authority per goal**, enforced by a partial unique index over
  `goal_id` where `status = 'approved'`. **One decision per revision**,
  enforced by a unique index on `plan_revision_id`. Concurrency loses on an
  index, not on a read-then-write race.
- **Idempotency.** A proposal carries a goal-scoped `proposal_id` and a
  decision a goal-scoped `decision_id`. Re-sending the same id with the same
  content replays the original row and appends no events; the same id with
  different content is a conflict.
- **Supersession is inert.** Approving a newer revision moves the older
  approved revision to `superseded`. That removes its future authority and
  does nothing else: it enqueues nothing, cancels nothing, interrupts
  nothing.
- **Approved task identities persist.** A revision edited within a goal whose
  plan was ever approved must still contain every task id that approved
  lineage introduced.

## Idempotency rests on the index, not on the transaction mode

Both `propose/3` and `approve/3`/`reject/3` read to detect a replay and then
write. `mode: :immediate` closes that window by taking SQLite's write lock
at BEGIN — but only when it is in effect. Inside an enclosing transaction
(the ExUnit SQL sandbox, or any caller that wraps this store in its own
transaction) Exqlite issues a SAVEPOINT and takes no write lock, so the
window is open.

The unique indexes are always in effect, so they are what idempotency rests
on. A writer that loses `(goal_id, decision_id)` or `(goal_id, proposal_id)`
**converges on the winner's row** and reports `:replayed`, because a request
that lost a race has not been refused — it has already succeeded. Digest
and decision agreement remain the guard: different content under the same
id, or a different decision kind, is still a conflict. A *different*
decision id for an already decided revision is still refused, because that
revision is spoken for.

## Storage failures are structured, never exceptions

Two deliberately distinct classes, and the list is closed:

| Outcome | Meaning | What the caller should do |
| --- | --- | --- |
| `{:error, {:database_busy, message}}` | the write lock was refused or the connection was unavailable; nothing was written | retry the same id; it converges |
| `{:error, {:database_conflict, detail}}` | the write met storage constraints this code did not anticipate; the transaction rolled back whole | **re-read** first — durable state may have moved |

A programming error (`ArgumentError`, `FunctionClauseError`, a bad query)
still crashes loudly rather than being dressed up as a transient storage
problem.

## Events are the authority

| Event | Carries |
| --- | --- |
| `cobbler.plan.revision.created` v1 | revision id, proposal id, numbers, version, digest, the canonical plan rendering, author, task count, deterministic order |
| `cobbler.plan.approved` v1 | revision id and number, decision id, bound digest, decider, time, optional superseded revision and note |
| `cobbler.plan.rejected` v1 | revision id and number, decision id, bound digest, decider, time, reason |

The revision event carries the plan as its **canonical JSON rendering**
rather than as a nested object, so what replay reads back is byte-identical
to what the digest was taken over. `EventRegistry` re-validates that
rendering through the full plan contract on every write and every replay,
and refuses an event whose declared digest, version, order, task count, or
author kind disagrees with its own content. A plan that could not be
proposed today cannot be resurrected from history either.

`Plans.rebuild/2` recomputes revisions, decisions, and the active authority
purely from these events and reports divergence from stored rows without
mutating anything. The digest it reports is **recomputed from the rebuilt
content**, not copied from the event.

## Sequential execution (work package D)

An approved plan stays inert until an explicit `request_plan_execution/3`.
From there `PlanExecutor` dispatches one plan task at a time through the
existing admission, command/claim, lease, and durable-dispatch machinery
(`Dispatcher.claim_and_gate/3` with `grant_lease:` — run row and lease
grant persisted before durable delivery, never a direct spawn), and
records deterministic gate evidence through `PlanGateRunner`.

- **Dispatch binds the authority at dispatch time.** Every dispatch
  re-reads the live approved revision and its digest; a proposed,
  rejected, invalid, or superseded revision cannot dispatch, and a moved
  digest is stale and refused. Holding a revision struct from earlier is
  never enough, because supersession is deliberately silent.
- **One active plan task per goal**, even for dependency-independent
  nodes. The next task is the first unaccepted dependency-ready task in
  deterministic `PlanGraph` order — a pure function of the plan content.
- **No premature goal completion.** A single run completing never
  completes a multi-task planned goal. The goal completes only after
  every required task is accepted AND the global acceptance gates pass
  at the integrated repository revision (the presentation holds an
  intermediate run terminal at `:working` while the plan is incomplete).
  Unplanned goals are untouched.
- **Gates, not self-report.** Every cited task gate executes through a
  bounded, supervised runner whose argv comes from `PlanGate` — never a
  plan shell string. Evidence binds goal, task, revision, digest, run,
  attempt, actual tested commit, and worktree; stale, missing, or forged
  evidence is refused, and a successful run alone never unlocks a
  dependent. Oversized output fails the attempt; it is never truncated.
  Gate failure leaves dependents blocked with a bounded
  `retry` / `escalate` / `needs_user` state.
- **Restart.** VERIFIED in the hermetic integration test: accepted task evidence,
  run/worktree identity and counters survive application restart, without another
  planning call. One admission decision funds one task dispatch. UNVERIFIED:
  plan-level quota wake/handoff continuation is not closed by this proof.
- **Unsuccessful runs.** A failed run records a bounded failed attempt without
  running acceptance gates. Interrupted/cancelled runs remain unresolved and cannot
  unlock dependents or be replaced by `resume`. Quota continuation requires the
  existing checkpoint/wake lifecycle; its plan-level integration remains pending.
- **Workspace.** Runtime execution requires `repository_path:` for allocation;
  per-task worktrees start at the latest accepted commit (initially the approved
  repository base). Gates derive their directory from the run's durable worktree.
  Global gates require all accepted commits to be ancestors of the final worktree
  HEAD. Gate injection bypasses filesystem integration only in hermetic unit tests.
- **Gate process bounds.** Timeout/overflow terminate the owned process group.
  Real gates require a clean worktree and unchanged HEAD before/after execution.
  A production caller cannot replace the tested commit with `commit:`.
- **Safe supersession.** A newer approval stops further dispatch from
  the old revision. In-flight work still records its attempt result at
  the safe boundary but grants no authority to changed work.
- **Authority hardening.** `Plans.authority/2` re-verifies the stored
  digest against the recomputed contract digest on every read; plan
  decision events require `human:` deciders consistently with the Plans
  API; replay verifies each decision digest against the reconstructed
  immutable revision and fails the rebuild on inconsistency instead of
  returning forged authority.

New trajectory events (all v1, all validated at the registry boundary):
`cobbler.plan.execution.requested`, `cobbler.plan.task.dispatched`,
`cobbler.plan.task.accepted`, `cobbler.plan.task.gate_failed`,
`cobbler.plan.execution.completed`.

## Deliberately absent, and what later packages owe

Packages B and C supply planning and CLI approval. Amendment orchestration,
CLI execution, saved-agent execution binding and plan-level quota continuation
remain pending. One obligation follows:

- **Amendment needs an explicit retirement path.** Because this slice
  refuses to drop a task id from approved lineage, a genuine scope
  reduction has no representation yet. The amendment package must add an
  approval-gated retirement that records *why* an approved task identity is
  retired, rather than relaxing the retention rule.
