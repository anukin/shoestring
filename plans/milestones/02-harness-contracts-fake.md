# Iteration 2: harness contracts and deterministic fake

**Status:** complete  
**Hard dependencies:** iteration 1 complete  
**Unlocks:** iterations 3 and 4

## Mission

Define Shoestring's vendor-neutral harness, capacity, lease, run, and checkpoint
contracts, then prove the lifecycle against a deterministic fake. Vendor CLI
availability must not be required to develop or test the supervisor.

## Required outcomes

- Small, versioned contracts separating execution from capacity observation.
- Legal run and lease state transitions owned by deterministic code.
- A scriptable fake harness that can reproduce success and every important
  failure boundary.
- Shared adapter contract tests for future Claude/Codex implementations.
- Initial run, checkpoint, and capacity-snapshot persistence.

## Preflight

- Read iteration 1's completion record and verify replay/rebuild tests.
- Read gate 0A evidence if available, but do not hard-code raw vendor fields into
  normalized contracts.
- Inventory the event registration and migration-extension procedures.
- Decide how time and identifiers are injected so tests never depend on sleeps
  or ambient wall clock.
- Confirm which contract payloads are durable events and which are ephemeral
  transport messages.
- Confirm the selected Oban version's Lite engine and SQLite migration/config
  requirements, and define deterministic manual test execution for jobs.
- Define the transaction/reconciliation boundary between durable
  `dispatch.requested` intent and Oban job insertion.

## Locked decisions

- Vendor transports terminate at adapters; Cobbler and Elf consume normalized
  domain events.
- Capacity source failure is independent of execution-process failure.
- Unknown is a first-class state, not a numeric default.
- Models never own run lifecycle or legal transitions.
- Leases expire deterministically but stop work only at safe harness boundaries.
- The fake implements the same public behavior as production adapters.
- A valid minimum checkpoint can be constructed without a model response.
- Oban Lite provides durable delivery attempts; trajectory events and lifecycle
  projections remain canonical domain state.
- Every job carries a durable `dispatch_id` and reconciles existing run state
  before repeating an external effect.
- Job completion is not task/run acceptance, and an Oban retry is never treated
  as proof that the prior external effect did not occur.

## Work package A: split adapter contracts

Prefer small behaviors over one omnipotent adapter. Exact module names may be
refined, but preserve these responsibilities:

```text
Harness.Adapter
  identity/capabilities, probe, start, resume, send, cancel, status

Harness.Run
  normalized event stream and process/session identity

Capacity.Source
  observe windows, provenance, freshness, confidence, support tier
```

- Define typed input/output structs and error categories.
- Keep provider names, CLI versions, adapter versions, and invocation modes in
  metadata.
- Separate transport/process errors, schema incompatibility, authentication
  required, quota refusal, cancellation, and ordinary task failure.
- Define capability discovery rather than assuming every adapter supports
  resume, send, cancellation, or interactive operation.

## Work package B: normalized contracts

Define and version at least:

- `RunRequest`: goal/task, workspace, prompt/continuation projection, policy,
  requested capabilities, and durable dispatch ID;
- `HarnessEvent`: lifecycle/output/tool/command/artifact/capacity/error/result
  with source event ID and ordering metadata;
- `CapacitySnapshot`: windows, used percentage where known, reset, observed-at,
  source, scope, freshness, confidence, support tier, and compatibility state;
- `ExecutionLease`: grant ID, admitted snapshot, reserves, response/tool budget,
  deadline, checkpoint cadence, and renewal state;
- `Checkpoint`: acceptance contract, repository state, evidence, decisions,
  unresolved issues, next action, provider session ID, and stop reason.

Avoid a universal unstructured `metadata` map as a substitute for required
fields. Preserve provider-specific extensions in a namespaced, bounded field.

## Work package C: lifecycle state machines

Define legal transitions and rejection behavior. A suggested run lifecycle is:

```text
requested -> starting -> running -> pausing -> suspended
                              \-> completed
                              \-> failed
                              \-> cancelling -> cancelled
```

Lease lifecycle:

```text
proposed -> granted -> active -> renewal_due -> renewed
                                  \-> expired -> checkpoint_required
                                  \-> revoked -> checkpoint_required
```

- Persist intent before simulated external effects.
- Make terminal states idempotent.
- Reject impossible transitions visibly and record enough context to diagnose
  the caller.
- Register the corresponding versioned trajectory events and projectors.

## Work package D: migrations and persistence

Add schemas owned by the established contracts:

- runs and provider/session metadata;
- checkpoints and artifact references;
- capacity snapshots/windows or a normalized equivalent;
- durable dispatch/lease identifiers where they are not represented solely by
  events.
- Oban's SQLite tables/configuration, introduced as delivery infrastructure
  rather than lifecycle persistence.

Keep trajectory events canonical for lifecycle. Tables optimized for current
queries must remain rebuildable or clearly identify non-derived identity data.
Where supported by the chosen configuration, persist dispatch intent and its
Oban job in one Ecto transaction. Regardless, add reconciliation that can
repair durable intent with no corresponding job after restart.

## Work package E: deterministic fake harness

