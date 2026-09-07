# Milestone 05: Quota-Aware Admission Policy and Deterministic Decision Model

- **Status**: Foundation PR (Milestone 05 Slice 1)
- **Scope**: Deterministic admission evaluation (`Shoestring.Cobbler`), versioned policy configuration, durable trajectory event persistence (`admission.decided` v1), and hermetic ExUnit tests. Dispatch remains inactive.
- **Evidence Label**: `VERIFIED` (all tests passing under ExUnit and `mix precommit`).

---

## 1. Executive Summary

Milestone 05 introduces quota-aware admission into Shoestring to prevent unbudgeted execution and provider rate-limit exhaustion. This foundation PR delivers pure, deterministic admission evaluation without activating automated dispatch.

Key architectural properties:
1. **Pure Deterministic Function**: `Shoestring.Cobbler.AdmissionEvaluation.evaluate/5` evaluates requests with explicit `now: %DateTime{}` and policy inputs. No hidden system clock reads or external network/CLI calls exist.
2. **Durable Versioned Event**: Admission evaluations persist as canonical `admission.decided` (v1) trajectory events via `Shoestring.Trajectory.append/3`, maintaining complete historical auditability.
3. **Operational Reserve Margins**: Reserves 20% remaining on 5-hour windows (refuses automatic admission at >= 80% used) and 10% on weekly windows (refuses automatic admission at >= 90% used).
4. **Strict Safety Boundaries**: Hard constraints (unsupported capability, incompatible CLI, hard quota blocks, reserve breaches, scope mismatches, active occupancy) **cannot be bypassed** by manual confirmation.
5. **Attributable Confirmation**: Bypasses for unknown, stale, or conservative observations require explicit attributable operator confirmation and are never described as automatically safe.
6. **No Past Reset Loops**: Stale or past reset timestamps schedule an explicit delayed recheck rather than an immediate retry loop, mandating re-observation prior to eventual dispatch.
7. **SQLite Concurrency Model**: Pure evaluation documents that atomic exclusivity requires runtime transactional locking in SQLite (immediate/exclusive write transactions, rather than PostgreSQL `SELECT FOR UPDATE`).

---

## 2. Operational Reserve Defaults and Lease Bounds

### 2.1 Quota Thresholds
Thresholds are operational safety buffers, **not empirical predictions** of task cost (`VERIFIED`):
- **5-Hour Window**: Reserve 20% remaining capacity. Automatic admission is refused when `used_percent >= 80.0%`.
- **Weekly Window**: Reserve 10% remaining capacity. Automatic admission is refused when `used_percent >= 90.0%`.
- **No Inferred Percentage Cost**: Tasks do not claim or subtract an arbitrary predicted percentage; evaluation ensures current usage is strictly below the reserve ceiling.

### 2.2 Conservative Lease Bounds
Default execution lease bounds proposed by admission decisions:
- **Response Budget**: 10 responses (`response_budget`)
- **Tool Budget**: 25 tool calls (`tool_budget`)
- **Deadline**: 300 seconds (5 minutes) from evaluation timestamp (`deadline_seconds`)
- **Checkpoint Cadence**: Every 1 turn (`checkpoint_cadence`)
- **Reserves**: `%{response: 1, tool: 1}`

### 2.3 Delayed Recheck Bounds
- **Delayed Recheck**: 60 seconds (`delayed_recheck_seconds`). When a quota reset timestamp is in the past or absent during a refusal/breach, evaluation defers until `now + delayed_recheck_seconds` to prevent CPU-spinning retry loops.

---

## 3. Decision Outcomes and Reason Codes

`Shoestring.Cobbler.AdmissionDecision` emits four mutually exclusive results:

| Result | Description | Typical Reason Codes |
| :--- | :--- | :--- |
| `:admit` | Admitted for execution (automatic or confirmed) | `automatic_admission_eligible`, `confirmed_unknown_capacity`, `confirmed_stale_observation` |
| `:defer_until` | Temporarily blocked until capacity resets or occupancy clears | `reserve_breach_five_hour`, `reserve_breach_weekly`, `past_reset_delayed_recheck`, `scope_occupied`, `hard_quota_refusal_deferred` |
| `:require_confirmation` | Requires attributable single-decision confirmation | `unknown_capacity`, `stale_observation`, `support_tier_conservative_partial`, `support_tier_reactive_only`, `missing_window_five_hour`, `missing_window_weekly` |
| `:reject` | Permanently refused for this candidate (cannot bypass) | `unsupported_capability`, `incompatible_cli`, `unsupported_tier`, `scope_mismatch` |

