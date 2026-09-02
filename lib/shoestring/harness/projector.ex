defmodule Shoestring.Harness.Projector do
  @moduledoc "Rebuildable harness projections derived from canonical trajectory events."

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias Shoestring.Harness.{
    CapacitySnapshotRecord,
    CapacitySnapshot,
    CapacityWindowRecord,
    CheckpointArtifactReference,
    CheckpointRecord,
    Clock,
    ExecutionLeaseRecord,
    Identifier,
    LeaseStateMachine,
    ProjectorTransition,
    RunRecord,
    RunStateMachine
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Artifact, EventRegistry, ProjectorPosition, TrajectoryEvent}

  @projector "harness"
  @version 1

  @spec name() :: String.t()
  def name, do: @projector

  @spec version() :: 1
  def version, do: @version

  @spec project(Ecto.UUID.t(), keyword()) :: {:ok, ProjectorPosition.t()} | {:error, term()}
  def project(goal_id, opts \\ []) do
    with {:ok, goal_id} <- cast_uuid(goal_id) do
      do_project(goal_id, opts, 0)
    end
  end

  @spec rebuild(Ecto.UUID.t(), keyword()) :: {:ok, ProjectorPosition.t()} | {:error, term()}
  def rebuild(goal_id, opts \\ []) do
    with {:ok, goal_id} <- cast_uuid(goal_id),
         {:ok, :ok} <- Repo.transaction(fn -> reset_derived_state(goal_id, opts) end) do
      project(goal_id, opts)
    end
  end

  @doc "Pure replay used to verify that lifecycle projections can be reconstructed."
  @spec replay_events([TrajectoryEvent.t()]) ::
          {:ok, ProjectorTransition.state()} | {:error, term()}
  def replay_events(events) when is_list(events) do
    events
    |> Enum.reduce_while(
      {:ok, %{state: ProjectorTransition.initial_state(), sequence: 0}},
      fn event, {:ok, acc} ->
        expected = acc.sequence + 1

        if event.sequence == expected do
          with {:ok, validated} <- EventRegistry.validate(event_attributes(event)),
               {:ok, payload} <-
                 EventRegistry.upcast(event.type, event.schema_version, validated.payload,
                   now: event.occurred_at
                 ),
               {:ok, state} <- ProjectorTransition.apply(acc.state, %{event | payload: payload}) do
            {:cont, {:ok, %{state: state, sequence: event.sequence}}}
          else
            {:error, error} -> {:halt, {:error, error}}
          end
        else
          {:halt, {:error, {:event_order, event.sequence, expected}}}
        end
      end
    )
    |> case do
      {:ok, %{state: state}} -> {:ok, state}
      error -> error
    end
  end

  defp do_project(goal_id, opts, applied) do
    case apply_next(goal_id, opts) do
      {:ok, :done, position} ->
        {:ok, position}

      {:ok, :applied, position} ->
        if reached_limit?(opts, applied + 1) do
          {:ok, position}
        else
          do_project(goal_id, opts, applied + 1)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp apply_next(goal_id, opts) do
    case Repo.transaction(fn -> apply_next_in_transaction(goal_id, opts) end) do
      {:ok, {:done, position}} -> {:ok, :done, position}
      {:ok, {:applied, position}} -> {:ok, :applied, position}
      {:ok, {:failed, error}} -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  defp apply_next_in_transaction(goal_id, opts) do
    position = load_or_create_position(goal_id, opts)

    cond do
      position.status == "failed" ->
        {:failed, failure_from_position(position)}

      position.version != @version ->
        fail(
          position,
          position.last_sequence + 1,
          {:projector_version_mismatch, @projector, position.version, @version},
          opts
        )

      true ->
        expected = position.last_sequence + 1

        case Repo.one(
               from event in TrajectoryEvent,
                 where: event.goal_id == ^goal_id and event.sequence == ^expected
             ) do
          nil ->
            if Repo.exists?(
                 from event in TrajectoryEvent,
                   where: event.goal_id == ^goal_id and event.sequence > ^expected
               ) do
              fail(position, expected, {:sequence_gap, expected}, opts)
            else
              {:done, position}
            end

          event ->
            apply_event(position, event, opts)
        end
    end
  end

  defp apply_event(position, event, opts) do
    with {:ok, validated} <- EventRegistry.validate(event_attributes(event)),
         {:ok, payload} <-
           EventRegistry.upcast(event.type, event.schema_version, validated.payload,
             now: event.occurred_at
           ),
         :ok <- persist_event(event, payload, opts),
         {:ok, position} <- advance(position, event.sequence, opts) do
      {:applied, position}
    else
      {:error, error} -> fail(position, event.sequence, error, opts)
    end
  end

  defp persist_event(event, payload, opts) do
    case ProjectorTransition.action(event.type) do
      {:run, action} -> persist_run(event, payload, action)
      {:lease, action} -> persist_lease(event, payload, action, opts)
      :checkpoint -> persist_checkpoint(event, payload, opts)
      :capacity_snapshot -> persist_capacity_snapshot(event, payload, opts)
      :ignore -> :ok
    end
  end

  defp persist_run(event, payload, :request) do
    with {:ok, run_id} <- payload_uuid(payload, "run_id"),
         :ok <- matching_run_id(event, run_id),
         %RunRecord{} = run <- Repo.get_by(RunRecord, id: run_id, goal_id: event.goal_id) do
      update_run_projection(
        run,
        :requested,
        Map.get(payload, "provider_session_id"),
        event.sequence,
        event.occurred_at
      )
    else
      nil -> {:error, {:run_not_found, Map.get(payload, "run_id")}}
      error -> error
    end
  end

  defp persist_run(event, payload, action) do
    with {:ok, run_id} <- payload_uuid(payload, "run_id"),
         :ok <- matching_run_id(event, run_id),
         %RunRecord{} = run <- Repo.get_by(RunRecord, id: run_id, goal_id: event.goal_id),
         {:ok, transition} <- RunStateMachine.transition(status_atom(run.status), action) do
      session_id = Map.get(payload, "provider_session_id") || run.provider_session_id
      update_run_projection(run, transition.state, session_id, event.sequence, event.occurred_at)
    else
      nil -> {:error, {:run_not_found, Map.get(payload, "run_id")}}
      error -> error
    end
  end

  defp persist_lease(event, payload, :propose, opts) do
    with {:ok, grant_id} <- payload_uuid(payload, "grant_id"),
         {:ok, run_id} <- payload_uuid(payload, "run_id"),
         {:ok, snapshot_id} <- payload_uuid(payload, "admitted_snapshot_id"),
         :ok <- matching_run_id(event, run_id),
         %RunRecord{} <- Repo.get_by(RunRecord, id: run_id, goal_id: event.goal_id),
         %CapacitySnapshotRecord{} <-
           Repo.get_by(CapacitySnapshotRecord, id: snapshot_id, goal_id: event.goal_id) do
      case Repo.get(ExecutionLeaseRecord, grant_id) do
        nil -> insert_lease(event, payload, grant_id, run_id, snapshot_id, opts)
        %ExecutionLeaseRecord{goal_id: goal_id} when goal_id == event.goal_id -> :ok
        _lease -> {:error, {:lease_not_owned, grant_id}}
      end
    else
      nil -> {:error, {:lease_dependency_not_found, Map.get(payload, "grant_id")}}
      error -> error
    end
  end

  defp persist_lease(event, payload, action, _opts) do
    with {:ok, grant_id} <- payload_uuid(payload, "grant_id"),
         %ExecutionLeaseRecord{goal_id: goal_id} = lease <-
           Repo.get(ExecutionLeaseRecord, grant_id),
         true <- goal_id == event.goal_id,
         {:ok, transition} <- LeaseStateMachine.transition(status_atom(lease.status), action) do
      lease
      |> ExecutionLeaseRecord.changeset(%{
        "status" => Atom.to_string(transition.state),
        "renewal_state" => renewal_state(action, lease.renewal_state),
        "projection_sequence" => event.sequence,
        "updated_at" => event.occurred_at
      })
      |> Repo.update()
      |> result_to_ok()
    else
      nil -> {:error, {:lease_not_found, Map.get(payload, "grant_id")}}
      false -> {:error, {:lease_not_owned, Map.get(payload, "grant_id")}}
      error -> error
    end
  end

  defp persist_checkpoint(event, payload, opts) do
    with {:ok, checkpoint_id} <- payload_uuid(payload, "checkpoint_id"),
         {:ok, run_id} <- payload_uuid(payload, "run_id"),
         :ok <- matching_run_id(event, run_id),
         %RunRecord{} <- Repo.get_by(RunRecord, id: run_id, goal_id: event.goal_id) do
      case Repo.get(CheckpointRecord, checkpoint_id) do
        nil -> insert_checkpoint(event, payload, checkpoint_id, run_id, opts)
        %CheckpointRecord{goal_id: goal_id} when goal_id == event.goal_id -> :ok
        _checkpoint -> {:error, {:checkpoint_not_owned, checkpoint_id}}
      end
    else
      nil -> {:error, {:run_not_found, Map.get(payload, "run_id")}}
      error -> error
    end
  end

  defp persist_capacity_snapshot(event, payload, opts) do
    with {:ok, snapshot_id} <- payload_uuid(payload, "snapshot_id"),
         {:ok, run_id} <- optional_payload_uuid(payload, "run_id"),
         :ok <- optional_matching_run_id(event, run_id),
         :ok <- optional_run_owner(event.goal_id, run_id) do
      case Repo.get(CapacitySnapshotRecord, snapshot_id) do
        nil -> insert_capacity_snapshot(event, payload, snapshot_id, run_id, opts)
        %CapacitySnapshotRecord{goal_id: goal_id} when goal_id == event.goal_id -> :ok
        _snapshot -> {:error, {:capacity_snapshot_not_owned, snapshot_id}}
      end
    end
  end

  defp insert_lease(event, payload, grant_id, run_id, snapshot_id, _opts) do
    reserves = Map.fetch!(payload, "reserves")

    %ExecutionLeaseRecord{
      id: grant_id,
      goal_id: event.goal_id,
      run_id: run_id,
      admitted_snapshot_id: snapshot_id,
      inserted_at: event.occurred_at,
      updated_at: event.occurred_at
    }
    |> ExecutionLeaseRecord.changeset(%{
      "contract_version" => Map.fetch!(payload, "contract_version"),
      "response_reserve" => map_value(reserves, "response"),
      "tool_reserve" => map_value(reserves, "tool"),
      "response_budget" => Map.fetch!(payload, "response_budget"),
      "tool_budget" => Map.fetch!(payload, "tool_budget"),
      "deadline" => Map.fetch!(payload, "deadline"),
      "checkpoint_cadence" => Map.fetch!(payload, "checkpoint_cadence"),
      "renewal_state" => Map.fetch!(payload, "renewal_state"),
      "status" => "proposed",
      "extensions" => Map.fetch!(payload, "extensions"),
      "projection_sequence" => event.sequence
    })
    |> Repo.insert()
    |> result_to_ok()
  end

  defp insert_checkpoint(event, payload, checkpoint_id, run_id, _opts) do
    checkpoint =
      %CheckpointRecord{
        id: checkpoint_id,
        goal_id: event.goal_id,
        run_id: run_id,
        inserted_at: event.occurred_at,
        updated_at: event.occurred_at
      }
      |> CheckpointRecord.changeset(%{
        "contract_version" => Map.fetch!(payload, "contract_version"),
        "acceptance_contract" => Map.fetch!(payload, "acceptance_contract"),
        "repository_state" => Map.fetch!(payload, "repository_state"),
        "evidence" => Map.fetch!(payload, "evidence"),
        "decisions" => Map.fetch!(payload, "decisions"),
        "unresolved_issues" => Map.fetch!(payload, "unresolved_issues"),
        "next_action" => Map.fetch!(payload, "next_action"),
        "provider_session_id" => Map.get(payload, "provider_session_id"),
        "stop_reason" => Map.fetch!(payload, "stop_reason"),
        "extensions" => Map.fetch!(payload, "extensions"),
        "projection_sequence" => event.sequence
      })

    with {:ok, checkpoint} <- Repo.insert(checkpoint),
         :ok <- insert_artifact_references(checkpoint, payload, event.goal_id) do
      :ok
    end
  end

  defp insert_artifact_references(checkpoint, payload, goal_id) do
    payload
    |> Map.fetch!("artifact_ids")
    |> map_items()
    |> Enum.reduce_while(:ok, fn artifact_id, :ok ->
      if Repo.exists?(
           from artifact in Artifact,
             where: artifact.id == ^artifact_id and artifact.goal_id == ^goal_id
         ) do
        case Repo.insert(
               CheckpointArtifactReference.changeset(
                 %CheckpointArtifactReference{},
                 checkpoint.id,
                 artifact_id
               )
             ) do
          {:ok, _reference} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      else
        {:halt, {:error, {:artifact_not_owned, artifact_id}}}
      end
    end)
  end

  defp insert_capacity_snapshot(event, payload, snapshot_id, run_id, opts) do
    with {:ok, capacity_snapshot} <-
           CapacitySnapshot.from_payload(payload, now: event.occurred_at) do
      snapshot =
        %CapacitySnapshotRecord{
          id: snapshot_id,
          goal_id: event.goal_id,
          run_id: run_id,
          inserted_at: event.occurred_at,
          updated_at: event.occurred_at
        }
        |> CapacitySnapshotRecord.changeset(%{
          "contract_version" => capacity_snapshot.version,
          "capacity_state" => Atom.to_string(capacity_snapshot.capacity_state),
          "legacy_capacity_state" => legacy_capacity_state(capacity_snapshot.capacity_state),
          "observed_at" => capacity_snapshot.observed_at,
          "legacy_observed_at" => capacity_snapshot.observed_at || event.occurred_at,
          "expires_at" => capacity_snapshot.expires_at,
          "freshness_max_age_seconds" => capacity_snapshot.freshness.max_age_seconds,
          "source_adapter_id" => capacity_snapshot.source.adapter_id,
          "source_method" => Atom.to_string(capacity_snapshot.source.event),
          "source_provider_id" => capacity_snapshot.source.provider_id,
          "source_invocation_mode" => capacity_snapshot.source.invocation_mode,
          "source_event" => Atom.to_string(capacity_snapshot.source.event),
          "scope" => capacity_snapshot.scope,
          "confidence" => Atom.to_string(capacity_snapshot.confidence),
          "support_tier" => Atom.to_string(capacity_snapshot.support_tier),
          "compatibility_state" => Atom.to_string(capacity_snapshot.compatibility_state),
          "reason" => capacity_snapshot.reason,
          "extensions" => capacity_snapshot.extensions,
          "projection_sequence" => event.sequence
        })

      with {:ok, snapshot} <- Repo.insert(snapshot),
           :ok <- insert_capacity_windows(snapshot, capacity_snapshot.windows, event, opts) do
        :ok
      end
    end
  end

  defp insert_capacity_windows(snapshot, windows, event, opts) do
    windows
    |> Enum.reduce_while(:ok, fn window, :ok ->
      attrs = %{
        "kind" => window.kind,
        "state" => Atom.to_string(window.state),
        "legacy_state" => legacy_window_state(snapshot.capacity_state, window.state),
        "used_percent" => Map.get(window, :used_percent),
        "reset_at" => Map.get(window, :reset_at),
        "unknown_reason" => Map.get(window, :reason)
      }

      window = %CapacityWindowRecord{
        id:
          Identifier.generate(Keyword.get(opts, :identifier, Shoestring.Harness.SystemIdentifier)),
        snapshot_id: snapshot.id,
        inserted_at: event.occurred_at,
        updated_at: event.occurred_at
      }

      case Repo.insert(CapacityWindowRecord.changeset(window, attrs)) do
        {:ok, _window} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp update_run_projection(run, status, session_id, sequence, occurred_at) do
    run
    |> RunRecord.projection_changeset(%{
      "status" => Atom.to_string(status),
      "provider_session_id" => session_id,
      "projection_sequence" => sequence,
      "updated_at" => occurred_at
    })
    |> Repo.update()
    |> result_to_ok()
  end

  defp reset_derived_state(goal_id, opts) do
    Repo.delete_all(
      from reference in CheckpointArtifactReference,
        where:
          reference.checkpoint_id in subquery(
            from checkpoint in CheckpointRecord,
              where: checkpoint.goal_id == ^goal_id,
              select: checkpoint.id
          )
    )

    Repo.delete_all(from checkpoint in CheckpointRecord, where: checkpoint.goal_id == ^goal_id)
    Repo.delete_all(from lease in ExecutionLeaseRecord, where: lease.goal_id == ^goal_id)

    Repo.delete_all(
      from window in CapacityWindowRecord,
        where:
          window.snapshot_id in subquery(
            from snapshot in CapacitySnapshotRecord,
              where: snapshot.goal_id == ^goal_id,
              select: snapshot.id
          )
    )

    Repo.delete_all(from snapshot in CapacitySnapshotRecord, where: snapshot.goal_id == ^goal_id)

    Repo.update_all(
      from(run in RunRecord, where: run.goal_id == ^goal_id),
      set: [status: "requested", provider_session_id: nil, projection_sequence: 0]
    )

    now = Clock.now(Keyword.get(opts, :clock, Shoestring.Harness.SystemClock))

    case Repo.get_by(ProjectorPosition, goal_id: goal_id, projector: @projector) do
      nil ->
        :ok

      position ->
        position
        |> change(
          version: @version,
          last_sequence: 0,
          status: "ok",
          error_detail: nil,
          updated_at: now
        )
        |> Repo.update!()
    end

    :ok
  end

  defp load_or_create_position(goal_id, opts) do
    case Repo.get_by(ProjectorPosition, goal_id: goal_id, projector: @projector) do
      %ProjectorPosition{} = position ->
        position

      nil ->
        now = Clock.now(Keyword.get(opts, :clock, Shoestring.Harness.SystemClock))

        %ProjectorPosition{
          id:
            Identifier.generate(
              Keyword.get(opts, :identifier, Shoestring.Harness.SystemIdentifier)
            ),
          goal_id: goal_id,
          projector: @projector,
          version: @version,
          last_sequence: 0,
          status: "ok",
          inserted_at: now,
          updated_at: now
        }
        |> Repo.insert!()
    end
  end

  defp advance(position, sequence, opts) do
    position
    |> change(
      last_sequence: sequence,
      status: "ok",
      error_detail: nil,
      updated_at: Clock.now(Keyword.get(opts, :clock, Shoestring.Harness.SystemClock))
    )
    |> Repo.update()
  end

  defp fail(position, sequence, error, opts) do
    position =
      position
      |> change(
        status: "failed",
        error_detail: encode_failure(error),
        updated_at: Clock.now(Keyword.get(opts, :clock, Shoestring.Harness.SystemClock))
      )
      |> Repo.update!()

    {:failed, {:harness_projection_failed, sequence, error, position}}
  end

  defp failure_from_position(position) do
    {:harness_projection_failed, position.last_sequence + 1,
     decode_failure(position.error_detail), position}
  end

  defp payload_uuid(payload, key) do
    case Ecto.UUID.cast(Map.get(payload, key)) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:invalid_payload_uuid, key}}
    end
  end

  defp optional_payload_uuid(payload, key) do
    case Map.get(payload, key) do
      nil -> {:ok, nil}
      value -> payload_uuid(%{key => value}, key)
    end
  end

  defp matching_run_id(%TrajectoryEvent{run_id: nil}, _run_id), do: :ok
  defp matching_run_id(%TrajectoryEvent{run_id: run_id}, run_id), do: :ok
  defp matching_run_id(_event, _run_id), do: {:error, :run_id_mismatch}
  defp optional_matching_run_id(_event, nil), do: :ok
  defp optional_matching_run_id(event, run_id), do: matching_run_id(event, run_id)

  defp optional_run_owner(_goal_id, nil), do: :ok

  defp optional_run_owner(goal_id, run_id) do
    if Repo.exists?(from run in RunRecord, where: run.id == ^run_id and run.goal_id == ^goal_id) do
      :ok
    else
      {:error, {:run_not_found, run_id}}
    end
  end

  defp status_atom("requested"), do: :requested
  defp status_atom("starting"), do: :starting
  defp status_atom("running"), do: :running
  defp status_atom("pausing"), do: :pausing
  defp status_atom("suspended"), do: :suspended
  defp status_atom("completed"), do: :completed
  defp status_atom("failed"), do: :failed
  defp status_atom("cancelling"), do: :cancelling
  defp status_atom("cancelled"), do: :cancelled
  defp status_atom("proposed"), do: :proposed
  defp status_atom("granted"), do: :granted
  defp status_atom("active"), do: :active
  defp status_atom("renewal_due"), do: :renewal_due
  defp status_atom("renewed"), do: :renewed
  defp status_atom("expired"), do: :expired
  defp status_atom("revoked"), do: :revoked
  defp status_atom("checkpoint_required"), do: :checkpoint_required
  defp status_atom(_status), do: :invalid

  defp renewal_state(:renewal_due, _current), do: "due"
  defp renewal_state(:renew, _current), do: "renewed"
  defp renewal_state(:expire, _current), do: "expired"
  defp renewal_state(:revoke, _current), do: "revoked"
  defp renewal_state(_action, current), do: current

  defp map_value(map, key), do: Map.get(map, key)
  defp legacy_capacity_state(:observed), do: "known"
  defp legacy_capacity_state(_state), do: "unknown"
  # The v1 shadow must not imply trusted capacity when the v2 parent is
  # degraded, refused, or unknown. A v1 known window is therefore retained
  # only for a canonical v2 observed snapshot.
  defp legacy_window_state(:observed, :observed), do: "known"
  defp legacy_window_state(_capacity_state, _window_state), do: "unknown"
  defp map_items(%{"items" => items}) when is_list(items), do: items
  defp map_items(%{items: items}) when is_list(items), do: items
  defp map_items(_value), do: []

  defp result_to_ok({:ok, _value}), do: :ok
  defp result_to_ok({:error, changeset}), do: {:error, changeset}

  defp reached_limit?(opts, count) do
    case Keyword.get(opts, :max_events, :infinity) do
      :infinity -> false
      limit when is_integer(limit) and limit >= 0 -> count >= limit
      _invalid -> false
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_goal_id, value}}
    end
  end

  defp event_attributes(event) do
    %{
      id: event.id,
      goal_id: event.goal_id,
      task_id: event.task_id,
      run_id: event.run_id,
      sequence: event.sequence,
      parent_event_id: event.parent_event_id,
      type: event.type,
      actor: event.actor,
      occurred_at: event.occurred_at,
      schema_version: event.schema_version,
      payload: event.payload,
      idempotency_key: event.idempotency_key
    }
  end

  defp encode_failure(error), do: error |> :erlang.term_to_binary() |> Base.encode64()
  defp decode_failure(nil), do: :projection_failed

  defp decode_failure(detail) do
    case Base.decode64(detail) do
      {:ok, encoded} -> :erlang.binary_to_term(encoded, [:safe])
      :error -> {:projection_failed_detail, detail}
    end
  end
end