Build a scenario DSL or fixture format that can schedule events against an
injected clock. Required scenarios:

- normal completion;
- approaching reserve across response boundaries;
- sudden quota refusal with no final response;
- stale and missing capacity;
- malformed/unknown vendor event;
- start failure and mid-run process crash;
- cancellation before and after an external-effect event;
- planned lease expiration at a safe boundary;
- same-session resume;
- cross-harness handoff to a second fake identity;
- delayed/duplicated/out-of-order transport delivery where applicable.

The fake should record received requests so tests can prove that raw prior
transcripts and forbidden data were not passed.
Drive fake dispatch through the Oban worker boundary in deterministic test mode
so retry, cancellation, and duplicate-delivery behavior are exercised before a
real provider process exists.

## Work package F: shared contract suite

Provide a reusable adapter test suite accepting a module/configuration and
asserting:

- identity and compatibility reporting;
- normalized start, stream, completion, failure, and cancellation;
- capability-appropriate resume behavior;
- quota refusal classification;
- missing/malformed capacity behavior;
- secret-free persistence and diagnostics;
- terminal idempotency and cleanup.

Production adapters must pass this suite plus their transport-specific tests.

## Required deterministic evals

| Eval | Fake scenario | Required result |
| --- | --- | --- |
| Replay | Complete then delete projections | Same run/lease/checkpoint state |
| Sudden limit | Refusal after partial work | Checkpoint possible with no model call |
| Safe lease stop | Deadline during operation | Pause after completion boundary only |
| Duplicate terminal | Completion delivered twice | One terminal transition |
| Stale capacity | Clock advances beyond TTL | Snapshot becomes ineligible/unknown |
| Handoff privacy | Fake B receives continuation | No fake A raw transcript |
| Schema drift | Required field removed | Compatibility degraded visibly |
| Restart | Stop supervisor mid-scenario | No duplicate dispatch on recovery |
| Delivery retry | Execute one durable dispatch job twice | One logical run/effect for the stable `dispatch_id` |

## Demo

Run one scripted goal through:

1. healthy capacity and lease grant;
2. partial work events;
3. sudden quota refusal;
4. deterministic checkpoint creation;
5. application restart and replay;
6. second fake harness continuation without the first transcript;
7. verified completion.

The demo may use synthetic repository artifacts; real worktrees arrive in
iteration 4.

## Acceptance gate

- All later orchestration can be developed against the fake.
- Contracts encode provenance, compatibility, freshness, and unknown states.
- Legal transitions are deterministic, versioned, persisted, and replayable.
- Every required fake scenario has a stable no-network test.
- Checkpoint structure does not require model-authored summary fields.
- Shared adapter tests are documented for iteration 3 and 4 agents.

## Out of scope

- Starting Claude Code, Codex, or Git worktrees.
- Production capacity parsing.
- Model planning or semantic checkpoint scoring.
- PTY/terminal protocols.
- Forecasting consumption.

## Likely blockers and response

- **Contract grows around vendor quirks:** move quirks to provider extensions and
  retain a small semantic core.
- **State duplicated between tables and events:** name the canonical fact and
  add a rebuild test for every derived table.
- **Fake diverges from production:** require production adapters to pass the
  same suite and add observed sanitized fixtures rather than special cases.
- **Tests rely on sleep:** inject clocks and explicit event advancement.

## Completion record

- **Final status:** Implementation, deterministic test suite, contract suite, and unified 7-step integration demo complete. All 16 fake scenarios and 9 deterministic evals pass without network access.
- **Completed on:** 2026-09-02 (America/Vancouver).
- **Contracts and versions:**
  - `Identity` v1 (`adapter_id`, `provider`, `adapter_version`, `schema_version`, `invocation_mode`);
  - `RunRequest` v1 (`goal_id`, `task_id`, `workspace_ref`, `prompt`, `continuation`, `policy`, `requested_capabilities`, `dispatch_id`, `extensions`);
  - `CapacitySnapshot` v2 (`snapshot_id`, `capacity_state`, `windows`, `observed_at`, `expires_at`, `freshness`, `source`, `scope`, `confidence`, `support_tier`, `compatibility_state`, `reason`, `extensions`);
  - `ExecutionLease` v1 (`grant_id`, `run_id`, `admitted_snapshot_id`, `reserves`, `response_budget`, `tool_budget`, `deadline`, `checkpoint_cadence`, `renewal_state`, `extensions`);
  - `Checkpoint` v1 (`checkpoint_id`, `goal_id`, `run_id`, `acceptance_contract`, `repository_state`, `evidence`, `decisions`, `unresolved_issues`, `next_action`, `provider_session_id`, `stop_reason`, `artifact_ids`, `extensions`);
  - `HarnessEvent` v1 (`run_id`, `source_event_id`, `ordinal`, `occurred_at`, `kind`, `process_id`, `provider_session_id`, `artifact_id`, `capacity_snapshot_id`, `error`, `result`, `extensions`);
  - `Error` struct with typed normalized categories (`:transport`, `:schema_incompatible`, `:auth_required`, `:quota_refused`, `:cancelled`, `:task_failed`, `:unsupported_capability`, `:invalid_transition`).
