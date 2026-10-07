# Iteration 6: Cobbler planning and approval

**Status:** in progress

## Implementation status

VERIFIED (GitHub inspection, 2026-10-07): package A merged in
[PR #89](https://github.com/anukin/shoestring/pull/89); the L1 hermetic lifecycle
follow-up merged in [PR #87](https://github.com/anukin/shoestring/pull/87).
[PR #90](https://github.com/anukin/shoestring/pull/90) remains a draft package D
implementation with successful CI and no submitted reviews at inspection.
The older draft [PR #88](https://github.com/anukin/shoestring/pull/88) remains
open; it does not add completed work beyond the merged foundation.

VERIFIED (GitHub inspection, 2026-10-07): package B merged in
[PR #91](https://github.com/anukin/shoestring/pull/91). REPO-INSPECTION: it adds the deterministic fixture planner,
configured local model boundary, quota admission, durable attempts/accounting,
strict structured validation, and one explicit repair. See
`../../docs/planner-boundary.md` and the package evidence record. It does not
close iteration 6. Package C (CLI approval interface), package E (amendment/replan), and
package D's independent review, production wiring, worktree binding and
integration proof remain pending. Remaining amendment contract decisions are
recorded explicitly below.

## Product interface decision (2026-10-05)

VERIFIED (user direction in the design discussion): work, plan review/edit,
approval/rejection, execution, and continuation belong in the CLI. The web UI
is for agent/orchestrator configuration and provider usage-limit visualization;
sessions, chat, CLI output, test output, and task execution are not product UI
requirements. This supersedes package C's earlier web approval UI requirement
without changing its durable revision, validation, quota, or approval contracts.
Package C remains pending as a CLI interface; this decision is not evidence of
implementation or iteration completion.

The accepted visual direction and implementation/acceptance checklist are recorded
in [the configuration and usage UI milestone](configuration-and-usage-ui.md),
with a repository-owned HTML mockup. That follow-up is separate from the
iteration-6 sequential execution acceptance gate. REPO-INSPECTION: Usage, Agents,
Settings and immutable CLI profile lookup are implemented. CLI plan approval,
approved-run profile binding and amendment/replan are not closed by that UI work.

**Hard dependencies:** iteration 5 complete

**Unlocks:** iteration 7 multi-Elf fan-out

## Mission

Add bounded model-assisted decomposition while deterministic Cobbler code retains
authority over lifecycle, quotas, dependencies, worktrees, and dispatch. A user
can review and edit an explicit task graph, approve it, and let Shoestring
execute its tasks sequentially through the quota-aware MVP.

## Required outcomes

- A versioned goal acceptance contract and planner-output schema.
- A durable, validated task DAG with checkpoint conditions.
- Human approval/edit/reject flow.
- Sequential execution through existing admission and lease policy.
- Bounded amendment/replanning without rediscovering accepted work after restart.

## Preflight

- Read iteration 5 completion record and replay one completed/interrupted goal.
- Verify planner inference itself can be admitted/accounted for; planning is not
  a free control-plane operation.
- Select fixture goals with known decompositions and acceptance tests.
- Decide which provider/local model can plan by configuration, without encoding
  personality claims such as “Claude always plans better.”
- Confirm all lifecycle policy APIs are callable without going through LiveView.

## Locked decisions

- Planner output is a proposal, never an executable command stream.
- Planner cannot dispatch, change reserves, approve itself, select destructive
  integration, or bypass worktree policy.
- Every task requires a bounded acceptance contract and checkpoint condition.
- The approved plan is durable; restart never asks a model to recreate it.
- Initial plan execution is sequential even when tasks are independent.
- Replanning is bounded, attributable, and approval-gated when scope changes.

REPO-INSPECTION: package B fixes initial-planning decisions: one durable request
per goal, at most two calls (initial plus one human-requested repair), a fixed
goal contract including repository/base and non-goals, and tool-free inference.
The full configured output allowance is charged before each call; failed calls
and new request IDs never replenish it. Unknown local-model capacity requires
single-decision confirmation and remains labeled `reactive_only`.

UNVERIFIED / undecided for package E: approval-gated retirement of an approved
task identity, the amendment budget shared with initial planning, and rules for
carrying accepted evidence into materially changed task contracts. The merged
foundation retains every approved task ID until an explicit retirement path
exists. These decisions are not implicitly relaxed by the planner boundary.

## Work package A: goal and task contracts

Define a strict versioned plan representation containing:

- goal statement, repository/base revision, constraints, explicit non-goals,
  global acceptance commands/evidence, and human approval metadata;
- task ID, title, bounded outcome, dependencies, inputs, expected artifacts,
  file/symbol hints where useful, task acceptance criteria, deterministic gates,
  safe checkpoint condition, and risk/uncertainty notes;
- planner identity/version and source context references;
- no embedded shell strings that bypass command policy.

Represent dependencies by stable task IDs. Validate missing references,
self-dependencies, cycles, duplicate IDs, empty outcomes, and unbounded tasks.

## Work package B: planner boundary

- Build the planning prompt/projection from durable goal/repository evidence.
- Request strict structured output and validate it before persistence.
- Record model-visible inputs by reference/summary without hidden reasoning.
- Distinguish transport failure, schema failure, unsafe proposal, and user
  rejection.
- Bound planning attempts and quota consumed.
- On invalid output, show validation errors and allow one bounded repair attempt
  or user edit; do not enter an infinite correction loop.
- Support a deterministic fixture planner for tests.

## Work package C: CLI approval interface

Allow the user, through the CLI, to:

- inspect goal contract and ordered/dependency task view;
- edit outcomes, dependencies, criteria, checkpoints, and non-goals;
- see validation errors and quota impact/support tier for the planner;
- approve a specific immutable plan revision;
- reject it with a recorded reason;
- create a new revision rather than mutating approved history.

No task may dispatch from an unapproved or superseded revision.

## Work package D: sequential executor

- Project the next dependency-satisfied task from the approved DAG.
- Submit that task through iteration 5 admission and execution leases.
- Create per-task checkpoints while preserving goal-level trajectory lineage.
- On completion, require the task acceptance evidence before unlocking dependents.
- On sleep/handoff, retain the same task identity and plan revision.
- On failure, choose deterministic retry/escalate/needs-user states according to
  bounded policy; a planner may advise only after the state is recorded.
- Complete the goal only after every required task and global acceptance gate.

## Work package E: amendment and replan

- Permit a bounded replan request when evidence invalidates the approved plan.
- Give the planner current plan, completed tasks, checkpoints, constraints, and
  failure evidence—not an unbounded transcript.
- Protect completed task history; replacements/supersessions are new events.
- Require user approval when dependencies, acceptance, non-goals, or meaningful
  scope change.
- Prevent replanning from resetting quota reservations or retry counters.

## Follow-up from iteration 5: one end-to-end lifecycle test

**Status:** VERIFIED: implemented and merged in PR #87 (2026-10-01). The
composed application flow and its limits are recorded in
`../evidence/06-cobbler-planning/hermetic-lifecycle.md`. That document's earlier
draft/review statuses describe its historical runs; the merge status here is
current. This follow-up does not reopen iteration 5.

Add one hermetic integration test that follows a single goal from UI submission
through dispatch, a scripted quota refusal, deterministic checkpoint creation,
application restart, reset wake/recheck, and continuation to completion. Use
`Shoestring.Harness.Fake` and trivial local commands; no provider CLI or network.
Drive the flow through product entry points and normal workers, without manually
projecting trajectory events or mutating lifecycle rows to force progress.

Acceptance criteria:

- The checkpoint preserves the task identity, acceptance contract, and required
  continuation evidence across restart.
- Wake/recheck re-evaluates capacity and dispatches exactly one continuation;
  replayed wake requests do not duplicate jobs or runs.
- Assert final run, lease, checkpoint, and goal projections and their visible UI
  state, including terminal completion without a leftover active lease.
- Exercise quota refusal as the recovery trigger. A lease deadline alone must
  not interrupt tools or suspend and redispatch naturally completed work.
- Start test processes under supervision and wait for owned processes to exit
  during teardown; do not leave Elves or monitors using the database afterward.
- Run `mix precommit` and record the exact results. If the test exposes a defect,
  verify that its regression assertion fails on the pre-fix commit for the
  intended behavioral reason.

## Required evals

| Eval | Planner/plan input | Required result |
| --- | --- | --- |
| Valid DAG | Known fixture | Durable revision and approval flow |
| Cycle | A depends B; B depends A | Validation failure, no dispatch |
| Missing criterion | Task lacks acceptance | Validation failure |
| Unsafe instruction | Planner asks to bypass reserves | Rejected/ignored by code |
| Invalid JSON/schema | Malformed fixture | Bounded repair/user path |
| Restart | Stop after task one | Continue task two without replan |
| Plan edit | User changes dependency | New revision, old preserved |
| Replan | Failure after partial completion | Completed work retained |
| Quota blocked planner | No planning capacity | Queue/manual plan, no bypass |
| Premature completion | Task result lacks gate | Dependents remain blocked |

## Semantic planner eval

Use several small repository goals and score proposals on:

- coverage of the goal acceptance contract;
- boundedness and independence of tasks;
- correct dependency ordering;
- useful checkpoint conditions;
- absence of invented repository facts;
- unnecessary task count and expected handoff overhead;
- success of sequential execution, not aesthetic plan quality alone.

Compare model plans to a human-authored fixture plan. Keep deterministic schema
and execution results separate from an optional judge score.

## Demo

1. Submit a fixture goal.
2. Generate and display a structured plan.
3. Edit one task/dependency and approve a revision.
4. Execute the first task sequentially.
5. Restart Shoestring.
6. Continue from the accepted revision without another planning call.
7. Reject an invalid/cyclic planner fixture visibly.

## Acceptance gate

- Invalid, cyclic, unapproved, or superseded plans cannot dispatch.
- Planner calls obey capacity/admission policy and bounded attempts.
- Approved plan revisions and user edits are durable trajectory facts.
- Sequential execution respects dependencies and task/global gates.
- Restart continues the accepted plan without rediscovery.
- Planner cannot mutate lifecycle, reserves, worktrees, or approval state.
- Replan retains completed evidence and requires approval for material changes.

## Out of scope

- Parallel execution or overlapping-file analysis.
- Automatic merge and cross-provider review.
- Learned task-size/capacity forecasting.
- Planner self-approval or fully autonomous scope changes.
- General project-management features.

## Likely blockers and response

- **Structured output remains unreliable:** keep human-authored plans available,
  improve validation feedback, and bound repair attempts.
- **Tasks are too large:** reject or require edit based on explicit boundedness
  rules rather than trusting planner adjectives.
- **Planner consumes scarce allowance:** admit it like other work and allow a
  local/manual planner configuration.
- **Repository changes invalidate plan:** record evidence and create a reviewed
  amendment rather than silently mutating tasks.

## Completion record

- **Final status:**
- **Completed on:**
- **Plan/goal schema versions:**
- **Events/projections/configuration:**
- **Planner adapters/fixtures:**
- **Deterministic eval results:**
- **Semantic planner eval results:**
- **Verification commands:**
- **Demo result:**
- **Deviations and remaining risks:**
- **Instructions for iteration 7:**
