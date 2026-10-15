# Iteration 7: multi-Elf fan-out

**Status:** implementation complete, awaiting human acceptance (2026-10-14) — started 2026-10-13
**Hard dependencies:** iteration 6 complete
**Unlocks:** iteration 8 verification and cross-review

## Mission

Run dependency-free approved tasks concurrently in separate worktrees without
allowing planner enthusiasm or stale subscription observations to overcommit the
same scarce capacity. Preserve successful sibling work when another Elf fails.

## Implementation sequence

REPO-INSPECTION: iteration 6 was accepted on 2026-10-13; its
[closure packet](../evidence/06-cobbler-planning/final-acceptance.md) retains
the planner, telemetry, output-preview, goal-row status and budget limitations.
Start with package B's durable reservation foundation. Keep the sequential
dispatcher enabled until atomic reservation/dispatch ownership, terminal
reconciliation and independence checks are integrated and proven together.

REPO-INSPECTION (2026-10-13): package B's initial acquisition boundary is
implemented; see [the foundation evidence](../evidence/07-multi-elf/reservation-foundation.md).
It records ownership and enforces configured limits with replay/restart checks.
The [settlement package](../evidence/07-multi-elf/reservation-settlement.md) now
closes verified terminal ownership and releases no-intent orphans, with durable
late-intent/resume fences and real Fake lifecycle checks. Existing ambiguous
intents still retain capacity. [Atomic initial-attempt dispatch](../evidence/07-multi-elf/atomic-plan-dispatch.md)
now connects reservations, claims, run/lease intent and delivery behind trusted
opt-in configuration. [Reservation continuations](../evidence/07-multi-elf/reservation-continuations.md)
now provide fresh wake/handoff ownership and verified predecessor settlement;
plan advancement reconciles terminal owners. Sequential claims remain enforced,
initial activation remains opt-in, and no production parallel dispatch is enabled.

REPO-INSPECTION: [CLI inspection and recovery](../evidence/07-multi-elf/reservation-cli-recovery.md)
now exposes durable ownership and queues service-owned reconciliation or explicit
never-started cancellation. Unknown effects/lost identity remain held; no elapsed
deadline or operator assertion frees ambiguous consumption.

REPO-INSPECTION: [scope policy and CLI preflight](../evidence/07-multi-elf/scope-policy.md)
now classify declared and actual scopes deterministically, refusing unknown,
shared, symlink and overlapping surfaces. Its final acceptance integration is
recorded below; CLI preflight alone does not enable dispatch.

REPO-INSPECTION: [sibling workspace binding](../evidence/07-multi-elf/sibling-workspaces.md)
now allocates separate private Git stores from the exact accepted base and
records immutable task lineage. Dirty unowned or foreign allocations are
refused and retained. The coordinator has not enabled sibling execution yet.

REPO-INSPECTION: [reservation-owned dispatch](../evidence/07-multi-elf/reservation-dispatch-ownership.md)
now persists per-child command/run/lease/delivery intent without a global task
claim. Legacy claims and outstanding reservations cannot bypass each other's
ownership checks. Its initial coordinator integration is recorded below.

REPO-INSPECTION: [the internal coordinator](../evidence/07-multi-elf/internal-fanout-coordinator.md)
now dispatches independent initial tasks into pinned private stores, skips blocked
providers, reconstructs every child and reserves duration for held children and
global gate command timeouts. An isolated production-worker/Fake lifecycle proves
two concurrent supervised children, independent acceptance, restart-safe intent,
dependency admission and never-started cancellation without affecting a sibling.
Production worker activation and remaining lifecycle
recovery are still pending; ordinary advancement is fenced for fan-out executions.

REPO-INSPECTION: [final scope acceptance](../evidence/07-multi-elf/final-scope-acceptance.md)
now binds changed files to tested commits after verified process settlement.
Unexpected overlap, shared surfaces, scope escape and unavailable final evidence
record durable blockers with passed gates retained. Unaffected siblings can still
be accepted; blockers stop subsequent admission and survive replay/restart.
Human conflict resolution and production activation remain pending.

