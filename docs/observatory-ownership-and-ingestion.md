# Capacity Observatory Ownership and Ingestion Foundation

This document specifies the architecture, public sink/ledger ingestion APIs, bounded semantic deduplication, neutral query APIs, and cross-goal lease reference boundary introduced for Iteration 3. It serves as the reference for subsequent PRs: `CodexMonitor`, `ClaudeMonitor`, harness supervision, and LiveView.

## Architecture

To preserve the invariant of the non-null, goal-scoped trajectory model without weakening foreign keys or altering existing database schemas:

1. **Internal Singleton Goal**: A dedicated, protected internal goal serves as the durable event stream for capacity observations:
   - **Goal ID**: `"00000000-0000-4000-8000-000000000cb0"`
   - **Owner ID**: `"00000000-0000-4000-8000-0000000000cb"`
   - **Status**: `"protected"`
2. **Database Protection**: The singleton goal is provisioned idempotently via database migration. SQLite triggers (`protect_observatory_goal_update` and `protect_observatory_goal_delete`) prevent accidental or unauthorized updates or deletions.
3. **Domain Isolation**: `Shoestring.Trajectory.Goal.user_goals/1` excludes the observatory goal from normal user listings. `Shoestring.Trajectory.Goal.changeset/2` forbids modifications to the protected goal, and `create_changeset/3` forbids claiming the observatory owner ID.
4. **Passive Claude & Proactive Codex**: The ledger supports both proactive meters (Codex) and passive interactive telemetry (Claude). Provider monitors ingest into this common ledger without coupling to goal lifecycles.

---

## Public Ingestion Sink API

The primary entrypoint for monitors is `Shoestring.Harness.Observatory.ingest/2` (also available via `Shoestring.Harness.CapacityObservatory.ingest/2`).

```elixir
alias Shoestring.Harness.Observatory

# Ingest a validated CapacitySnapshot struct:
{:ok, :persisted, snapshot} = Observatory.ingest(snapshot)

# Or ingest map attributes (parsed via CapacitySnapshot contract):
{:ok, :persisted, snapshot} = Observatory.ingest(snapshot_attrs, now: DateTime.utc_now())

# When an equivalent high-frequency reading is ingested:
{:ok, :deduplicated, existing_snapshot} = Observatory.ingest(same_snapshot)
```

### Ingestion Flow

1. Validates the input against the canonical `CapacitySnapshot` v2 specification.
2. Ensures the observatory singleton goal is provisioned in the database (`ensure_provisioned/1`).
3. Compares the incoming reading against the latest recorded observation for the target `{provider_id, invocation_mode, scope}`.
4. **If equivalent**: Returns `{:ok, :deduplicated, existing_snapshot}`. No new event is appended, and the ledger does not grow. The original `observed_at` timestamp and snapshot identity are preserved.
5. **If changed**:
   - Appends a canonical `capacity.snapshot_observed` v2 event under `@observatory_goal_id` through `Shoestring.Trajectory.append/3`.
   - Projects the event into `harness_capacity_snapshots` and `harness_capacity_windows` via `Shoestring.Harness.Projector.project/2`.
   - Returns `{:ok, :persisted, snapshot}`.

---

## Bounded Semantic Deduplication

Repeated equivalent high-frequency readings (e.g. from 1-second refresh callbacks or periodic polling) do not grow the ledger. However, changes are never erased:

### Deduplication Key
`{provider_id, invocation_mode, scope}`

