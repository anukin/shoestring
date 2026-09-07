# Milestone 05: Cobbler Foundation — Durable Commands, Lifecycle State Machine, and SQLite Exclusivity

- **Status**: Foundation PR (Milestone 05 Slice 2, stacked on PR #49)
- **Scope**: Durable Cobbler commands (`cobbler_commands`), intent lifecycle state machine (`Shoestring.Cobbler.StateMachine`), SQLite-enforced exclusive global MVP task claim (`cobbler_claims`), authoritative trajectory persistence (`cobbler.intent_submitted`, `cobbler.intent_claimed`, `cobbler.intent_transitioned` v1), pure/durable trajectory state replay (`Shoestring.Cobbler.StateReplay`), and hermetic test suite. Execution remains strictly disabled.
- **Evidence Label**: `VERIFIED` (all tests passing under ExUnit and `mix precommit`).

---

## 1. Executive Summary

Milestone 05 establishes quota-aware task management and admission control in Shoestring. Building directly on the pure admission evaluation contract delivered in PR #49 (`Shoestring.Cobbler.AdmissionPolicy`, `AdmissionDecision`, `AdmissionEvaluation`), this foundation slice introduces:
1. **Durable Commands & Idempotency**: Caller-supplied stable command IDs scoped to goal, canonical payload hashing, idempotent replay returning original cached results without extra events, and rejection of conflicting payload reuses.
2. **Deterministic Lifecycle State Machine**: Explicit legal lifecycle transitions (`pending` -> `active` <-> `needs_user` -> terminal `completed` / `failed` / `cancelled`). Demonstrates that `needs_user` is recoverable via `resume`, while completed/failed/cancelled states are strictly terminal and reject all subsequent transitions.
3. **SQLite-Enforced Atomic Exclusivity**: Global singleton active task claim enforced at the database level via unique constraints on `active_slot` and `claim_slot` (`status = 'active'`). Eliminates count-then-act races and guarantees that at most one implementation task can be active globally for MVP.
4. **Authoritative Trajectory Integration**: Emits registered trajectory events (`cobbler.intent_submitted`, `cobbler.intent_claimed`, `cobbler.intent_transitioned` v1) with strict payload schema validation, rejecting unregistered fields.
5. **Deterministic Event Replay**: State can be purely reconstructed from trajectory events (`Shoestring.Cobbler.StateReplay`), proving that database tables are derived projections rather than non-reproducible source state.
6. **Execution Disabled**: Pending intents are inert and inspectable. No automated background dispatch, Oban queuing, or Elf process spawning is activated.

---

## 2. Durable Commands and Idempotency Model

`Shoestring.Cobbler.Commands` manages all mutations through durable command records:

### 2.1 Goal-Scoped Caller IDs (`VERIFIED`)
Commands require caller-supplied stable IDs (`command_id`). The unique index `cobbler_commands_goal_id_command_id_index` enforces that command IDs are uniquely scoped per goal:
- Different goals may safely use identical command IDs without collision.
- The same goal cannot execute two distinct operations under the same command ID.

### 2.2 Canonical Payload Hashing and Idempotent Replay (`VERIFIED`)
Each command computes a canonical SHA-256 hash of its payload.
- **Duplicate Execution**: When a command arrives with an existing `(goal_id, command_id)` and matching payload hash, Cobbler returns the original result immediately. No new state transitions are evaluated, and zero new trajectory events are emitted.
- **Conflicting Payload Reuse**: When a command arrives with an existing `(goal_id, command_id)` but a differing payload hash, Cobbler rejects the request with:
  `{:error, {:conflicting_command_payload, "command_id '...' was already executed with a different payload"}}`

---

## 3. Cobbler Intent Lifecycle and State Machine

`Shoestring.Cobbler.StateMachine` provides pure, deterministic transition logic:

| Current State | Event | Target State | Recoverable? | Terminal? | Notes |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `:pending` | `:claim` | `:active` | No | No | Requires exclusive SQLite claim |
| `:pending` | `:needs_user` | `:needs_user` | Yes | No | Suspends prior to claim |
| `:pending` | `:fail` | `:failed` | No | Yes | Terminal failure |
| `:pending` | `:cancel` | `:cancelled` | No | Yes | Terminal cancellation |
| `:active` | `:needs_user` | `:needs_user` | Yes | No | Operator intervention required |
| `:active` | `:complete` | `:completed` | No | Yes | Releases exclusive claim |
| `:active` | `:fail` | `:failed` | No | Yes | Releases exclusive claim |
| `:active` | `:cancel` | `:cancelled` | No | Yes | Releases exclusive claim |
| `:needs_user` | `:resume` | `:active` | No | No | **Recoverable transition** |
| `:needs_user` | `:fail` | `:failed` | No | Yes | Releases active claim if held |
| `:needs_user` | `:cancel` | `:cancelled` | No | Yes | Releases active claim if held |
| `:completed` | *any* | *error* | No | Yes | **Rejected as illegal transition** |
| `:failed` | *any* | *error* | No | Yes | **Rejected as illegal transition** |
| `:cancelled` | *any* | *error* | No | Yes | **Rejected as illegal transition** |

### Safety Invariants (`VERIFIED`):
1. `:needs_user` is strictly recoverable via `:resume`, returning the task to `:active` without losing intent context.
2. Terminal states (`:completed`, `:failed`, `:cancelled`) reject all subsequent transitions with `{:error, {:illegal_transition, state, event}}`.
3. Claims are released exclusively upon terminal transitions, never upon `:needs_user` suspension.

---

## 4. SQLite-Enforced Exclusive Global MVP Claim

### 4.1 Concurrency and Unique Constraints (`VERIFIED`)
In Milestone 05 MVP, concurrency is constrained to at most one active task globally:
- Table: `cobbler_claims`
- Column: `active_slot` (contains `"global"` while active, `nil` when released).
- Unique Constraint 1: `create unique_index(:cobbler_claims, [:active_slot], name: :cobbler_claims_active_slot_index)`
- Unique Constraint 2: `create unique_index(:cobbler_claims, [:claim_slot], where: "status = 'active'", name: :cobbler_claims_singleton_active_index)`

Because SQLite permits multiple `NULL` entries in unique indices, only active claims compete for the unique slot. If a second competing claim attempts insertion while another claim is active:
- SQLite immediately triggers a unique constraint violation.
- Cobbler returns `{:error, {:already_claimed, current_active_claim}}`.
- No count-then-act race window exists (`VERIFIED`).

### 4.2 Exclusivity Boundaries and Never-Release Rules (`VERIFIED`)
In adherence to locked decisions from iteration 4 and `AGENTS.md`:
- **No Timers / Lease Expiries**: No background timer, lease timeout, or heartbeat expiry may release the claim.
- **No Staleness Release**: Staleness is diagnostic evidence, not an automatic release trigger.
- **Explicit Release Only**: Claims are released only upon explicit terminal command execution (`complete`, `fail`, `cancel`).
- **Claim Recovery**: If the same command or intent re-claims, the active claim is safely recovered rather than failing.

---

## 5. Admission Reference Validation Contract (`VERIFIED`)

Arbitrary caller claims of admission cannot bypass policy evaluation:
1. When submitting an intent (`submit_intent`), the caller must supply a valid `AdmissionDecision` struct or serialized map.
2. The decision's `result` must be `:admit`. If the decision is `:defer_until`, `:require_confirmation`, or `:reject`, the intent is rejected with `{:error, {:admission_not_admitted, ...}}`.
3. Candidate provider ID, requested capability, scope, and goal ID (if set) must match the intent attributes byte-for-byte; any mismatch is rejected.
4. Schema validation via `AdmissionDecision.from_payload/2` guarantees that arbitrary forged maps missing required fields or containing unregistered keys fail validation.

---

## 6. Inert Pending Intents and Inspectability

Pending intents (`status: "pending"`) represent admitted, inert task declarations:
- They do not spawn any OS process or background worker.
- They do not enqueue any Oban job.
- They do not dispatch to any Elf or provider adapter.
- They are inspectable via `Shoestring.Cobbler.get_intent/2` and `Shoestring.Cobbler.list_intents/2`.
- Direct execution paths (e.g., direct Elf or adapter CLI invocations) remain outside this foundation boundary; Cobbler does not claim that direct paths are protected.

---

## 7. Trajectory Authoritative Persistence & Replay

All lifecycle state changes emit canonical trajectory events:
- `"cobbler.intent_submitted"` (v1): Records intent creation, admission decision reference, candidate provider, capability, and scope.
- `"cobbler.intent_claimed"` (v1): Records exclusive claim acquisition, claim ID, and timestamp.
- `"cobbler.intent_transitioned"` (v1): Records each state transition (`from_status`, `to_status`, `event_name`, reason).

### Event Replay Stability (`VERIFIED`)
`Shoestring.Cobbler.StateReplay` demonstrates that:
1. Pure replay of trajectory events (`StateReplay.replay_events/1`) reconstructs exact in-memory intent states and active claim status without reading the database.
2. Projection rebuild (`StateReplay.rebuild/2`) can re-populate database rows from scratch after simulated database loss, preserving original UUIDs and terminal states.

---

## 8. Test Coverage and Verification Evidence

All tests pass hermetically using SQLite in-memory sandbox and `Shoestring.Harness.Fake`:

| Test Suite | Path | Tests | Failures | Focus |
| :--- | :--- | :--- | :--- | :--- |
| `StateMachineTest` | `test/shoestring/cobbler/state_machine_test.exs` | 9 | 0 | Legal/illegal transitions, `needs_user` recovery, terminal protection |
| `ClaimTest` | `test/shoestring/cobbler/claim_test.exs` | 4 | 0 | SQLite unique constraints, atomic claiming, never count-then-act, release vacating |
| `CommandsTest` | `test/shoestring/cobbler/commands_test.exs` | 16 | 0 | Caller IDs, idempotency, conflict detection, admission validation, claim exclusivity, lifecycle transitions |
| `StateReplayTest` | `test/shoestring/cobbler/state_replay_test.exs` | 2 | 0 | Pure event fold, database projection rebuild, cold-start recovery |
| `EventRegistryTest` | `test/shoestring/trajectory/event_registry_test.exs` | 18 | 0 | Payload schemas, required fields, UUID casting, unknown field rejection |
| **Total Cobbler** | `test/shoestring/cobbler/` | **72** | **0** | (+31 new tests over PR #49 baseline of 41 tests) |

Full repository gate:
- `mix precommit`: Clean pass across all 838 tests (838 tests, 0 failures, 1 skipped, 6 excluded; 52 Node passes).
