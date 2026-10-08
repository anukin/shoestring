# Iteration 6 — durable sequential approved-plan execution (package D)

REPO-INSPECTION: this is the historical PR #90 author report. The subsequent
review found blockers in its acceptance/process/worktree claims. Current fixes,
proof and remaining limits are recorded in [executor-integration.md](executor-integration.md).

Branch: `polly/iter6-sequential-executor-opencode`
Base: `df624790538b9bde687262a2ef86d24ae140b4bd` (prior same-command gate:
4 doctests, 1660 tests, 0 failures, 1 skipped, 6 excluded; Node 52/52 + 7/7)

Identifier and redaction conventions for this directory are recorded in its
`README.md`. Every plan fixture is synthetic: the base revision
`0a1b2c3d4e5f60718293a4b5c6d7e8f901234567` is a fabricated hexadecimal
string and not a commit in this repository, identities are `human:`
placeholders, UUIDs are generated per test run, and no credential,
provider-generated identifier, machine identifier, absolute home path, or
hidden model reasoning appears in fixtures or in this document. Gate
evidence in tests uses an injected runner (never an OS process) and the
synthetic commit above.

The milestone file `plans/milestones/06-cobbler-planning.md` is absent in
this worktree; per the brief delta, the brief (`.polly/executor-brief.md`),
`docs/plan-contract.md`, and this directory are the authoritative
contract. No Codex report was recovered or relaunched (REPO-INSPECTION
only of the quoted tail in the brief); all APIs below were validated
against the worktree's own code in this session. No nested agent calls
were used.

## Scope delivered

Work package D plus the brief's narrowly required authority hardening,
through callable domain APIs plus the normal durable workers. No LiveView
dependency: every executor entrypoint is reachable via `Shoestring.Cobbler`.

| Module | Role |
| --- | --- |
| `Shoestring.Cobbler.PlanExecutor` | explicit execution request, atomic revision/digest-bound sequential dispatch, event-derived task/attempt/acceptance projection, quota/restart continuation, safe supersession |
| `Shoestring.Cobbler.PlanGateRunner` | bounded supervised gate execution with bound evidence and forgery refusal |
| `Shoestring.Cobbler` | facade additions: `request_plan_execution/3`, `advance_plan_execution/2`, `complete_plan_task_run/3`, `resume_plan_execution/2`, `plan_execution_status/2`, `run_plan_gate/3` |

Hardening (same slice): `Plans.authority/2` re-verifies the stored
digest against the recomputed contract digest on every read;
`EventRegistry` requires `human:` proposal authors and deciders
consistently with the Plans API; `Plans.rebuild/2` verifies each decision
digest against the reconstructed immutable revision and fails the rebuild
on inconsistency instead of returning forged authority.

Narrow presentation override (explicitly authorized in the brief solely
to avoid premature multi-task goal completion):
`ShoestringWeb.CobblerPresentation.derive_goal_state_for_plan/2` plus a
`plan_status/1` reader in `CobblerDashboardLive` and `CobblerGoalLive`.
An executing-but-incomplete plan holds an intermediate run terminal at
`:working`; every other status folds exactly as before, so unplanned-goal
behavior is preserved. No approval UI, template redesign, or other
frontend work.

New trajectory events (all v1, registry-validated):
`cobbler.plan.execution.requested`, `cobbler.plan.task.dispatched`,
`cobbler.plan.task.accepted`, `cobbler.plan.task.gate_failed`,
`cobbler.plan.execution.completed`.

Narrative contract updated: `docs/plan-contract.md` (status, module
table, new "Sequential execution" section, retired dispatch-binding
obligation, remaining amendment obligation).

## Gate

VERIFIED — final, run in `$WORKTREE`:

```
$ mix precommit < /dev/null
```

exit 0; ExUnit `4 doctests, 1699 tests, 0 failures, 1 skipped
(6 excluded)`; `gate_0a.node_test` `tests 52 / pass 52 / fail 0`;
`ui.node_test` `tests 7 / pass 7 / fail 0`.

1699 − 1660 = **39 new tests**, exactly the sum of the new files below.
No existing test was modified, deleted, or skipped.

| Test file | Tests |
| --- | --- |
| `test/shoestring/cobbler/plan_executor_test.exs` | 20 |
| `test/shoestring/cobbler/plan_authority_hardening_test.exs` | 6 |
| `test/shoestring/cobbler/plan_gate_runner_test.exs` | 8 |
| `test/shoestring_web/live/cobbler_presentation_plan_test.exs` | 5 |

