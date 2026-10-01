# Human plan contract v1

REPO-INSPECTION: This is the inert iteration-6 foundation, covering manual goal
contracts, validated DAG proposals, immutable revisions, exact approval/rejection,
and canonical replay. It introduces no planner, executor, dispatch adapter,
amendment orchestration, approval UI, or acceptance runner. It does not complete
the broader iteration-6 milestone.

## Domain boundary

REPO-INSPECTION: `Shoestring.Cobbler` exposes the following functions. Each accepts
an authenticated `owner_id` supplied by the application boundary, never an owner
from the content map. IDs must be canonical lowercase UUID strings. A request ID
is a nonblank UTF-8 string of at most 100 bytes, scoped to the goal across all plan
operations. Optional `opts` supports `repo:` for hermetic repository testing.

| Function | Required arguments before optional opts |
| --- | --- |
| `create_plan_goal` | owner ID, caller-assigned goal UUID, request ID, goal contract |
| `propose_plan` | owner ID, goal ID, request ID, exact latest revision UUID (nil initially), full content |
| `approve_plan` | owner ID, goal ID, request ID, exact revision UUID, exact content digest |
| `reject_plan` | owner ID, goal ID, request ID, exact revision UUID, exact content digest, reason |
| `read_plan` | owner ID, goal ID |
| `plan_revision` | owner ID, goal ID, revision UUID |
| `active_plan_authority` | owner ID, goal ID |
| `rebuild_plans` | owner ID, goal ID |

REPO-INSPECTION: Mutations return `{:ok, %{state: state, event: event,
repeated?: boolean}}` or `{:error, reason}`. Reads/rebuild return `{:ok, state}`;
revision reads return `{:ok, revision}`; active authority returns `{:ok, revision}`
or `{:ok, nil}`. Wrong ownership is concealed as `:goal_not_found`. UUID syntax
and protected observatory identities fail as `:invalid_identity`. These library
entrypoints assume a trusted authenticated caller; they are not a replacement for
authentication. The existing low-level trajectory append interface is also an
internal trusted application interface.

REPO-INSPECTION: Goal creation records an immutable initial contract and an inert
goal identity labelled "Planning goal". Its actual statement lives in the
canonical contract. Creation can define a contract for an existing owned active
goal with no prior plan contract. New mutations require an active goal; exact
idempotent repeats remain readable after terminal settlement. Proposal is the
plan creation/edit operation and always creates a new revision. No task/run/lease
rows or Oban jobs are created by these functions.

## Strict representation

REPO-INSPECTION: `PlanContract` accepts JSON-shaped values with string object keys;
it rejects atom keys, structs, floats, malformed UTF-8, improper lists, unknown
fields at every level, unsupported versions, and credential-shaped text. It bounds
encoded input to 131,072 bytes, depth to 16, visited nodes to 32,768, object size to
64, and aggregate raw text/scalar storage before JSON encoding. All limits apply
together, including the event wrapper. Inputs exceeding any limit fail; they are
never truncated. Schema/DAG errors are lists of `%{path: [...], code: atom}` without
copies of rejected content. Event registry errors use the established
`{:invalid_payload, type, version, changeset}` wrapper carrying structured errors.

REPO-INSPECTION: Every field below is required. Empty lists are permitted only
where their minimum is zero; their presence makes the absence explicit.

| Goal field | Meaning and bounds |
| --- | --- |
| `version` | Exactly integer 1 |
| `statement` | Nonblank UTF-8 text, 8,000 bytes |
| `repository` | `reference` (500-byte logical reference), `base_revision` (40 lowercase hex characters) |
| `constraints`, `non_goals` | Explicit lists, 0–32 entries, 2,000 bytes each |
| `acceptance` | Shared acceptance object below |
| `execution` | Per-task ceilings below |
| `budget` | Planning attempts 0–10; revisions 1–100; total response tokens 1–10,000,000; total tool calls 1–100,000 |