REPO-INSPECTION: [the durable child inbox](../evidence/07-multi-elf/child-inbox-wakeups.md)
now captures progress, checkpoint, stop and verification notifications with their
pinned parent/task/attempt identity. Source events, inbox receipts and service
delivery jobs commit together; canonical observations deduplicate processing.
Terminal delivery verifies siblings independently without advancing dispatch.
Startup replay repairs missing/discarded delivery and status exposes pending
messages. Production fan-out, explicit conflict resolution and replacement
policy remain pending.

REPO-INSPECTION: [pre-fan-out prerequisites](../evidence/07-multi-elf/pre-fanout-prerequisites.md)
now keep generic goal rows synchronized with canonical completion, charge and
reserve fan-out final-scope verification overhead, and retain full redacted
public Claude output that fails rather than truncates when oversized.

REPO-INSPECTION: [scope resolution](../evidence/07-multi-elf/scope-resolution.md)
lets a human accept or reject one scope-blocked attempt by CLI; acceptance
acknowledges exactly the recorded blockers and nothing merges.

REPO-INSPECTION: [partial-failure recovery](../evidence/07-multi-elf/partial-failure-recovery.md)
classifies every child's stop, replaces bounded task/adapter failures with
their own checkpoint through normal admission, and cancels one child or the
whole goal by stopping owned process groups.

REPO-INSPECTION: [production activation](../evidence/07-multi-elf/production-activation.md)
routes the execution worker through a default-off fan-out driver with a
deterministic sequential fallback, completes fan-out executions, and unlocks
dependents only after a read-only verified human integration.

- First: configured global/provider-account/goal limits, shared weighted units,
  immutable admission provenance and replay-safe durable reservation identity.
- Next: explicit conflict resolution and production coordinator activation,
  bounded replacement and partial-failure recovery. Preserve
  uncertain owners until additional process evidence can resolve them.
- Before fan-out (done): canonical/generic goal status synchronization,
  worst-case verification budget and full bounded public Claude output.

The user authorized work directly on main without a PR; this overrides the
standing worktree/PR workflow for this implementation.

## Required outcomes

- Durable global, provider, and goal concurrency limits.
- Conservative capacity reservations outside model prompts.
- One isolated branch/worktree and trajectory lineage per concurrent task.
- Durable Cobbler inbox/wakeup events for child progress.
- Restart-safe dispatch and partial-failure recovery.
- Explicit conflict policy for uncertain or overlapping file scopes.

## Preflight

- Read iteration 6 completion record and replay an approved sequential plan.
- Prove iteration 5 admission and leases remain correct with one active run.
- Select fixture task graphs with known independent and conflicting changes.
- Define account/provider scope identifiers used for concurrency and reservation.
- Choose conservative configured reservation units; learned consumption is not
  available yet.
- Default global/provider-account/goal limits and shared configured units to one;
  increasing them is an explicit operator configuration decision.
- Until account discovery exists, use one shared local scope per provider and
  submission scope. Never invent separate account scopes for sibling tasks.

## Locked decisions

- Only dependency-satisfied approved tasks are candidates for fan-out.
- Concurrency and reservations are enforced by deterministic code.
- Observed provider capacity is shared account state, not duplicated per Elf.
- MVP reservations are conservative configured allowances, not learned forecasts
  and not provider-enforced guarantees.
- Each implementation Elf has its own worktree.
- Uncertain independence defaults to sequential execution or human approval.
- One child failure never erases successful sibling events/artifacts.
- Automatic merging remains out of scope.

## Work package A: dispatch coordinator

- Extend Cobbler to compute the set of dependency-satisfied, unstarted tasks.
- Acquire global, provider/account, and per-goal concurrency slots atomically
  before durable dispatch intent.
- Acquire a capacity reservation using the same snapshot/policy version used for
  admission.
- Persist slot/reservation/dispatch ownership before launching an Elf.
- Use stable dispatch IDs so restart reconciliation cannot duplicate runs.
- Release slots/reservations on every terminal or reconciled orphan path.
- Avoid head-of-line blocking where a task for one provider prevents an
  otherwise safe task for another provider.