- **Schemas/migrations:**
  - Ecto schemas: `RunRecord` (`harness_runs`), `ExecutionLeaseRecord` (`harness_leases`), `CheckpointRecord` (`harness_checkpoints`), `CheckpointArtifactReference` (`harness_checkpoint_artifacts`), `CapacitySnapshotRecord` (`harness_capacity_snapshots`), `CapacityWindowRecord` (`harness_capacity_windows`), `DispatchRecord` (`harness_dispatches`), and Oban Lite SQLite tables (`oban_jobs`, `oban_peers`);
  - Migrations: `20260831050006_add_harness_foundation.exs`, `20260901232504_add_oban_dispatch.exs`, `20260901232628_evolve_capacity_snapshot_contract_v2.exs`, `20260902232748_add_harness_run_request_extensions.exs`, `20260903000650_harden_capacity_snapshot_contract_v2.exs`.
- **Events/transitions added:**
  - Registered durable events in `EventRegistry`: `run.requested` (v1), `run.starting` (v1), `run.running` (v1), `run.pausing` (v1), `run.suspended` (v1), `run.completed` (v1), `run.failed` (v1), `run.cancelling` (v1), `run.cancelled` (v1), `dispatch.requested` (v1), `dispatch.effect_failed` (v1), `dispatch.effect_unknown` (v1), `dispatch.effect_deferred` (v1), `lease.proposed` (v1), `lease.granted` (v1), `lease.active` (v1), `lease.renewal_due` (v1), `lease.renewed` (v1), `lease.expired` (v1), `lease.revoked` (v1), `lease.checkpoint_required` (v1), `checkpoint.created` (v1), `capacity.snapshot_observed` (v1, v2), and `harness.event_recorded` (v1);
  - Pure state machines: `RunStateMachine` (`requested -> starting -> running -> pausing -> suspended`, `running -> completed / failed / cancelling -> cancelled`, with idempotent terminal handling) and `LeaseStateMachine` (`proposed -> granted -> active -> renewal_due -> renewed`, `expired -> checkpoint_required`, `revoked -> checkpoint_required`).
- **Fake scenarios implemented:**
  - All 16 scripted offline scenarios implemented in `Shoestring.Harness.Fake.Scenario`: `normal_completion`, `approaching_reserve`, `sudden_quota_refusal`, `stale_capacity`, `missing_capacity`, `malformed_event`, `start_failure`, `mid_run_crash`, `cancel_before_effect`, `cancel_after_effect`, `lease_expiry_at_safe_boundary`, `same_session_resume`, `cross_harness_handoff`, `delayed_delivery`, `duplicated_delivery`, `out_of_order_delivery`.
- **Contract-suite results:**
  - `Shoestring.Harness.ContractSuite` shared test suite implemented in `test/support/contract_suite.ex` and exercised in `test/shoestring/harness/contract_suite_test.exs` (both conforming capability adapter validation and intentional rejection tests for non-conforming adapters).
- **Verification commands:**
  - `mix test test/shoestring/harness/fake/demo_test.exs`: 1 test, 0 failures;
  - `mix test test/shoestring/harness/`: 109 tests, 0 failures;
  - `mix precommit`: formatting, warnings-as-errors compilation, full ExUnit suite, and Gate 0A Node checks pass cleanly.
- **Demo result:**
  - `test/shoestring/harness/fake/demo_test.exs` coherently verifies all 7 mandated demo steps in one unified automated flow:
    1. Healthy capacity observation and ExecutionLease grant;
    2. Partial work events from Fake Adapter A;
    3. Sudden quota refusal before an end-of-turn response;
    4. Deterministic Checkpoint creation without model inference;
    5. Simulated application restart (terminating supervised writer process) followed by pure trajectory replay and complete projection reconstruction from canonical SQLite events;
    6. Continuation through Fake Adapter B using only structured checkpoint references, proving zero raw transcript leakage;
    7. Terminal run and goal task completion verified in both database projections and canonical trajectory.
- **Deviations and deferred findings:**
  - None from the core contract requirements. Synthetic repository artifacts are used per plan specification; real Git worktrees are intentionally scheduled for Iteration 4.
- **Instructions for iteration 3:**
  - Consume normalized `CapacitySnapshot` observations exclusively through `Shoestring.Harness.Capacity.Source` behavior.
  - Rely on `CapacitySnapshot.eligible?/2` and `freshness/2` rather than inspecting raw vendor status strings.
  - Implement proactive polling and reactive status-line parsers conforming to `CapacitySnapshot` v2.
  - Build the Cobbler planner against the deterministic fake harness before integrating real provider transports.
- **Instructions for iteration 4:**
  - Wrap provider CLI transports (Claude Code and Codex) in `Shoestring.Harness.Adapter` implementations.
  - Execute the shared contract suite (`Shoestring.Harness.ContractSuite`) against all production adapters.
  - Guarantee that continuation requests use only `Checkpoint` references and structured task prompts, preserving the zero-raw-transcript-leakage invariant proven in Iteration 2.
