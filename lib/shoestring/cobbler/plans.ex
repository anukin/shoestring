defmodule Shoestring.Cobbler.Plans do
  @moduledoc """
  Inert human plan foundation. Every request is owner-scoped and serialized
  with an immediate transaction. Events are authoritative; the replaceable
  projection is never used to grant authority. No dispatch or lifecycle effects.
  """
  import Ecto.Query
  alias Shoestring.Repo
  alias Shoestring.Cobbler.{PlanContract, PlanProjection}
  alias Shoestring.Trajectory.{EventRegistry, Goal, TrajectoryEvent}

  def create_goal(owner_id, goal_id, request_id, contract, opts \\ []) do
    request(
      owner_id,
      goal_id,
      request_id,
      "cobbler.plan.goal_defined",
      %{"contract" => contract},
      opts
    )
  end

  def propose(owner_id, goal_id, request_id, base_revision, content, opts \\ []) do
    request(
      owner_id,
      goal_id,
      request_id,
      "cobbler.plan.revision_proposed",
      %{"base_revision" => base_revision, "content" => content},
      opts
    )
  end

  def approve(owner_id, goal_id, request_id, revision_id, digest, opts \\ []) do
    request(
      owner_id,
      goal_id,
      request_id,
      "cobbler.plan.revision_approved",
      %{"revision_id" => revision_id, "digest" => digest},
      opts
    )
  end

  def reject(owner_id, goal_id, request_id, revision_id, digest, reason, opts \\ []) do
    request(
      owner_id,
      goal_id,
      request_id,
      "cobbler.plan.revision_rejected",
      %{"revision_id" => revision_id, "digest" => digest, "reason" => reason},
      opts
    )
  end

  def read(owner_id, goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with :ok <- identities(owner_id, goal_id),
         {:ok, goal} <- owned_goal(repo, owner_id, goal_id),
         {:ok, state} <- replay(repo, goal) do
      {:ok, state}
    end
  end

  def revision(owner_id, goal_id, revision_id, opts \\ []) do
    with {:ok, state} <- read(owner_id, goal_id, opts) do
      case Map.fetch(state["revisions"], revision_id) do
        {:ok, revision} -> {:ok, revision}
        :error -> {:error, :revision_not_found}
      end
    end
  end

  def active_authority(owner_id, goal_id, opts \\ []) do
    with {:ok, state} <- read(owner_id, goal_id, opts) do
      case state["active_revision"] do
        nil -> {:ok, nil}
        id -> {:ok, Map.fetch!(state["revisions"], id)}
      end
    end
  end

  def rebuild(owner_id, goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with :ok <- identities(owner_id, goal_id) do
      serialized_transaction(
        repo,
        fn ->
          goal = unwrap(repo, owned_goal(repo, owner_id, goal_id))
          state = unwrap(repo, replay(repo, goal))
          persist(repo, goal_id, state, last_sequence(repo, goal_id))
          state
        end
      )
    end
  end

  defp request(owner_id, goal_id, request_id, type, request, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    candidate = %{
      "request_id" => request_id,
      "request_digest" => String.duplicate("0", 64),
      "request" => request
    }

    with :ok <- identities(owner_id, goal_id),
         :ok <- PlanContract.event(type, candidate) do
      digest =
        PlanContract.digest(%{"type" => type, "owner_id" => owner_id, "request" => request})

      payload = %{candidate | "request_digest" => digest}

      with {:ok, _} <- EventRegistry.validate_payload(type, 1, payload) do
        result =
          serialized_transaction(
            repo,
            fn ->
              goal = load_goal(repo, owner_id, goal_id, type)
              state = unwrap(repo, replay(repo, goal))

              case existing(repo, goal_id, request_id) do
                nil ->
                  if goal.status != "active", do: repo.rollback(:goal_not_active)
                  now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

                  event = %TrajectoryEvent{
                    id: Ecto.UUID.generate(),
                    goal_id: goal_id,
                    sequence: last_sequence(repo, goal_id) + 1,
                    type: type,
                    actor: "human:" <> owner_id,
                    occurred_at: now,
                    schema_version: 1,
                    payload: payload,
                    idempotency_key: "plan:" <> request_id
                  }

                  next = unwrap(repo, apply_event(state, event, goal))
                  event = event |> TrajectoryEvent.changeset(%{}) |> repo.insert!()
                  persist(repo, goal_id, next, event.sequence)
                  %{state: next, event: event, repeated?: false}

                event ->
                  if event.type == type and event.payload == payload do
                    %{state: state, event: event, repeated?: true}
                  else
                    repo.rollback(:idempotency_conflict)
                  end
              end
            end
          )

        case result do
          {:ok, %{event: event, repeated?: false}} -> publish(event)
          _ -> :ok
        end

        result
      end
    end
  end

  defp load_goal(repo, owner_id, goal_id, type) do
    case repo.get(Goal, goal_id) do
      nil when type == "cobbler.plan.goal_defined" ->
        %Goal{id: goal_id}
        |> Goal.create_changeset(owner_id, %{"title" => "Planning goal"})
        |> repo.insert!()

      _ ->
        unwrap(repo, owned_goal(repo, owner_id, goal_id))
    end
  end

  defp owned_goal(repo, owner_id, goal_id) do
    case repo.get_by(Goal.user_goals(), id: goal_id, owner_id: owner_id) do
      nil -> {:error, :goal_not_found}
      goal -> {:ok, goal}
    end
  end

  defp identities(owner_id, goal_id) do
    with {:ok, ^owner_id} <- Ecto.UUID.cast(owner_id),
         {:ok, ^goal_id} <- Ecto.UUID.cast(goal_id),
         false <- Goal.observatory?(goal_id),
         false <- owner_id == Shoestring.Harness.Observatory.observatory_owner_id() do
      :ok
    else
      _ -> {:error, :invalid_identity}
    end
  end

  defp existing(repo, goal_id, request_id) do
    repo.get_by(TrajectoryEvent, goal_id: goal_id, idempotency_key: "plan:" <> request_id)
  end

  defp last_sequence(repo, goal_id) do
    repo.one(from e in TrajectoryEvent, where: e.goal_id == ^goal_id, select: max(e.sequence)) ||
      0
  end

  defp replay(repo, goal) do
    events =
      repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal.id and like(e.type, "cobbler.plan.%"),
          order_by: e.sequence
      )

    replay_events(goal, events)
  end

  @doc "Replays ordered canonical plan events, validating both contracts and causal transitions."
  def replay_events(%Goal{} = goal, events) do
    Enum.reduce_while(events, {:ok, initial()}, fn event, {:ok, state} ->
      with {:ok, _} <- EventRegistry.validate(Map.from_struct(event)),
           true <- event.goal_id == goal.id and event.actor == "human:" <> goal.owner_id,
           true <- event.sequence > state["last_plan_sequence"],
           true <- is_binary(event.id),
           true <-
             is_nil(event.task_id) and is_nil(event.run_id) and is_nil(event.parent_event_id),
           true <- event.idempotency_key == "plan:" <> event.payload["request_id"],
           true <-
             event.payload["request_digest"] ==
               PlanContract.digest(%{
                 "type" => event.type,
                 "owner_id" => goal.owner_id,
                 "request" => event.payload["request"]
               }),
           false <- Map.has_key?(state["requests"], event.payload["request_id"]),
           false <- event.id in Map.values(state["requests"]),
           {:ok, next} <- apply_event(state, event, goal) do
        {:cont, {:ok, next}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_plan_history, event.sequence, reason}}}
        _ -> {:halt, {:error, {:invalid_plan_history, event.sequence, :identity_order_or_digest}}}
      end
    end)
  end

  defp initial do
    %{
      "contract" => nil,
      "revisions" => %{},
      "latest_revision" => nil,
      "active_revision" => nil,
      "requests" => %{},
      "last_plan_sequence" => 0
    }
  end

  defp apply_event(state, event, _goal) do
    request = event.payload["request"]

    result =
      case event.type do
        "cobbler.plan.goal_defined" -> define_goal(state, request)
        "cobbler.plan.revision_proposed" -> propose_revision(state, request, event)
        "cobbler.plan.revision_approved" -> decide(state, request, event, "approved")
        "cobbler.plan.revision_rejected" -> decide(state, request, event, "rejected")
      end

    with {:ok, next} <- result do
      {:ok,
       next
       |> Map.put("last_plan_sequence", event.sequence)
       |> put_in(["requests", event.payload["request_id"]], event.id)}
    end
  end

  defp define_goal(%{"contract" => nil} = state, request),
    do: {:ok, %{state | "contract" => request["contract"]}}

  defp define_goal(_state, _request), do: {:error, :goal_already_defined}

  defp propose_revision(%{"contract" => nil}, _request, _event),
    do: {:error, :goal_contract_required}

  defp propose_revision(state, request, event) do
    content = request["content"]

    revision_limit =
      min(
        state["contract"]["budget"]["max_revisions"],
        content["goal"]["budget"]["max_revisions"]
      )

    with true <- request["base_revision"] == state["latest_revision"],
         true <- map_size(state["revisions"]) < revision_limit,
         {:ok, order} <- PlanContract.validate_dag(content),
         :ok <- revision_goal(state["contract"], content["goal"]),
         :ok <- PlanContract.validate_bounds(content["goal"], content),
         :ok <- preserve_identities(state, content) do
      revision = %{
        "id" => event.id,
        "base_revision" => request["base_revision"],
        "content" => content,
        "digest" => PlanContract.digest(content),
        "order" => order,
        "status" => "proposed",
        "author" => event.actor,
        "proposed_at" => DateTime.to_iso8601(event.occurred_at),
        "decision" => nil
      }

      {:ok,
       state |> put_in(["revisions", event.id], revision) |> Map.put("latest_revision", event.id)}
    else
      false -> {:error, :stale_revision_or_revision_budget}
      error -> error
    end
  end

  defp revision_goal(initial, revised) do
    caps =
      Enum.all?(["budget", "execution"], fn section ->
        Enum.all?(revised[section], fn {key, value} -> value <= initial[section][key] end)
      end)

    if caps and revised["repository"] == initial["repository"],
      do: :ok,
      else: {:error, :goal_identity_or_budget_changed}
  end

  # With no executor state yet, protect every ever-approved identity. Later
  # amendment policy may explicitly replace unfinished identities, but never
  # erase completed identities or their evidence.
  defp preserve_identities(state, content) do
    protected =
      state["revisions"]
      |> Map.values()
      |> Enum.filter(&(&1["status"] in ["approved", "superseded"]))
      |> Enum.flat_map(&Enum.map(&1["content"]["tasks"], fn task -> task["id"] end))

    incoming = Enum.map(content["tasks"], & &1["id"])

    if Enum.all?(protected, &(&1 in incoming)),
      do: :ok,
      else: {:error, :approved_task_identity_removed}
  end

  defp decide(state, request, event, status) do
    id = request["revision_id"]

    case state["revisions"][id] do
      nil ->
        {:error, :revision_not_found}

      revision ->
        cond do
          revision["digest"] != request["digest"] ->
            {:error, :digest_mismatch}

          id != state["latest_revision"] ->
            {:error, :stale_revision}

          revision["status"] != "proposed" ->
            {:error, :decision_conflict}

          true ->
            decision = %{
              "event_id" => event.id,
              "actor" => event.actor,
              "at" => DateTime.to_iso8601(event.occurred_at),
              "digest" => request["digest"],
              "reason" => request["reason"],
              "status" => status
            }

            next =
              state
              |> put_in(["revisions", id, "status"], status)
              |> put_in(["revisions", id, "decision"], decision)

            if status == "approved" do
              next =
                case state["active_revision"] do
                  nil -> next
                  prior -> put_in(next, ["revisions", prior, "status"], "superseded")
                end

              {:ok, Map.put(next, "active_revision", id)}
            else
              {:ok, next}
            end
        end
    end
  end

  defp persist(repo, goal_id, state, sequence) do
    repo.insert!(%PlanProjection{goal_id: goal_id, state: state, last_sequence: sequence},
      on_conflict: [set: [state: state, last_sequence: sequence]],
      conflict_target: [:goal_id]
    )
  end

  # SQLite has one writer per database. Prevent local plan callers from
  # occupying every connection's busy handler while the lock owner needs to
  # resume. The database transaction remains the cross-process authority;
  # this local lock is only contention control and owns no domain state.
  defp serialized_transaction(repo, fun) do
    :global.trans(
      {{__MODULE__, repo}, self()},
      fn ->
        repo.transaction(fun, mode: :immediate)
      end,
      [node()]
    )
  rescue
    error in Exqlite.Error ->
      if error.message == "database is locked",
        do: {:error, :storage_busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp unwrap(_repo, {:ok, result}), do: result
  defp unwrap(repo, {:error, reason}), do: repo.rollback(reason)

  defp publish(event) do
    Phoenix.PubSub.broadcast(
      Shoestring.PubSub,
      Shoestring.Trajectory.topic(event.goal_id),
      {:trajectory_event_committed, event}
    )
  rescue
    _ -> :ok
  end
end