## Work package B: conservative reservations

Represent a reservation with:

- reservation ID, provider/account scope, goal/task/run, policy version;
- capacity observation ID and age at grant;
- configured reserve unit or class;
- admission lease bounds and a reconciliation deadline;
- state: held, consumed/closed, released, or reconciliation-required. An elapsed
  deadline is evidence requiring reconciliation; it never frees capacity or
  authorizes cancellation/replacement by itself. Uncertain owners still count.

Because the MVP cannot reliably translate a task into usage percentage, the
reservation may be a configured concurrency-weight or coarse task class. It
must prevent every concurrent candidate from independently claiming all of the
same allowance. These units do not predict provider percentage headroom. Usage
visualizations must call them conservative/configured, not predicted.

## Work package C: worktree/branch fan-out

- Create every task worktree from an explicit accepted base commit.
- Record branch lineage and the plan/task revision.
- Keep sibling filesystem state isolated.
- Never silently reuse another task's dirty worktree.
- Preserve successful/failed branches for user inspection.
- Record output commits/diffs and verification artifacts independently.
- Detect if the source/base branch changed after plan approval and require a
  rebase/replan decision rather than assuming compatibility.

## Work package D: independence and overlap policy

Use layered evidence:

1. planner-declared file/symbol scopes are hints only;
2. deterministic repository metadata/static analysis may improve them;
3. actual changed-file sets become authoritative after execution;
4. overlapping changed files or shared migration/configuration surfaces block
   automatic integration and may require sequential redo or human resolution.

- Define high-risk shared surfaces such as lockfiles, migrations, generated
  registries, and central configuration.
- Require explicit user approval to run concurrently when declared scopes
  overlap or are unknown under strict mode.
- Record independence/conflict decisions and evidence in the trajectory.

## Work package E: child inbox and wakeups

- Give each child run a durable parent Cobbler/goal/task identity.
- Record progress, checkpoint, suspended, failed, and completed messages as
  events rather than ephemeral mailbox-only facts.
- Wake Cobbler from committed child events.
- Deduplicate delivery by event/command ID.
- Reconstruct active children and pending messages after restart.
- Update the plan projection without waiting for all siblings to terminate.

## Work package F: partial failure and replacement

- Preserve completed siblings and their evidence.
- Classify retryable adapter failure, quota sleep, task failure, cancellation,
  and conflict separately.
- Apply bounded retry/replacement policy through normal admission.
- A replacement Elf receives the failed child's checkpoint, not sibling
  transcripts.
- User cancellation may target one child or the goal; define and test both.
- Goal completion remains blocked until required failed tasks are resolved or a
  new approved plan revision removes/supersedes them.

## Required evals

| Eval | Scenario | Required result |
| --- | --- | --- |
| Independent fan-out | Two disjoint tasks | Concurrent isolated runs |
| Provider cap | Three tasks, limit one | Only one provider slot acquired |
| Shared headroom | Two candidates | Reservations prevent double claim |
| Restart after intent | Crash before child start | One reconciled dispatch |
| Restart while running | Two active fakes | Children/state recovered once |
| Sibling failure | One pass, one crash | Passing artifacts retained |
| Overlap known | Both target same file | Sequential/confirmation required |
| Overlap discovered | Diffs overlap unexpectedly | Integration blocked visibly |
| Quota sleep | One child suspended | Other safe child may continue |
| Cancel one | Target child cancellation | Sibling unaffected |
| Cancel goal | Parent cancellation | All children boundedly stopped |

## Economic/fairness eval

Simulate multiple goals and provider windows. Measure:

- maximum simultaneous runs versus configured limits;
- reservation leaks after every failure state;
- false parallel admissions against the same headroom;
- time a ready goal waits behind unrelated blocked work;
- successful tasks preserved per partial failure;
- observed capacity delta per verified child where fixtures/live data permit.