---

## 4. Manual Confirmation and Hard Boundaries

### 4.1 Attributable Single-Decision Confirmation
Manual confirmation allows an operator to authorize execution when observations are incomplete or degraded. A valid confirmation requires:
- `confirmed_by`: Non-empty operator/command identity (e.g., `"operator:alice"`). Unattributed confirmations are rejected (`"confirmation_invalid_unattributed"`).
- `target_provider_id`: Must match candidate provider ID. Mismatches are rejected (`"confirmation_invalid_provider_mismatch"`).
- `target_scope`: Must match candidate scope. Mismatches are rejected (`"confirmation_invalid_scope_mismatch"`).
- `intent`: Explicit operational intent string (e.g., `"emergency_manual_run"`).

### 4.2 Non-Bypassable Hard Constraints (`VERIFIED`)
The following conditions **CANNOT** be bypassed by manual confirmation under any circumstance:
1. **Unsupported Capability**: Candidate cannot satisfy requested capability.
2. **Incompatible CLI / Adapter**: Provider adapter is marked `:incompatible`.
3. **Unsupported Tier**: Provider is marked `:unsupported`.
4. **Scope Mismatch**: Requested account/provider scope does not match candidate scope.
5. **Active Occupancy**: Scope is currently occupied by another active run/lease.
6. **Hard Quota Block**: Provider reported explicit quota refusal (`capacity_state: :refused`).
7. **Known Reserve Breach**: Observed usage meets or exceeds maximum thresholds (`>= 80%` 5-hour or `>= 90%` weekly).

When an unbypassable constraint is encountered, evaluation returns `:reject` or `:defer_until` even if a valid confirmation is provided, explicitly noting that confirmation cannot bypass the constraint.

### 4.3 Honest Language
When admitted via confirmation, the decision explanation explicitly records:
`"Admitted via attributable single-decision confirmation by '...'; not automatically safe (...) "`
Manual execution is **never** described as automatically safe (`VERIFIED`).

---

## 5. Missing Evidence and Reset Timestamps

### 5.1 Missing Evidence Preserved as Unknown
If a snapshot or window is absent, `used_percent` is stored as `nil` (unknown), **never manufactured as 0%** (`VERIFIED`). Manufacturing 0% would falsely indicate full capacity availability.

### 5.2 Reset Timestamps in the Past
If a window or refusal reports a reset timestamp `reset_at <= now`, scheduling a retry at `reset_at` would cause an immediate, infinite retry loop. In this scenario:
- `defer_until` is calculated as `now + policy.delayed_recheck_seconds` (default: 60s).
- Reason code is set to `"past_reset_delayed_recheck"`.
- `reobservation_required` is set to `true`.
- Eventual dispatch will require a fresh observation before granting execution.

---

## 6. Concurrency and SQLite Guarantees

Pure admission evaluation evaluates candidate eligibility in-memory. However:
- Pure evaluation does **not** claim to provide atomic exclusivity across distributed nodes or concurrent OS processes.
- Concurrency control must be enforced transactionally at runtime.
- In Shoestring's SQLite deployment, exclusive access must be established via `BEGIN IMMEDIATE` / write transactions on the underlying database, avoiding assumptions of Postgres-style `SELECT FOR UPDATE` (`REPO-INSPECTION`).
- Explicit occupancy evidence (`occupancy`) is evaluated conservatively: if occupancy indicates the provider or account is active, evaluation immediately defers.

---

## 7. Durable Persistence Schema (`admission.decided` v1)

The decision payload schema is registered in `Shoestring.Trajectory.EventRegistry`:

```elixir
"admission.decided" => %{
  1 => %{
    required: [
      :decision_id,
      :result,
      :reason_code,
      :explanation,
      :requested_capability,
      :candidate,
      :scope,
      :observation,
      :policy,
      :proposed_bounds,
      :reobservation_required,
      :evaluated_at
    ],
    optional: [
      :run_id,
      :defer_until,
      :override,
      :extensions
    ],
    uuid_fields: [:decision_id, :run_id],
    types: %{
      candidate: :map,
      observation: :map,
      policy: :map,
      override: :map,
      proposed_bounds: :map,
      reobservation_required: :boolean,
      evaluated_at: :utc_datetime,
      defer_until: :utc_datetime,
      extensions: :map
    }
  }
}
```

This schema guarantees durable replay stability across application restarts and database reloads.