Two compiler warnings in the gate output
(`dispatch_jobs_before` in `wake_reobserve_test.exs`,
unused `Oban.Job` alias in `wakeup_continuation_test.exs`) are
pre-existing and untouched by this change.

## Acceptance mapping

### 1. Atomic revision/digest-bound dispatch; inert planning

| Requirement | Where it is enforced | Where it is proved |
| --- | --- | --- |
| planning inert until explicit request | `request_execution/3` is the only entry; `advance/2` without it returns `:no_execution_requested` | executor test "planning stays inert until an explicit execution request" |
| proposed/rejected plans cannot dispatch | hardened `Plans.authority/2` returns nil; request refuses `:no_approved_authority` | "a proposed (unapproved) plan cannot dispatch", "a rejected plan cannot dispatch" |
| stale digest refused | `bind_authority/3` compares revision AND digest at the atomic boundary | "a stale digest is refused" |
| cross-goal rejection | authority and admission lookups are goal-scoped | "a cross-goal revision cannot authorize", "an admission from another goal is refused" |
| duplicate/concurrent kickoff cannot dispatch twice | deterministic command/run/dispatch ids converge in the stores; idempotent executor events; refused reuse before side effects | "duplicate execution requests replay", "concurrent kickoff cannot dispatch twice" (parallel `Task.async` kickoffs, exactly one run) |
| one active plan task per goal | `active_dispatch/2` awaits while any dispatch is unresolved | chain and independent-node tests assert `:awaiting_task` with one run |
| deterministic order | first unaccepted dependency-ready task in `ordered_task_ids` | chain executes alpha→beta; independent north→south (declared order) |
| ordinary unplanned goals untouched | no authority/execution → `planned?: false`, writes nothing | "ordinary goals keep their behavior" |

### 2. Event-derived state; existing admission/lease/durable workers

Task, attempt, acceptance, and progress state fold purely from the five
executor event types (`status/2`, `project/2`); no executor process
state exists. Dispatch goes through `Dispatcher.claim_and_gate/3` with
`grant_lease:` (run row + lease grant persisted before
`Dispatches.enqueue_for_run/2`, never a direct spawn). No second
capacity, wake, checkpoint, lease, or dispatch policy was added. The
existing single-run completion path is unchanged; the multi-task hold
lives only in the executor projection plus the narrow presentation
override.

### 3. Trusted bounded supervised gates bound to the tested commit/worktree

