# Initial planner boundary

REPO-INSPECTION: package B decomposes a goal into a candidate plan. It is
callable through `Shoestring.Cobbler` without LiveView. Human revision editing,
approval and rejection remain the existing `Plans` domain; inference never
approves a plan, dispatches a task, grants a lease, changes reserves, or gets
filesystem tools.

## Entry points

| Facade | Effect |
| --- | --- |
| `request_plan(goal_id, attrs, opts)` | Store an immutable bounded projection and model/budget configuration |
| `generate_plan(goal_id, request_key, opts)` | Admit, claim, charge, then make the initial inference call |
| `repair_plan(goal_id, request_key, opts)` | One explicit repair after schema/unsafe output, with fresh admission |
| `planning_status(goal_id)` | Read candidate state, validation errors, tier and quota accounting |
| `rebuild_planning(goal_id)` | Rebuild from events and report row divergence, without mutation |
| `adopt_planned_revision(goal_id, request_key, attrs, opts)` | Human-authored proposal bound to the reviewed candidate digest |

REPO-INSPECTION: request attributes are `request_key`, `requested_by` (a
`human:` identity), `goal_contract` (the package A goal contract), and optional
`context_event_ids` (at most 15). The bounded projection includes durable goal
title/description, the fixed goal acceptance and repository/base contract, and
explicit goal-owned evidence references with selected summaries. Only goal,
decision, completed-task and checkpoint facts are eligible. Provider output,
transcripts and hidden reasoning are never projected. Oversized or sensitive
inputs fail; they are not truncated.

REPO-INSPECTION: inference returns `{:ok, %{request: row, outcome: ...}}`.
Read `row.state`: `pending`, `blocked`, `running`, `ready`, `schema_failed`,
`unsafe_proposal`, `transport_failed`, or `budget_exceeded`. Validation errors
are bounded diagnostics in `row.errors["items"]`. A `ready` candidate is stored
as canonical JSON plus its SHA-256 digest. Adoption takes `digest` and
`authored_by`, plus `parent_revision_number` when needed, and creates a
`proposed` revision. User rejection uses the existing `reject_plan/3` API and
its distinct durable rejection event.

## Configuration

REPO-INSPECTION: inference is disabled by default. Choose an already installed
local model explicitly; this boundary does not download models:

```elixir
config :shoestring, :planner,
  adapter: :ollama,
  model: "your-installed-model",
  endpoint: "http://127.0.0.1:11434",
  max_output_tokens: 4096,
  timeout_ms: 60_000
```

REPO-INSPECTION: only the fixture and Ollama adapters are registered. The
Ollama endpoint must be HTTP on loopback with no credentials, path, query or
fragment. Model selection, endpoint digest and bounds bind the durable request;
configuration changes cannot reroute a replay. The server's own deployment and
model selection remain the operator's responsibility.

SCHEMA-ONLY: the production HTTP request uses Ollama's documented
[`/api/generate`](https://docs.ollama.com/api/generate) structured-output
`format`, explicit `model`, non-streamed generation and `num_predict` output
bound. It supplies no tools and disables thinking. The response collector is
bounded at 131,072 bytes. Req retries and redirects are disabled, following
the [Req interface](https://req.hexdocs.pm/Req.html). Hermetic Plug stubs exercise
the actual adapter code; live model inference and semantic quality were not
verified.

## Admission and accounting

REPO-INSPECTION: every initial/repair call evaluates the existing
`AdmissionEvaluation` policy for `read_only`, persists `admission.decided`,
acquires the existing exclusive global Cobbler task claim, and reserves the
full output allowance in one SQLite transaction before inference. An occupied
claim, mismatched provider/scope, quota refusal or reserve breach prevents the
call; confirmation cannot lift a hard stop. Inference is supervised and bounded
by the configured deadline. Terminal results release only the owned claim.

REPO-INSPECTION: local model quota observation is unknown by default and its
support tier is `reactive_only`. The application caller can explicitly provide
`confirm_unknown_capacity: true` for that one call. Confirmation is attributed
to the requesting human and bound to provider, scope and `read_only` intent.
It must be supplied again for a repair; it is never inferred from a prior call.
The foundation's `human:` identity convention is attribution, not a newly
introduced authentication system.

REPO-INSPECTION: per goal, initial planning has one durable request and at most
two inference calls. Output allowance is 1..8192 tokens per call, charged in
full before invocation. Reported output usage is recorded separately and must
fit that allowance. Failed or lost calls retain their full charge. Input data
is bounded at 24,576 bytes and evidence summaries at 4,000 bytes each. These
are deterministic ceilings, not estimates of a provider's percentage quota or
actual monetary cost. A fresh request key, restart, manual revision, or config
change cannot reset the counters.

REPO-INSPECTION: a repeated initial call returns stored state. Schema/unsafe
output permits one explicit repair with the original validation errors. Invalid
raw output is discarded; repair receives the bounded projection and feedback.
Transport failures never enter an automatic correction loop. A crash after
reservation leaves `running` state and its claim intact: replay cannot know
whether inference happened, and therefore makes no replacement call. Manual
plan authoring remains available. Recovering abandoned ambiguous claims requires
an explicit operator decision; this package adds no timer or cleanup policy.

## Validation and authority

REPO-INSPECTION: the adapter receives a JSON schema with the fixed goal and
bounded task contracts. The authoritative check is the existing `PlanContract`:
unknown fields, commands, invalid DAGs, missing criteria/checkpoints, invalid
gates and execution bounds fail closed. The candidate must preserve the entire
normalized goal contract. Shoestring supplies model provenance; a model cannot
supply an author or approval. Text is proposal content, never executable policy;
schema checks do not claim to prove semantic correctness.

REPO-INSPECTION: four version-1 event types record request, block, attempt start
and finish. They validate canonical inputs/results on write and replay.
`rebuild_planning/1` checks request/result bindings, evidence ownership and
admission lineage; cache divergence prevents further inference or adoption.
The planner task supervisor restarts empty and never redispatches a lost call.

UNVERIFIED: real model quality, live quota measurement, and production UI wiring
were not verified. Package C must render the stored candidate, errors and quota
data and request exact human actions. Package E must define its amendment
budget and protect completed evidence before admitting any new replan. Neither
package is silently implemented by this initial-planning budget.