Do not optimize fairness with model judgment; use an explicit deterministic
queue policy and record its version.

## Demo

1. Approve a DAG with two independent tasks and one dependent task.
2. Dispatch the independent tasks to separate fake or real worktrees.
3. Fail one child while the other completes.
4. Restart Shoestring and show successful work/reservations reconstructed.
5. Replace/resume the failed child.
6. Show the dependent task unlock only after both acceptance gates.
7. Run an overlapping-scope fixture and show fan-out refusal.

## Acceptance gate

- Concurrency never exceeds deterministic configured limits.
- Reservations are durable, explainable, and released on all terminal paths.
- Restart never duplicates an admitted child.
- Sibling branches/events/artifacts are isolated and survive partial failure.
- Conflict/uncertainty policy prevents unsafe automatic concurrent integration.
- Planner output cannot allocate slots or capacity directly.
- CLI exposes slots, reservations, children, blockers and provider evidence.
  The UI remains Agents, Settings and Usage; it may visualize configured
  allowance, but execution, approvals and child management remain CLI workflows.

## Out of scope

- Learned capacity reservation sizes.
- Automatic merge/cherry-pick into the user's branch.
- Distributed workers or remote hosts.
- Cross-provider review loops.
- Arbitrary swarm/recursive agent creation.

## Likely blockers and response

- **Provider account scope is unclear:** enforce the more conservative shared
  scope and expose the assumption.
- **Reservation units lack calibration:** use concurrency-weight classes and
  small limits; forecasting arrives later.
- **Tasks appear independent but edit shared code:** block integration and retain
  both branches for human/sequential resolution.
- **Restart cannot attach to vendor session:** suspend/checkpoint/reconcile rather
  than relaunching blindly.

## Completion record

- **Final status:** implementation complete; awaiting human acceptance. See the
  [final acceptance packet](../evidence/07-multi-elf/final-acceptance.md).
- **Completed on:** implementation 2026-10-14; acceptance pending.
- **Concurrency/reservation policy version:** `ReservationPolicy` version 1
  (all limits and units default to one); fan-out queue policy version 1
  (rotating round-robin over goals, declared task order, provider-blocked tasks
  skipped).
- **Events/schemas/configuration:** reservation, settlement and operation
  events; `cobbler.plan.child.observed`; `cobbler.plan.task.scope_resolved`;
  `cobbler.plan.cancellation.requested`/`completed`;
  `cobbler.plan.integration.recorded`; `verification_overhead_ms` on
  acceptance events. Config: `:plan_fanout` (`enabled: false`) and
  `:plan_reservation_policy`.
- **Conflict-detection strategy:** layered file-level evidence. Declared hints
  must be known and disjoint before dispatch; live observations run before more
  dispatch; final changed files are bound to the tested commit. Any overlap,
  shared surface, symlink, escape or unknown blocks for an explicit human
  accept/reject. Uncertainty falls back to sequential execution, and nothing
  merges automatically.
- **Deterministic eval results:** all 11 required evals VERIFIED (see packet).
- **Economic/fairness results:** maxima equal to the limits (3/2/2), zero false
  admissions, leaks or unrelated waits; 10/12 tasks accepted with zero
  regressions. Capacity delta is unavailable with Fake.
- **Verification commands:** `mix precommit` → 4 doctests, 2161 tests,
  0 failures, 1 skipped, 6 excluded; JavaScript 52/52 and 8/8.
- **Demo result:** VERIFIED on an isolated node with live Fake Elves through the
  production driver ([transcript](../evidence/07-multi-elf/demo/transcript.json)).
- **Deviations and remaining risks:** integration happens through a
  human-recorded merge commit, because iteration 6 forbids amending an accepted
  repository contract. Dependents after integration run sequentially. Fan-out
  ships default-off. No live provider fan-out was run.
- **Instructions for iteration 8:** verify fan-out children with
  independent/cross-provider review using the retained private branches and
  final-scope evidence. Keep integration human-recorded. Reuse
  `stop_class`, cancellation and replacement rather than adding a second
  failure policy.