### Equivalence Criteria (`equivalent?/3`)
Two observations `a` and `b` are equivalent at time `now` if and only if:
- **Capacity State**: `a.capacity_state == b.capacity_state` (e.g., `:observed`, `:degraded`, `:refused`, `:unknown`).
- **Support Tier**: `a.support_tier == b.support_tier` (`:proactive`, `:conservative_partial`, `:reactive_only`, `:unsupported`).
- **Compatibility**: `a.compatibility_state == b.compatibility_state` (`:compatible`, `:degraded`, `:incompatible`).
- **Confidence**: `a.confidence == b.confidence` (`:high`, `:medium`, `:low`, `:none`).
- **Reason**: `a.reason == b.reason`.
- **Provenance**: `a.source` matches `b.source` across `adapter_id`, `provider_id`, `invocation_mode`, and `event`.
- **Freshness Policy**: `a.freshness.max_age_seconds == b.freshness.max_age_seconds`.
- **Freshness State Transition**: `CapacitySnapshot.freshness(a, now) == CapacitySnapshot.freshness(b, now)`. If an existing reading has transitioned from `:fresh` to `:stale`, a new reading is persisted.
- **Windows**: Identical window counts, kinds, states, `used_percent` values (no floating point drift), `reset_at` timestamps, and unknown reasons.
- **Extensions**: `a.extensions == b.extensions`.

### Timestamp & Age Preservation Across Restart
Because deduplication skips appending new events rather than overwriting stored timestamps with synthetic values, the true observation timestamp (`observed_at`) is preserved across node restarts, replays, and `Projector.rebuild/2`.

---

## Provider-Neutral Query API

Designed for consumption by monitors, supervisors, and LiveView telemetry views:

### 1. `latest_observation/4` and `get_latest_observation/4`
Fetches the latest snapshot for a provider/mode/scope:

```elixir
# Returns {:ok, snapshot} or {:error, :not_found}
{:ok, snapshot} = Observatory.latest_observation("codex", "app_server", "account-1")

# Returns snapshot or nil
snapshot = Observatory.get_latest_observation("claude", "interactive_status_line", "claude-session")
```

### 2. `latest_observations/1`
Returns the list of latest snapshots across all active provider scopes:

```elixir
snapshots = Observatory.latest_observations()
```

### 3. `observation_summary/2`
Produces a unified, presentation-ready telemetry map:

```elixir
summary = Observatory.observation_summary(snapshot, now: DateTime.utc_now())
```

Summary shape:
- `provider_id`: String (e.g. `"codex"`, `"claude"`)
- `invocation_mode`: String (e.g. `"app_server"`, `"interactive_status_line"`)
- `adapter_id`: String
- `event`: Atom (e.g. `:explicit_read`, `:status_line_input`)
- `scope`: String
- `capacity_state`: `:observed | :degraded | :refused | :unknown`
- `windows`: List of `%{kind, state, used_percent, reset_at, reason}`. **No fake 0% values**: unknown windows have `used_percent: nil`.
- `freshness_state`: `:fresh | :stale | :unknown`
- `age_seconds`: Non-negative integer (seconds elapsed since observation) or `nil`
- `max_age_seconds`: Positive integer
- `observed_at`: `DateTime.t()` or `nil`
- `expires_at`: `DateTime.t()` or `nil`
- `confidence`: `:high | :medium | :low | :none`
- `compatibility_state`: `:compatible | :degraded | :incompatible`
- `support_tier`: `:proactive | :conservative_partial | :reactive_only | :unsupported`
- `reason`: String diagnostic reason or `nil`
- `eligible?`: Boolean automation eligibility evaluated strictly via `CapacitySnapshot.eligible?/2`. Only fresh, compatible, high-confidence, proactive observations with complete observed windows are eligible; all others fail closed (`false`).
- `snapshot`: The underlying `CapacitySnapshot.t()` struct.

---

## Future Lease Lookup Boundary

User execution leases (`lease.proposed`) require referencing an admitted capacity snapshot (`admitted_snapshot_id`).

In `Shoestring.Harness.Projector`:
- When a user run under user goal `goal_id` proposes a lease, the projector verifies `snapshot.goal_id == goal_id or snapshot.goal_id == observatory_goal_id`.
- If the snapshot is owned by the protected observatory stream, it is accepted and projected.
- If the snapshot belongs to another user goal, the projection fails with `{:error, {:lease_dependency_not_found, grant_id}}`.
- Strict goal ownership remains fully enforced for all other entities (runs, tasks, checkpoints, and artifacts).