REPO-INSPECTION: Budget keys are `max_planning_attempts`, `max_revisions`,
`max_total_response_tokens`, and `max_total_tool_calls`. An edited goal cannot
change its repository reference/base or raise an initial budget/execution cap.
Revision counts do not reset after rejection or approval, and each proposal must
also fit its own `max_revisions`. Constraints, non-goals, criteria, and statements
can change in a new reviewable revision. Budget fields bound proposed execution;
this slice does not consume provider allowance or introduce a consumption ledger.

| Plan content field | Meaning and bounds |
| --- | --- |
| `version` | Exactly integer 1 |
| `goal` | Complete goal contract snapshot, included in content digest |
| `provenance` | `kind` must be `human`; `version` is a 100-byte manual authoring version; `source_context_refs` is 0–32 logical references of 500 bytes |
| `tasks` | 1–64 task contracts |

| Task field | Meaning and bounds |
| --- | --- |
| `id` | Stable canonical lowercase UUID, scoped to this goal's DAG |
| `title`, `outcome` | Nonblank text, 500 / 4,000 bytes |
| `dependencies` | 0–63 stable task UUIDs from this same revision |
| `inputs`, `hints` | Explicit lists of logical inputs/file/symbol hints, 0–32 entries of 500 bytes |
| `expected_artifacts` | 1–32 logical artifact descriptions of 500 bytes |
| `acceptance` | Shared acceptance object below |
| `checkpoint` | Nonblank `condition` (2,000 bytes) and `evidence` (1–32 logical references of 500 bytes) |
| `risk_notes` | Explicit uncertainty/risk list, 0–32 entries of 2,000 bytes |
| `execution` | Numeric per-task bounds below |

REPO-INSPECTION: Acceptance requires `criteria` (1–32 nonblank entries of 2,000
bytes), `evidence` (1–32 nonblank logical references of 500 bytes), and `gates`
(currently exactly one trusted name: `mix_precommit`). Shell strings, arbitrary
commands, and `model_success` are not gate names. No contract text or logical
reference is evaluated, executed, fetched, or interpreted as acceptance evidence.

SCHEMA-ONLY: A later trusted acceptance runner must map `mix_precommit` to the
repository-controlled gate and bind actual gate results to task/revision/base
identity. A task/model success message alone must never unlock dependencies or
complete a goal. Evidence/checkpoint descriptions are required here, but the
foundation does not produce or verify those artifacts.

REPO-INSPECTION: Execution keys are `max_attempts` (1–10),
`max_runtime_seconds` (1–86,400), `max_response_tokens` (1–1,000,000), and
`max_tool_calls` (1–10,000). Each task must fit the revised goal's per-task ceiling.
The sum of response/tool bounds multiplied by each task's attempt bound must fit
the revised goal's total budget. Numeric ceilings are proposal limits; a runtime
limit must never become an automatic cancellation trigger for useful work.

REPO-INSPECTION: DAG validation rejects duplicate identities, missing references,
self-dependencies, duplicate edges, and cycles before domain or low-level event
persistence. Topological order repeatedly selects the lowest eligible task UUID,
so task input ordering does not change the projected ordering. Lists remain
content: changing their order changes the digest even if the DAG is equivalent.

## Revisions, decisions, and authority

REPO-INSPECTION: A proposal event's UUID is its revision UUID. Revision content is
never modified. Every revision retains its full content, author (`human:<owner
UUID>`), proposal time, base revision, digest, DAG order, status, and decision
metadata. Approval/rejection records the deciding event UUID, attributed actor,
time, exact digest, decision status, and rejection reason (nonblank, at most 2,000
bytes). Revision/decision IDs and metadata are assigned by the domain, outside the editable map.

REPO-INSPECTION: The v1 digest is lowercase SHA-256 of the deterministic Erlang
external-term encoding of recursively canonicalized content: objects become
key-sorted key/value tuples; lists preserve order; JSON scalars preserve value.
The embedded version and goal contract are covered. The fixed synthetic fixture
digest and JSON round-trip test lock this format. A request digest separately
covers event type, owner UUID, and full request. Hashes bind content, not user
identity authentication; the caller must authenticate the supplied owner.

