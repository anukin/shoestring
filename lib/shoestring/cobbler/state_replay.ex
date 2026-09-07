defmodule Shoestring.Cobbler.StateReplay do
  @moduledoc """
  Pure and database-backed state rebuild from authoritative trajectory events.

  Demonstrates that Cobbler state can be fully reconstructed from canonical
  trajectory events without relying on ephemeral in-memory or uncommitted state.
  """

  import Ecto.Query
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent
  alias Shoestring.Cobbler.{Claim, Intent, StateMachine}

  @doc """
  Purely replays a list of TrajectoryEvents into in-memory Cobbler state.
  """
  @spec replay_events([TrajectoryEvent.t()]) ::
          {:ok, %{intents: %{String.t() => map()}, active_claim: map() | nil}}
          | {:error, term()}
  def replay_events(events) when is_list(events) do
    initial = %{intents: %{}, active_claim: nil}

    result =
      Enum.reduce_while(events, {:ok, initial}, fn event, {:ok, state} ->
        case apply_event(state, event) do
          {:ok, new_state} -> {:cont, {:ok, new_state}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    result
  end

  @doc """
  Rebuilds in-memory state for a goal by loading its canonical trajectory.
  """
  @spec replay(Ecto.UUID.t(), keyword()) ::
          {:ok, %{intents: %{String.t() => map()}, active_claim: map() | nil}}
          | {:error, term()}
  def replay(goal_id, opts \\ []) do
    with {:ok, events} <- Trajectory.replay(goal_id, opts) do
      replay_events(events)
    end
  end

  @doc """
  Rebuilds database rows for a goal's intents and claims from canonical trajectory events.
  """
  @spec rebuild(Ecto.UUID.t(), keyword()) ::
          {:ok, %{intents: [Intent.t()], active_claim: Claim.t() | nil}}
          | {:error, term()}
  def rebuild(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.transaction(fn ->
      # Clean up existing projection rows for this goal
      from(c in Claim, where: c.goal_id == ^goal_id) |> repo.delete_all()
      from(i in Intent, where: i.goal_id == ^goal_id) |> repo.delete_all()

      with {:ok, %{intents: intents_map, active_claim: active_claim}} <- replay(goal_id, opts) do
        persisted_intents =
          Enum.map(intents_map, fn {_id, data} ->
            %Intent{id: data.id}
            |> Intent.changeset(data)
            |> Ecto.Changeset.put_change(:goal_id, goal_id)
            |> repo.insert!()
          end)

        persisted_claim =
          if active_claim do
            %Claim{id: active_claim.id}
            |> Claim.acquire_changeset(active_claim)
            |> Ecto.Changeset.put_change(:goal_id, goal_id)
            |> Ecto.Changeset.put_change(:intent_id, active_claim.intent_id)
            |> repo.insert!()
          else
            nil
          end

        %{intents: persisted_intents, active_claim: persisted_claim}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp apply_event(state, %TrajectoryEvent{type: "cobbler.intent_submitted", payload: payload}) do
    intent_id = payload["intent_id"]

    intent_data = %{
      id: intent_id,
      goal_id: payload["goal_id"],
      task_id: payload["task_id"],
      title: payload["title"] || "Intent #{intent_id}",
      status: "pending",
      requested_capability: payload["requested_capability"],
      provider_id: payload["provider_id"],
      account_id: payload["account_id"] || "default",
      scope: payload["scope"],
      admission_decision_id: payload["admission_decision_id"],
      proposed_bounds: payload["proposed_bounds"] || %{},
      override: payload["override"],
      metadata: payload["metadata"] || %{}
    }

    new_intents = Map.put(state.intents, intent_id, intent_data)
    {:ok, %{state | intents: new_intents}}
  end

  defp apply_event(state, %TrajectoryEvent{type: "cobbler.intent_claimed", payload: payload}) do
    intent_id = payload["intent_id"]

    case Map.get(state.intents, intent_id) do
      nil ->
        {:error, {:unknown_intent_in_event, intent_id}}

      intent ->
        updated_intent = Map.put(intent, :status, "active")
        new_intents = Map.put(state.intents, intent_id, updated_intent)

        claim_data = %{
          id: payload["claim_id"],
          claim_slot: "global_active",
          active_slot: "global",
          goal_id: payload["goal_id"],
          intent_id: intent_id,
          command_id: payload["command_id"],
          provider_id: payload["provider_id"],
          account_id: payload["account_id"] || intent.account_id || "default",
          scope: payload["scope"],
          status: "active",
          claimed_at: parse_datetime(payload["claimed_at"]),
          metadata: payload["metadata"] || %{}
        }

        {:ok, %{intents: new_intents, active_claim: claim_data}}
    end
  end

  defp apply_event(state, %TrajectoryEvent{type: "cobbler.intent_transitioned", payload: payload}) do
    intent_id = payload["intent_id"]
    to_status = payload["to_status"]

    case Map.get(state.intents, intent_id) do
      nil ->
        {:error, {:unknown_intent_in_event, intent_id}}

      intent ->
        updated_intent = Map.put(intent, :status, to_status)
        new_intents = Map.put(state.intents, intent_id, updated_intent)

        # If terminal, clear active claim
        new_claim =
          if (StateMachine.terminal?(to_status) and state.active_claim) &&
               state.active_claim.intent_id == intent_id do
            nil
          else
            state.active_claim
          end

        {:ok, %{intents: new_intents, active_claim: new_claim}}
    end
  end

  defp apply_event(state, _other_event), do: {:ok, state}

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_datetime(_), do: DateTime.utc_now()
end