`PlanGateRunner` resolves argv through `PlanGate.argv/1` on every run
(an unknown name such as `rm -rf` is refused — a plan can never supply
executables); runs under a supervisor with a bounded timeout and a
65 536-byte output cap (oversized fails, never truncates); resolves the
actual commit via `git rev-parse HEAD` in the actual worktree.
`verify/4` requires exact binding of goal/task/revision/digest/run/
attempt/gate/argv/commit and `exit_status == 0`. A successful run alone
never unlocks a dependent ("a successful run without passing gates
cannot unlock dependents"); gate failure records bounded
`retry`/`escalate`/`needs_user` and leaves dependents blocked; the goal
completes only after all tasks are accepted plus the global gates pass
at the integrated revision ("a failing global gate blocks goal
completion"). Evidence after a repository or contract change cannot be
silently reused: acceptance re-resolves the attempt contract from the
execution's own bound revision row, and stored argv is flattened to
stay inside the trajectory secret-scan depth bound (mirroring why plan
revision events carry canonical JSON).

### 4. Quota/restart continuation without duplicates or counter reset

`resume/2` rebuilds everything from events: same execution id,
revision, attempt lineage (monotonic per-task attempt numbers),
acceptance contract, and checkpoint (gate) evidence. Accepted tasks
never re-execute ("restart resumes after task one"); duplicate wakes
converge (`:awaiting_task`, no second run); attempts/durations only
grow (`status` counters, "counters only grow" test). No timer or lease
deadline cancels active work: the executor never cancels anything, and
`complete_task_run/3` refuses a non-terminal run instead of timing one
out. One admission decision funds exactly one task dispatch; reuse is
refused as `{:admission_reused, _}` before any side effect, so a
legitimate retry with a fresh admission finds a clean command id.

### 5. Safe supersession

`advance/2` re-reads live authority on every call: after a newer
approval, further dispatch from the old revision is refused
(`{:authority_mismatch, _}`) while the in-flight attempt still runs
its gates and records its result against the revision it ran under —
never cancelled for staleness, never granting authority to changed
work, never adopting the replacement plan. Proved by "a newer approval
stops dispatch while the active attempt still records" (one run total).

### 6. Narrow authority hardening with behavioral locks

| Gap | Lock | Pre-fix proof |
| --- | --- | --- |
| stored digest never re-verified on read | tampered row holds no authority | VERIFIED — fails at `df62479` (authority still returned) |
| non-`human:` deciders accepted in events | approved/rejected payload validation | VERIFIED — fails at `df62479` (both validate cleanly) |
| non-`human:` proposal author in events | revision-created `authored_by` validation | VERIFIED — fails at `df62479` (validates cleanly) |
| replay returns forged authority | rebuild fails on decision-digest mismatch | VERIFIED — fails at `df62479` (rebuild succeeds with forged authority) |

Pre-fix verification method: tracked `lib/` changes stashed (worktree
at `df62479`), new test files kept, `mix test
test/shoestring/cobbler/plan_authority_hardening_test.exs` run — the
five locks above fail for the stated behavioural reasons, never on a
missing module or signature. The sixth test (decision for a
never-created revision) passes pre- and post-fix and is labeled in-file
as documentation of pre-existing behavior, not a lock. Executor, runner,
and presentation tests exercise new functionality absent at the base and
are not claimed as regression proof.

### 7. Hermetic tests, gate honesty

Fake-grade admission, injected gate runner (internal/test config —
never plan-controlled names or results), trivial local worktree
(`File.cwd!/0`), fixed clocks, `start_supervised!`-free isolation via
the DataCase sandbox with monitor/message-free sequential awaits
(`Task.await_many/2` for the true-concurrency test; no `Process.sleep`
or `Process.alive?` anywhere new). No provider CLI, no network. Lock
choice documented in code: `:global.trans` was measured and does NOT
mutual-exclude on `nonode@nohost`, so at-most-once rests on
deterministic ids, store convergence, pre-checks, and idempotent
events instead of a mutex.

## Design notes worth review

**Why one admission per task.** Lease replay is keyed by admission
decision id, so sharing one decision across tasks would converge every
task onto the first task's grant. The executor refuses a bound decision
before any side effect. Operators (and tests) re-observe admission per
task, which is also the correct quota posture between sequential tasks.

**Why stored gate argv is a joined string.** The trajectory
secret-scan (`Contract.safe_term?/1`) bounds nesting at depth 4; a
nested argv list inside per-gate evidence maps exceeds it. Stored
evidence keeps one joined command line per gate (depth-safe) while the
in-memory runner evidence keeps the exact argv list that `verify/4`
compares. Same rationale as canonical-JSON plan revision events.

**Crash window between grant and dispatched-event.** Run ids are
deterministic per (goal, task, attempt), so a crash after the run row
persists but before the dispatched event records is recognized on the
next advance and converged onto the recorded event (`:recovered`)
instead of dispatching a second run for the same attempt.

**Durations.** Attempt/duration counters accumulate from bound gate
evidence (accepted) and recorded attempt durations (failures) and never
reset. Duration-budget refusal before dispatch is approximate by
construction (future gate durations are unknown); attempts are refused
exactly. Stated as a limitation, not a silent guarantee.

## Deviations and limitations

- **UNVERIFIED — gate timeout path.** The runner timeout killer is
  implemented (supervised task terminated on overrun) but has no
  hermetic test: exercising it requires a real overrunning OS process,
  which the hermetic contract forbids. Oversize, refusal, forgery, and
  binding paths are all tested.
- **SCHEMA-ONLY — duration budgets.** Tracked and reported; pre-dispatch
  refusal is attempts-exact, durations-approximate (see above).
- **Concurrent-kickoff loser ergonomics.** A loser that already consumed
  the shared admission reports `{:admission_reused, _}` rather than a
  silent convergence; the next advance converges it to `:awaiting_task`.
  At-most-once (one run) holds in every interleaving observed across
  six seeds; the return shape under a perfect-simultaneity race may
  require that one retry.
- **No planner, no approval UI, no amendment orchestration.**
  Packages B, C, and E remain open, as do the milestone's eval matrix
  and demo. Scope reduction still has no representation (retention rule
  unchanged); supersession remains the only authority transition.
- **Presentation hold scope.** The `:working` hold applies to
  `:completed`/`:failed` folds while a plan executes incompletely;
  `:needs_user` still surfaces (operator attention must never be
  hidden). Both LiveViews degrade to `:unplanned` (legacy fold) on any
  read error rather than crashing the page.