REPO-INSPECTION: Only the latest proposed revision can receive a new decision.
Unknown/foreign revisions fail as `:revision_not_found`; stale decisions fail as
`:stale_revision`; content mismatch fails as `:digest_mismatch`; a second distinct
decision fails as `:decision_conflict`. Proposal checks the exact latest base,
including rejected proposals, and fails as `:stale_revision_or_revision_budget`
when stale or exhausted. Reusing a request ID with different content/type fails
as `:idempotency_conflict`. An exact repeat returns its original event plus the
current state; repeating an old approval never restores superseded authority.

REPO-INSPECTION: A new proposal leaves previous approved authority intact.
Rejection leaves it intact too. Approval atomically selects the new revision and
marks the previous approved revision superseded, preserving its approval and
content. Older undecided proposals remain recorded but stale. No supersession
side effect interrupts/cancels work or rewrites existing task/run/lease state.
This slice conservatively refuses removal of any ever-approved task identity
(`:approved_task_identity_removed`), including identities from superseded plans.

SCHEMA-ONLY: The eventual dispatcher must check current authority in the same
transaction as the dispatch claim, requiring an active goal and matching revision, digest, dependency
completion, gate evidence, admission, and lease policy. A cached revision or
`active_plan_authority` read is not a dispatch capability. Existing iteration-5
legacy dispatch continues independently; this foundation does not route it through
plans. There is no plan-task dispatch entrypoint in this slice.

SCHEMA-ONLY: Future amendment/executor work must retain completion and checkpoint
evidence under stable goal/task identity, prohibit rediscovery or mutation of
accepted work, map goal-scoped plan IDs to durable execution task identities,
maintain consumed allowance and attempt counters across revisions/restarts, and
serialize approval/supersession with new claims. Supersession must prevent future
claims for the prior revision without cancelling an already useful active run.
The conservative identity-preservation rule here is not amendment orchestration
or a completed-task acceptance ledger.

## Canonical events and rebuild

REPO-INSPECTION: Registered v1 events are `cobbler.plan.goal_defined`,
`cobbler.plan.revision_proposed`, `cobbler.plan.revision_approved`, and
`cobbler.plan.revision_rejected`. Each carries only `request_id`, `request_digest`,
and a strict operation-specific `request`. They share trajectory sequence numbers
with existing events and use `plan:<request ID>` idempotency keys. Plan events have
no task/run/parent links. Human ownership, digest, ordering, causal transitions,
and unique request/event identities are revalidated during replay. Unknown future
plan types/versions fail closed instead of silently ignoring possible authority.

REPO-INSPECTION: Event insertion and derived `cobbler_plan_projections` replacement
are one immediate SQLite transaction. A local repository lock serializes plan
writers before connection checkout; SQLite remains the durable writer lock across
processes and other code paths. Outside contention can return `:storage_busy`
without a partial write. The caller can explicitly repeat its original request;
the service does not automatically retry. Events publish after the transaction.

REPO-INSPECTION: Reads and approval derive authority from canonical events, never
from the projection row. `rebuild_plans` recomputes and upserts every derived plan
field in one transaction; it does not delete events, goal/task identities, or
history. Pure replay is `Plans.replay_events(goal, ordered_plan_events)`. Generic
goal/task projection continues to ignore the existing `cobbler.*` family, while
the plan registry enforces the deeper strict schema on write and replay.

## Spec alignment and remaining scope

REPO-INSPECTION: The supplied milestone is proposed and includes planner admission,
model-assisted decomposition, approval UI, sequential execution, and bounded
amendments. The explicit implementation brief narrows this PR to the foundation.
Its earlier hermetic lifecycle follow-up is already present at the merged base;
this change does not edit that test or its evidence ledger. Numeric caps, manual
provenance, a SHA-1-shaped repository base, immutable initial budget ceilings, and
conservative retention of all approved task IDs are choices made concrete here;
the milestone does not specify their exact wire shapes or numbers. SHA-256 Git
repository IDs and repository/base-changing amendments need a later schema/policy.

UNVERIFIED: No planner transport, provider quota accounting, live provider run,
UI approval, executor acceptance, amendment orchestration, or iteration-7 dispatch
has been verified or claimed by this foundation.
