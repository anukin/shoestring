defmodule Shoestring.Harness.Observatory do
  @moduledoc """
  Durable capacity observatory sink and provider-neutral observation ledger.

  Preserves the non-null goal-scoped trajectory architecture by providing a
  single, protected internal singleton goal under which provider capacity
  observations are canonically recorded as `capacity.snapshot_observed` v2 events.

  ## Architecture & Ingestion Lifecycle

  1. **Singleton Observatory Goal**: A well-known protected goal
     (`@observatory_goal_id`) serves as the durable event stream for all
     provider capacity observations.
  2. **Bounded Deduplication**: High-frequency equivalent readings do not grow
     the ledger. If usage, window reset, reason, provenance, support tier,
     compatibility, refusal, or freshness state changes, the reading is persisted.
  3. **Projection**: Ingested events are immediately projected into
     `harness_capacity_snapshots` and `harness_capacity_windows` under the
     observatory goal.
  4. **Query Surface**: Neutral queries expose latest observations per scope,
     freshness, age, diagnostic reasons, and fail-closed automation eligibility
     via `CapacitySnapshot.eligible?/2`.
  5. **Cross-Goal Lease Reference**: User execution leases may safely reference
     admitted capacity snapshots owned by this observatory stream, while strict
     goal ownership is preserved for all other entities.
  """

  import Ecto.Query

  alias Shoestring.Harness.{
    CapacitySnapshot,
    CapacitySnapshotRecord,
    Projector
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.Goal

  @observatory_goal_id "00000000-0000-4000-8000-000000000cb0"
  @observatory_owner_id "00000000-0000-4000-8000-0000000000cb"
  @observatory_title "Capacity Observatory"
  @observatory_description "Protected singleton capacity observatory"
  @observatory_status "protected"

  @type deduplication_key :: {String.t(), String.t(), String.t()}

  @type window_summary :: %{
          kind: String.t(),
          state: :observed | :unknown,
          used_percent: float() | nil,
          reset_at: DateTime.t() | nil,
          reason: String.t() | nil
        }

  @type observation_summary :: %{
          provider_id: String.t(),
          invocation_mode: String.t(),
          adapter_id: String.t(),
          event: atom(),
          scope: String.t(),
          capacity_state: :observed | :degraded | :refused | :unknown,
          windows: [window_summary()],
          freshness_state: :fresh | :stale | :unknown,
          age_seconds: non_neg_integer() | nil,
          max_age_seconds: pos_integer(),
          observed_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          confidence: atom(),
          compatibility_state: atom(),
          support_tier: atom(),
          reason: String.t() | nil,
          eligible?: boolean(),
          snapshot: CapacitySnapshot.t()
        }

  @doc "The well-known UUIDv4 of the protected observatory singleton goal."
  @spec observatory_goal_id() :: Ecto.UUID.t()
  def observatory_goal_id, do: @observatory_goal_id

  @doc "The well-known UUIDv4 of the protected observatory system owner."
  @spec observatory_owner_id() :: Ecto.UUID.t()
  def observatory_owner_id, do: @observatory_owner_id

  @doc "The canonical title of the singleton observatory goal."
  @spec observatory_title() :: String.t()
  def observatory_title, do: @observatory_title

  @doc "The canonical description of the singleton observatory goal."
  @spec observatory_description() :: String.t()
  def observatory_description, do: @observatory_description

  @doc "The protected status flag of the singleton observatory goal."
  @spec observatory_status() :: String.t()
  def observatory_status, do: @observatory_status

  @doc "Returns true if the given goal or ID is the observatory singleton."
  @spec observatory_goal?(Goal.t() | Ecto.UUID.t() | nil) :: boolean()
  def observatory_goal?(%Goal{id: id}), do: id == @observatory_goal_id
  def observatory_goal?(%Goal{status: "protected"}), do: true
  def observatory_goal?(id) when is_binary(id), do: id == @observatory_goal_id
  def observatory_goal?(_other), do: false

  @doc """
  Idempotently provisions the observatory goal in the database if not present.
  Survives restarts and uses standard repository schema conventions.
  """
  @spec ensure_provisioned(keyword()) :: {:ok, Goal.t()} | {:error, term()}
  def ensure_provisioned(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(Goal, @observatory_goal_id) do
      %Goal{} = goal ->
        {:ok, goal}

      nil ->
        now = DateTime.utc_now()

        goal = %Goal{
          id: @observatory_goal_id,
          owner_id: @observatory_owner_id,
          title: @observatory_title,
          description: @observatory_description,
          status: @observatory_status,
          inserted_at: now,
          updated_at: now
        }

        case repo.insert(goal, on_conflict: :nothing) do
          {:ok, inserted} ->
            {:ok, inserted}

          {:error, _changeset} ->
            case repo.get(Goal, @observatory_goal_id) do
              %Goal{} = existing -> {:ok, existing}
              nil -> {:error, :observatory_provisioning_failed}
            end
        end
    end
  end

  @doc """
  Ingests a validated CapacitySnapshot v2 into the shared observatory ledger.

  Performs bounded semantic deduplication against the latest observation for the
  matching `{provider_id, invocation_mode, scope}`. If the reading is equivalent,
  it returns `{:ok, :deduplicated, existing_snapshot}` without appending to the ledger.
  If the reading has changed (usage, resets, reason, refusal, provenance, or freshness
  transition), it appends a canonical `capacity.snapshot_observed` v2 event under the
  observatory goal, projects the event into snapshot/window records, and returns
  `{:ok, :persisted, snapshot}`.
  """
  @spec ingest(CapacitySnapshot.t() | map(), keyword()) ::
          {:ok, :persisted, CapacitySnapshot.t()}
          | {:ok, :deduplicated, CapacitySnapshot.t()}
          | {:error, term()}
  def ingest(snapshot_or_attrs, opts \\ [])

  def ingest(%CapacitySnapshot{} = snapshot, opts) do
    do_ingest(snapshot, opts)
  end

  def ingest(attrs, opts) when is_map(attrs) do
    result =
      if Enum.any?(Map.keys(attrs), &is_binary/1) do
        CapacitySnapshot.from_payload(attrs, opts)
      else
        CapacitySnapshot.new(attrs, opts)
      end

    case result do
      {:ok, %CapacitySnapshot{} = snapshot} ->
        do_ingest(snapshot, opts)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp do_ingest(%CapacitySnapshot{version: 2} = snapshot, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, _goal} <- ensure_provisioned(opts) do
      case get_latest_observation(
             snapshot.source.provider_id,
             snapshot.source.invocation_mode,
             snapshot.scope,
             opts
           ) do
        %CapacitySnapshot{} = latest ->
          if equivalent?(snapshot, latest, now) do
            {:ok, :deduplicated, latest}
          else
            persist_snapshot_event(snapshot, opts)
          end

        nil ->
          persist_snapshot_event(snapshot, opts)
      end
    end
  end

  defp do_ingest(%CapacitySnapshot{version: version}, _opts) do
    {:error, {:unsupported_snapshot_version, version}}
  end

  defp persist_snapshot_event(%CapacitySnapshot{} = snapshot, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

    occurred_at = snapshot.observed_at || now

    event_attrs = %{
      "type" => "capacity.snapshot_observed",
      "schema_version" => 2,
      "actor" => Keyword.get(opts, :actor, "capacity_observatory"),
      "occurred_at" => occurred_at,
      "idempotency_key" => "capacity-observed:#{snapshot.snapshot_id}",
      "payload" => snapshot_to_payload(snapshot)
    }

    trajectory_opts = [
      writer_opts: Keyword.get(opts, :writer_opts, [])
    ]

    with {:ok, _event} <-
           Trajectory.append(@observatory_goal_id, event_attrs, trajectory_opts),
         {:ok, _position} <-
           Projector.project(@observatory_goal_id, clock: clock) do
      {:ok, :persisted, snapshot}
    end
  end

  @doc """
  Computes the deduplication key for an observation.
  Identifies the `{provider_id, invocation_mode, scope}` boundary.
  """
  @spec deduplication_key(CapacitySnapshot.t()) :: deduplication_key()
  def deduplication_key(%CapacitySnapshot{} = snapshot) do
    {snapshot.source.provider_id, snapshot.source.invocation_mode, snapshot.scope}
  end

  @doc """
  Evaluates whether two observations are semantically equivalent.

  Returns true only if:
  - Capacity state, confidence, support tier, compatibility state, and reason match
  - Provenance (adapter_id, provider_id, invocation_mode, source event) matches
  - Freshness max_age_seconds matches
  - Windows are identical (kind, state, used_percent, reset_at, unknown_reason)
  - Freshness state at the evaluated time (`now`) has not transitioned (e.g. fresh -> stale)
  - Extensions match
  """
  @spec equivalent?(CapacitySnapshot.t(), CapacitySnapshot.t(), DateTime.t()) :: boolean()
  def equivalent?(%CapacitySnapshot{} = a, %CapacitySnapshot{} = b, %DateTime{} = now) do
    a.capacity_state == b.capacity_state and
      a.confidence == b.confidence and
      a.support_tier == b.support_tier and
      a.compatibility_state == b.compatibility_state and
      a.reason == b.reason and
      sources_match?(a.source, b.source) and
      freshness_settings_match?(a.freshness, b.freshness) and
      windows_equivalent?(a.windows, b.windows) and
      extensions_match?(a.extensions, b.extensions) and
      CapacitySnapshot.freshness(a, now) == CapacitySnapshot.freshness(b, now)
  end

  def equivalent?(%CapacitySnapshot{} = a, %CapacitySnapshot{} = b) do
    equivalent?(a, b, DateTime.utc_now())
  end

  defp sources_match?(s1, s2) do
    s1.adapter_id == s2.adapter_id and
      s1.provider_id == s2.provider_id and
      s1.invocation_mode == s2.invocation_mode and
      s1.event == s2.event
  end

  defp freshness_settings_match?(f1, f2) do
    f1.max_age_seconds == f2.max_age_seconds
  end

  defp extensions_match?(e1, e2) do
    (e1 || %{}) == (e2 || %{})
  end

  defp windows_equivalent?(windows_a, windows_b) when is_list(windows_a) and is_list(windows_b) do
    length(windows_a) == length(windows_b) and
      sorted_windows_match?(
        Enum.sort_by(windows_a, & &1.kind),
        Enum.sort_by(windows_b, & &1.kind)
      )
  end

  defp windows_equivalent?(_a, _b), do: false

  defp sorted_windows_match?([], []), do: true

  defp sorted_windows_match?([wa | rest_a], [wb | rest_b]) do
    window_match?(wa, wb) and sorted_windows_match?(rest_a, rest_b)
  end

  defp sorted_windows_match?(_a, _b), do: false

  defp window_match?(%{kind: k, state: :observed} = a, %{kind: k, state: :observed} = b) do
    numbers_equal?(Map.get(a, :used_percent), Map.get(b, :used_percent)) and
      datetimes_equal?(Map.get(a, :reset_at), Map.get(b, :reset_at))
  end

  defp window_match?(%{kind: k, state: :unknown} = a, %{kind: k, state: :unknown} = b) do
    Map.get(a, :reason) == Map.get(b, :reason)
  end

  defp window_match?(_a, _b), do: false

  defp numbers_equal?(nil, nil), do: true
  defp numbers_equal?(a, b) when is_number(a) and is_number(b), do: abs(a - b) < 0.0001
  defp numbers_equal?(_a, _b), do: false

  defp datetimes_equal?(nil, nil), do: true

  defp datetimes_equal?(%DateTime{} = a, %DateTime{} = b) do
    DateTime.compare(a, b) == :eq
  end

  defp datetimes_equal?(_a, _b), do: false

  @doc """
  Fetches the latest observation for a specific provider, mode, and scope.
  Returns `{:ok, snapshot}` or `{:error, :not_found}`.
  """
  @spec latest_observation(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, CapacitySnapshot.t()} | {:error, :not_found}
  def latest_observation(provider_id, invocation_mode, scope, opts \\ []) do
    case get_latest_observation(provider_id, invocation_mode, scope, opts) do
      %CapacitySnapshot{} = snapshot -> {:ok, snapshot}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Fetches the latest observation for a specific provider, mode, and scope.
  Returns `%CapacitySnapshot{}` or `nil` if not found.
  """
  @spec get_latest_observation(String.t(), String.t(), String.t(), keyword()) ::
          CapacitySnapshot.t() | nil
  def get_latest_observation(provider_id, invocation_mode, scope, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    query =
      from snapshot in CapacitySnapshotRecord,
        where:
          snapshot.goal_id == ^@observatory_goal_id and
            snapshot.source_provider_id == ^to_string(provider_id) and
            snapshot.source_invocation_mode == ^to_string(invocation_mode) and
            snapshot.scope == ^to_string(scope),
        order_by: [desc: snapshot.projection_sequence, desc: snapshot.inserted_at],
        limit: 1,
        preload: [:windows]

    case repo.one(query) do
      nil -> nil
      %CapacitySnapshotRecord{} = record -> record_to_snapshot(record, opts)
    end
  end

  @doc """
  Returns the latest observation across all distinct provider/mode/scope targets.
  """
  @spec latest_observations(keyword()) :: [CapacitySnapshot.t()]
  def latest_observations(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    query =
      from snapshot in CapacitySnapshotRecord,
        where: snapshot.goal_id == ^@observatory_goal_id,
        order_by: [desc: snapshot.projection_sequence, desc: snapshot.inserted_at],
        preload: [:windows]

    repo.all(query)
    |> Enum.uniq_by(fn s -> {s.source_provider_id, s.source_invocation_mode, s.scope} end)
    |> Enum.map(&record_to_snapshot(&1, opts))
  end

  @doc """
  Produces a comprehensive observation summary for monitors, telemetry, and LiveView.

  Computes freshness, elapsed age, windows (preserving nil for unknown without fake 0%),
  and fail-closed automation eligibility via `CapacitySnapshot.eligible?/2`.
  """
  @spec observation_summary(CapacitySnapshot.t(), keyword()) :: observation_summary()
  def observation_summary(%CapacitySnapshot{} = snapshot, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    freshness_state = CapacitySnapshot.freshness(snapshot, now)

    age_seconds =
      case snapshot.observed_at do
        %DateTime{} = observed_at ->
          case DateTime.diff(now, observed_at, :second) do
            diff when diff >= 0 -> diff
            _future -> nil
          end

        nil ->
          nil
      end

    windows =
      Enum.map(snapshot.windows, fn window ->
        %{
          kind: window.kind,
          state: window.state,
          used_percent: Map.get(window, :used_percent),
          reset_at: Map.get(window, :reset_at),
          reason: Map.get(window, :reason)
        }
      end)

    %{
      provider_id: snapshot.source.provider_id,
      invocation_mode: snapshot.source.invocation_mode,
      adapter_id: snapshot.source.adapter_id,
      event: snapshot.source.event,
      scope: snapshot.scope,
      capacity_state: snapshot.capacity_state,
      windows: windows,
      freshness_state: freshness_state,
      age_seconds: age_seconds,
      max_age_seconds: snapshot.freshness.max_age_seconds,
      observed_at: snapshot.observed_at,
      expires_at: snapshot.expires_at,
      confidence: snapshot.confidence,
      compatibility_state: snapshot.compatibility_state,
      support_tier: snapshot.support_tier,
      reason: snapshot.reason,
      eligible?: CapacitySnapshot.eligible?(snapshot, now),
      snapshot: snapshot
    }
  end

  @doc """
  Decodes a stored `CapacitySnapshotRecord` and its associated `windows` into a
  canonical `CapacitySnapshot.t()`. Preserves true original observation timestamp and age.
  """
  @spec record_to_snapshot(CapacitySnapshotRecord.t(), keyword()) :: CapacitySnapshot.t()
  def record_to_snapshot(%CapacitySnapshotRecord{} = record, _opts \\ []) do
    windows =
      Enum.map(record.windows || [], fn window ->
        case window.state do
          "observed" ->
            %{
              "kind" => window.kind,
              "state" => "observed",
              "used_percent" => window.used_percent,
              "reset_at" => window.reset_at && DateTime.to_iso8601(window.reset_at)
            }
            |> reject_nil_values()

          "unknown" ->
            %{
              "kind" => window.kind,
              "state" => "unknown",
              "reason" => window.unknown_reason
            }
        end
      end)

    payload = %{
      "snapshot_id" => record.id,
      "contract_version" => record.contract_version,
      "capacity_state" => record.capacity_state,
      "windows" => %{"items" => windows},
      "observed_at" => record.observed_at && DateTime.to_iso8601(record.observed_at),
      "expires_at" => record.expires_at && DateTime.to_iso8601(record.expires_at),
      "freshness" => %{
        "max_age_seconds" => record.freshness_max_age_seconds
      },
      "source" => %{
        "adapter_id" => record.source_adapter_id,
        "provider_id" => record.source_provider_id,
        "invocation_mode" => record.source_invocation_mode,
        "event" => record.source_event
      },
      "scope" => record.scope,
      "confidence" => record.confidence,
      "support_tier" => record.support_tier,
      "compatibility_state" => record.compatibility_state,
      "reason" => record.reason,
      "extensions" => record.extensions || %{}
    }

    validation_opts = [now: record.observed_at || record.inserted_at || DateTime.utc_now()]

    case CapacitySnapshot.from_payload(payload, validation_opts) do
      {:ok, snapshot} ->
        snapshot

      {:error, changeset} ->
        raise "Invalid stored capacity snapshot #{record.id}: #{inspect(changeset)}"
    end
  end

  defp snapshot_to_payload(%CapacitySnapshot{} = snapshot) do
    payload = %{
      "snapshot_id" => snapshot.snapshot_id,
      "contract_version" => snapshot.version,
      "capacity_state" => Atom.to_string(snapshot.capacity_state),
      "windows" => %{
        "items" =>
          Enum.map(snapshot.windows, fn window ->
            case window.state do
              :observed ->
                %{
                  "kind" => window.kind,
                  "state" => "observed",
                  "used_percent" => window.used_percent,
                  "reset_at" => window.reset_at && DateTime.to_iso8601(window.reset_at)
                }
                |> reject_nil_values()

              :unknown ->
                %{
                  "kind" => window.kind,
                  "state" => "unknown",
                  "reason" => window.reason
                }
            end
          end)
      },
      "freshness" => %{
        "max_age_seconds" => snapshot.freshness.max_age_seconds
      },
      "source" => %{
        "adapter_id" => snapshot.source.adapter_id,
        "provider_id" => snapshot.source.provider_id,
        "invocation_mode" => snapshot.source.invocation_mode,
        "event" => Atom.to_string(snapshot.source.event)
      },
      "scope" => snapshot.scope,
      "confidence" => Atom.to_string(snapshot.confidence),
      "support_tier" => Atom.to_string(snapshot.support_tier),
      "compatibility_state" => Atom.to_string(snapshot.compatibility_state),
      "extensions" => snapshot.extensions || %{}
    }

    payload
    |> put_optional(
      "observed_at",
      snapshot.observed_at && DateTime.to_iso8601(snapshot.observed_at)
    )
    |> put_optional("expires_at", snapshot.expires_at && DateTime.to_iso8601(snapshot.expires_at))
    |> put_optional("reason", snapshot.reason)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp reject_nil_values(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
