defmodule Shoestring.Harness.Checkpoints do
  @moduledoc """
  Durable checkpoint writer (Milestone 05, work package D).

  Mirrors the `Commands` / `Dispatches` idempotency contract for
  `checkpoint.created` contents:

  - **Ownership check.** The checkpoint's run row must exist under the same
    goal (`{:error, {:run_not_found, run_id}}` when the run row is missing,
    `{:error, {:run_not_owned, run_id}}` when it belongs to another goal).
  - **Contract validation** through `Shoestring.Harness.Checkpoint.new/1`.
  - **Artifact pre-check mirroring the projector.** Every `artifact_id` must
    reference an artifact row owned by the same goal, otherwise
    `{:error, {:artifact_not_owned, artifact_id}}` and nothing is appended.
  - **Canonical payload** built with `Shoestring.Harness.EventPayload.checkpoint/1`
    (never a second hand-rolled mapping).
  - **Idempotent append** with key `"checkpoint-created:<checkpoint_id>"`.
    When the event already exists the recorded checkpoint is rebuilt from
    the canonical payload and returned with `outcome: :replayed` and no new
    events.

  Returns `{:ok, %{checkpoint_id: id, outcome: :recorded | :replayed,
  events: [event], checkpoint: checkpoint}}`.

  Projection is the caller's responsibility; this writer appends only and
  makes no projector change.
  """

  import Ecto.Query

  alias Shoestring.Harness.{Checkpoint, Clock, EventPayload, Identifier, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Artifact, TrajectoryEvent}

  @actor "harness"
  @schema_version 1

  @type record_result :: %{
          required(:checkpoint_id) => Ecto.UUID.t(),
          required(:outcome) => :recorded | :replayed,
          required(:events) => [TrajectoryEvent.t()],
          required(:checkpoint) => Checkpoint.t()
        }

  @doc """
  Records checkpoint contents for a goal.

  Accepts a `Checkpoint` struct or an attrs map (validated through
  `Checkpoint.new/1`; a missing `:checkpoint_id` is generated via the
  `:identifier` source, default `Shoestring.Harness.SystemIdentifier`).

  Options: `:repo`, `:actor` (default `"harness"`), `:now` (`%DateTime{}`
  for `occurred_at`), `:clock` (used when `:now` is absent),
  `:writer_opts`, `:identifier`.
  """
  @spec record(Ecto.UUID.t(), Checkpoint.t() | map(), keyword()) ::
          {:ok, record_result()} | {:error, term()}
  def record(goal_id, input, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, checkpoint} <- resolve_checkpoint(input, opts),
         :ok <- owned_run(repo, goal_id, checkpoint.run_id),
         :ok <- owned_artifacts(repo, goal_id, checkpoint.artifact_ids) do
      key = idempotency_key(checkpoint.checkpoint_id)

      case existing_event(repo, goal_id, key) do
        %TrajectoryEvent{} = event ->
          replay_checkpoint(goal_id, checkpoint.checkpoint_id, event)

        nil ->
          append_checkpoint(goal_id, checkpoint, key, opts)
      end
    end
  end

  @doc "The trajectory idempotency key for a checkpoint id."
  @spec idempotency_key(Ecto.UUID.t()) :: String.t()
  def idempotency_key(checkpoint_id), do: "checkpoint-created:#{checkpoint_id}"

  defp resolve_checkpoint(%Checkpoint{} = checkpoint, _opts), do: {:ok, checkpoint}

  defp resolve_checkpoint(attrs, opts) when is_map(attrs) do
    attrs =
      if Map.get(attrs, :checkpoint_id, Map.get(attrs, "checkpoint_id")) do
        attrs
      else
        identifier = Keyword.get(opts, :identifier, Shoestring.Harness.SystemIdentifier)
        Map.put(attrs, :checkpoint_id, Identifier.generate(identifier))
      end

    Checkpoint.new(attrs)
  end

  defp resolve_checkpoint(_input, _opts),
    do: {:error, {:checkpoint_invalid, :not_an_object}}

  defp owned_run(repo, goal_id, run_id) do
    case repo.get(RunRecord, run_id) do
      nil -> {:error, {:run_not_found, run_id}}
      %RunRecord{goal_id: ^goal_id} -> :ok
      %RunRecord{} -> {:error, {:run_not_owned, run_id}}
    end
  end

  defp owned_artifacts(repo, goal_id, artifact_ids) do
    Enum.reduce_while(artifact_ids, :ok, fn artifact_id, :ok ->
      if repo.exists?(
           from artifact in Artifact,
             where: artifact.id == ^artifact_id and artifact.goal_id == ^goal_id
         ) do
        {:cont, :ok}
      else
        {:halt, {:error, {:artifact_not_owned, artifact_id}}}
      end
    end)
  end

  defp existing_event(repo, goal_id, key) do
    repo.get_by(TrajectoryEvent, goal_id: goal_id, idempotency_key: key)
  end

  defp replay_checkpoint(goal_id, checkpoint_id, %TrajectoryEvent{payload: payload}) do
    case from_event_payload(goal_id, payload) do
      {:ok, checkpoint} ->
        {:ok,
         %{checkpoint_id: checkpoint_id, outcome: :replayed, events: [], checkpoint: checkpoint}}

      {:error, reason} ->
        {:error, {:checkpoint_invalid, reason}}
    end
  end

  defp append_checkpoint(goal_id, checkpoint, key, opts) do
    attrs = %{
      "type" => "checkpoint.created",
      "schema_version" => @schema_version,
      "actor" => Keyword.get(opts, :actor, @actor),
      "occurred_at" => now(opts),
      "idempotency_key" => key,
      "payload" => EventPayload.checkpoint(checkpoint)
    }

    case Trajectory.append(goal_id, attrs,
           trusted: [run_id: checkpoint.run_id],
           writer_opts: Keyword.get(opts, :writer_opts, [])
         ) do
      {:ok, event} ->
        {:ok,
         %{
           checkpoint_id: checkpoint.checkpoint_id,
           outcome: :recorded,
           events: [event],
           checkpoint: checkpoint
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Rebuilds the recorded checkpoint from its canonical event payload (the
  # same mapping `EventPayload.checkpoint/1` produced, inverted). The payload
  # carries no goal id; the goal is the row the event was found under.
  defp from_event_payload(goal_id, payload) when is_map(payload) do
    Checkpoint.new(%{
      version: payload["contract_version"],
      checkpoint_id: payload["checkpoint_id"],
      goal_id: goal_id,
      run_id: payload["run_id"],
      acceptance_contract: %{criteria: get_in(payload, ["acceptance_contract", "criteria"])},
      repository_state: %{
        revision: get_in(payload, ["repository_state", "revision"]),
        dirty: get_in(payload, ["repository_state", "dirty"])
      },
      evidence: get_in(payload, ["evidence", "items"]),
      decisions: get_in(payload, ["decisions", "items"]),
      unresolved_issues: get_in(payload, ["unresolved_issues", "items"]),
      next_action: payload["next_action"],
      provider_session_id: payload["provider_session_id"],
      stop_reason: payload["stop_reason"],
      artifact_ids: get_in(payload, ["artifact_ids", "items"]),
      extensions: payload["extensions"] || %{}
    })
  end

  defp from_event_payload(_goal_id, _payload), do: {:error, :invalid_checkpoint_payload}

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> DateTime.truncate(now, :microsecond)
      _other -> Clock.now(Keyword.get(opts, :clock, Shoestring.Harness.SystemClock))
    end
  end

  defp cast_goal_id(goal_id) do
    case Ecto.UUID.cast(goal_id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_goal_id, goal_id}}
    end
  end
end
