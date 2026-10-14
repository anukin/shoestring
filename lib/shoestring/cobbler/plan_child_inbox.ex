defmodule Shoestring.Cobbler.PlanChildInbox do
  @moduledoc """
  Durable fan-out child notifications bound to canonical source events.

  Capture and delivery enqueue share the source event's write transaction.
  Processing may verify a terminal child but never advances the dispatcher.
  Canonical acknowledgements survive delivery loss; replay repairs caches and
  missing/discarded jobs without changing an Elf or freeing uncertain ownership.
  """
  import Ecto.Query
  alias Shoestring.Cobbler.{PlanBinding, PlanChildMessage, PlanChildWorker, PlanExecutor}
  alias Shoestring.Cobbler.{ReservationRecord, Reservations, ReservationWriter}
  alias Shoestring.Harness.RunRecord
  alias Shoestring.{Repo, Trajectory}
  alias Shoestring.Trajectory.TrajectoryEvent

  @types ~w(run.starting run.running run.pausing run.suspended run.completed run.failed run.cancelled run.interrupted checkpoint.created harness.event_recorded cobbler.plan.task.accepted cobbler.plan.task.gate_failed cobbler.plan.task.scope_blocked)
  @identity ~w(event_id goal_id execution_id plan_task_id revision_number plan_digest attempt root_run_id run_id source_sequence source_type message_kind)a
  @active_jobs ~w(available scheduled executing retryable)

  def source_types, do: @types
  def valid_kind?("run.failed", kind), do: kind in ~w(failed quota_wait)
  def valid_kind?(type, kind), do: type in @types and message_kind(%{type: type}) == kind

  @doc false
  def capture(repo, %TrajectoryEvent{type: type} = event) when type in @types do
    if repo.in_transaction?() do
      case binding(repo, event) do
        :ignore ->
          :ok

        {:ok, attrs} ->
          row =
            repo.get(PlanChildMessage, event.id) ||
              repo.insert!(PlanChildMessage.changeset(attrs))

          if Map.take(Map.from_struct(row), @identity) != attrs,
            do: repo.rollback(:child_message_binding_mismatch)

          row = refresh_ack!(repo, row)
          _ = enqueue!(repo, row)
          :ok

        {:error, reason} ->
          repo.rollback(reason)
      end
    else
      {:error, :child_message_transaction_required}
    end
  end

  def capture(_repo, _event), do: :ok

  def process(event_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, id} <- Ecto.UUID.cast(event_id),
         %PlanChildMessage{} = row <- repo.get(PlanChildMessage, id),
         {:ok, event} <- authorize(repo, row),
         {:ok, ack} <- acknowledgement(repo, row) do
      if ack do
        {:ok, %{outcome: :replayed, event_id: row.event_id, observation_event_id: ack.id}}
      else
        with {:ok, result} <- observe(repo, row, event, opts) do
          if result.outcome == :awaiting_quiescence,
            do: wait_for_stop(repo, row),
            else: acknowledge(repo, row, result, opts)
        end
      end
    else
      nil -> {:error, :child_message_not_found}
      :error -> {:error, :invalid_child_event_id}
      {:error, _} = error -> error
    end
  end

  @doc "Replay source history and acknowledgements; repair delivery only."
  def reconcile(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    # Stream bounded pages rather than loading provider progress history at once.
    reconcile_page(repo, opts[:goal_id], nil, %{
      captured_count: 0,
      repaired_count: 0,
      failure_count: 0,
      failures: []
    })
  end

  def summary(repo, goal_id, execution_id) do
    query =
      from m in PlanChildMessage, where: m.goal_id == ^goal_id and m.execution_id == ^execution_id

    counts =
      repo.all(from m in query, group_by: m.status, select: {m.status, count(m.event_id)})
      |> Map.new()

    pending =
      repo.all(
        from m in query, where: m.status == "pending", order_by: m.source_sequence, limit: 128
      )

    %{
      pending_count: Map.get(counts, "pending", 0),
      observed_count: Map.get(counts, "observed", 0),
      pending_complete?: Map.get(counts, "pending", 0) <= 128,
      pending: Enum.map(pending, &Map.take(Map.from_struct(&1), @identity ++ [:last_reason]))
    }
  end

  defp binding(_repo, %{run_id: nil}), do: :ignore

  defp binding(repo, event) do
    run = repo.get(RunRecord, event.run_id)

    requested =
      repo.one(
        from e in TrajectoryEvent,
          where:
            e.goal_id == ^event.goal_id and e.run_id == ^event.run_id and
              e.type == "run.requested",
          order_by: e.sequence,
          limit: 1
      )

    if requested && get_in(requested.payload, ["extensions", "shoestring.fanout:version"]) == 1 do
      with %RunRecord{} <- run,
           true <- event.payload["run_id"] == run.id and run.goal_id == event.goal_id,
           true <- event.task_id in [nil, run.task_id],
           %{} = plan <- get_in(requested.payload, ["extensions", PlanBinding.key()]),
           true <- run.extensions[PlanBinding.key()] == plan,
           true <- run.extensions["shoestring.fanout:version"] == 1,
           true <-
             requested.task_id == run.task_id and
               requested.payload["workspace_ref"] == run.workspace_ref,
           %ReservationRecord{} = owner <- repo.get_by(ReservationRecord, run_id: run.id),
           true <- get_in(requested.payload, ["extensions", Reservations.key()]) == owner.id,
           true <- valid_owner?(owner, run, plan),
           {:ok, root} <- root_owner(repo, owner, plan, MapSet.new()),
           true <-
             root.run_id ==
               PlanExecutor.task_run_id(event.goal_id, plan["plan_task_id"], plan["attempt"]) do
        {:ok,
         %{
           event_id: event.id,
           goal_id: event.goal_id,
           run_id: run.id,
           root_run_id: root.run_id,
           execution_id: plan["execution_id"],
           revision_number: plan["revision_number"],
           plan_digest: plan["plan_digest"],
           plan_task_id: plan["plan_task_id"],
           attempt: plan["attempt"],
           source_sequence: event.sequence,
           source_type: event.type,
           message_kind: message_kind(event)
         }}
      else
        _ -> {:error, :child_message_binding_mismatch}
      end
    else
      :ignore
    end
  end

  defp valid_owner?(owner, run, plan) do
    owner.goal_id == run.goal_id and owner.execution_id == plan["execution_id"] and
      owner.plan_task_id == plan["plan_task_id"] and owner.attempt == plan["attempt"] and
      run.extensions[Reservations.key()] == owner.id
  end

  defp root_owner(repo, owner, plan, seen) do
    with false <- MapSet.member?(seen, owner.id) or MapSet.size(seen) >= 64,
         %RunRecord{} = run <- repo.get(RunRecord, owner.run_id),
         true <- valid_owner?(owner, run, plan),
         true <- run.extensions["shoestring.fanout:version"] == 1,
         true <- run.extensions[PlanBinding.key()] == plan do
      if owner.parent_id do
        case repo.get(ReservationRecord, owner.parent_id) do
          nil ->
            {:error, :child_message_binding_mismatch}

          parent ->
            parent_run = repo.get(RunRecord, parent.run_id)

            if (parent.goal_id == owner.goal_id and parent_run) &&
                 parent_run.workspace_ref == run.workspace_ref,
               do: root_owner(repo, parent, plan, MapSet.put(seen, owner.id)),
               else: {:error, :child_message_binding_mismatch}
        end
      else
        {:ok, owner}
      end
    else
      _ -> {:error, :child_message_binding_mismatch}
    end
  end

  defp message_kind(%{type: "run.failed", payload: %{"error_category" => "quota_refused"}}),
    do: "quota_wait"

  defp message_kind(%{type: type})
       when type in ~w(run.starting run.running run.pausing harness.event_recorded),
       do: "progress"

  defp message_kind(%{type: "checkpoint.created"}), do: "checkpoint"
  defp message_kind(%{type: type}), do: type |> String.split(".") |> List.last()

  defp authorize(repo, row) do
    with %TrajectoryEvent{} = event <- repo.get(TrajectoryEvent, row.event_id),
         {:ok, expected} <- binding(repo, event),
         true <- Map.take(Map.from_struct(row), @identity) == expected do
      {:ok, event}
    else
      _ -> {:error, :child_message_binding_mismatch}
    end
  end

  defp acknowledgement(repo, row) do
    ack = repo.get_by(TrajectoryEvent, goal_id: row.goal_id, idempotency_key: ack_key(row))

    if is_nil(ack) or
         (ack.type == "cobbler.plan.child.observed" and ack.parent_event_id == row.event_id and
            ack.run_id == row.run_id and
            Map.take(ack.payload, Map.keys(ack_identity(row))) == ack_identity(row)),
       do: {:ok, ack},
       else: {:error, :child_message_binding_mismatch}
  end

  defp observe(repo, row, event, opts) when row.message_kind in ["completed", "failed"] do
    with :ok <- reconcile_stops(repo, row.goal_id, opts),
         {:ok, status} <- PlanExecutor.status(row.goal_id, opts) do
      child = Enum.find(status[:children] || [], &(&1.root_run_id == row.root_run_id))

      cond do
        is_nil(status[:execution]) or status.execution.execution_id != row.execution_id ->
          {:ok, %{outcome: :prior_execution}}

        is_nil(child) or child.run_id != row.run_id ->
          {:ok, %{outcome: :prior_attempt}}

        event.type in ["run.completed", "run.failed"] ->
          case PlanExecutor.complete_task_run(row.goal_id, row.run_id, opts) do
            {:ok, result} ->
              {:ok, %{outcome: result.disposition, resolution_event_id: result[:event_id]}}

            {:error, :fanout_child_not_quiescent} ->
              {:ok, %{outcome: :awaiting_quiescence}}

            error ->
              error
          end

        true ->
          {:ok, %{outcome: :observed}}
      end
    end
  end

  defp observe(repo, row, event, opts) do
    result =
      if event.type in ~w(run.failed run.cancelled run.interrupted),
        do: reconcile_stops(repo, row.goal_id, opts),
        else: :ok

    with :ok <- result, do: {:ok, %{outcome: :observed, message_kind: row.message_kind}}
  end

  defp reconcile_stops(repo, goal_id, opts),
    do:
      Reservations.reconcile_terminals(
        goal_id,
        Keyword.merge(Keyword.get(opts, :reconciliation_opts, []),
          repo: repo,
          now: Keyword.get(opts, :now, DateTime.utc_now())
        )
      )

  defp wait_for_stop(repo, row) do
    ReservationWriter.run(repo, fn ->
      repo.transaction(
        fn ->
          current = repo.get!(PlanChildMessage, row.event_id)
          {:ok, _} = authorize(repo, current)

          case acknowledgement(repo, current) do
            {:ok, nil} ->
              repo.update!(Ecto.Changeset.change(current, last_reason: "awaiting_quiescence"))

            {:ok, _} ->
              :ok

            {:error, reason} ->
              repo.rollback(reason)
          end

          %{outcome: :awaiting_quiescence, event_id: row.event_id}
        end,
        mode: :immediate
      )
    end)
  end

  defp acknowledge(repo, row, result, opts) do
    nested? = repo.in_transaction?()

    transaction =
      ReservationWriter.run(repo, fn ->
        repo.transaction(
          fn ->
            row = repo.get!(PlanChildMessage, row.event_id)
            {:ok, _} = authorize(repo, row)
            row = refresh_ack!(repo, row)

            if row.status == "observed" do
              %{
                outcome: :replayed,
                event_id: row.event_id,
                observation_event_id: row.observation_event_id
              }
            else
              payload = ack_identity(row) |> Map.put("outcome", Atom.to_string(result.outcome))

              payload =
                if result[:resolution_event_id],
                  do: Map.put(payload, "resolution_event_id", result.resolution_event_id),
                  else: payload

              case Trajectory.append(
                     row.goal_id,
                     %{
                       "type" => "cobbler.plan.child.observed",
                       "schema_version" => 1,
                       "actor" => "cobbler",
                       "occurred_at" => Keyword.get(opts, :now, DateTime.utc_now()),
                       "idempotency_key" => ack_key(row),
                       "payload" => payload
                     },
                     trusted: [run_id: row.run_id, parent_event_id: row.event_id],
                     writer_opts: [transaction_repo: repo]
                   ) do
                {:ok, event} ->
                  repo.update!(
                    Ecto.Changeset.change(row,
                      status: "observed",
                      observation_event_id: event.id,
                      last_reason: nil
                    )
                  )

                  %{
                    outcome: result.outcome,
                    event_id: row.event_id,
                    observation_event_id: event.id
                  }

                {:error, reason} ->
                  repo.rollback(reason)
              end
            end
          end,
          mode: :immediate
        )
      end)

    case transaction do
      {:ok, %{outcome: outcome, observation_event_id: id}} when outcome != :replayed ->
        unless nested?, do: publish(repo.get!(TrajectoryEvent, id), opts)
        transaction

      _ ->
        transaction
    end
  end

  defp publish(event, opts) do
    fun =
      Keyword.get(opts, :publish_fun, fn event ->
        Phoenix.PubSub.broadcast(
          Shoestring.PubSub,
          Trajectory.topic(event.goal_id),
          {:trajectory_event_committed, event}
        )
      end)

    fun.(event)
  rescue
    _ -> :notification_failed
  catch
    _, _ -> :notification_failed
  end

  defp ack_identity(row) do
    Map.take(Map.from_struct(row), @identity -- [:event_id, :goal_id, :source_sequence])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.put("source_event_id", row.event_id)
    |> Map.put("source_sequence", row.source_sequence)
  end

  defp ack_key(row), do: "plan-child-observed:#{row.event_id}"

  defp refresh_ack!(repo, row) do
    case acknowledgement(repo, row) do
      {:ok, nil} ->
        repo.update!(Ecto.Changeset.change(row, status: "pending", observation_event_id: nil))

      {:ok, ack} ->
        repo.update!(
          Ecto.Changeset.change(row,
            status: "observed",
            observation_event_id: ack.id,
            last_reason: nil
          )
        )

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp enqueue!(_repo, %{status: "observed"}), do: false

  defp enqueue!(repo, row) do
    job = row.job_id && repo.get(Oban.Job, row.job_id)

    if job && job.state in @active_jobs && job.worker == "Shoestring.Cobbler.PlanChildWorker" &&
         job.args == %{"event_id" => row.event_id} do
      false
    else
      # Lite inserts the same Job changeset through Repo.insert. Direct insertion
      # keeps CLI-only writers independent of a running Oban process; the service
      # stager discovers committed jobs. The receipt's write lock deduplicates.
      job = repo.insert!(PlanChildWorker.new(%{event_id: row.event_id}))
      repo.update!(Ecto.Changeset.change(row, job_id: job.id))
      true
    end
  end

  defp reconcile_page(repo, goal_id, cursor, result) do
    query =
      from e in TrajectoryEvent,
        join: requested in TrajectoryEvent,
        on:
          requested.run_id == e.run_id and requested.goal_id == e.goal_id and
            requested.type == "run.requested",
        where:
          fragment(
            "json_extract(?, '$.extensions.\"shoestring.fanout:version\"')",
            requested.payload
          ) == 1 and e.type in ^@types,
        distinct: true,
        order_by: e.id,
        limit: 128,
        select: e

    query = if goal_id, do: from(e in query, where: e.goal_id == ^goal_id), else: query
    query = if cursor, do: from(e in query, where: e.id > ^cursor), else: query
    events = repo.all(query)

    result =
      Enum.reduce(events, result, fn event, result ->
        before = repo.get(PlanChildMessage, event.id)

        case ReservationWriter.run(repo, fn ->
               repo.transaction(fn -> capture(repo, event) end, mode: :immediate)
             end) do
          {:ok, :ok} ->
            after_row = repo.get(PlanChildMessage, event.id)

            %{
              result
              | captured_count:
                  result.captured_count + if(is_nil(before) and after_row, do: 1, else: 0),
                repaired_count:
                  result.repaired_count +
                    if(
                      after_row && (is_nil(before) or before.job_id != after_row.job_id) &&
                        after_row.job_id,
                      do: 1,
                      else: 0
                    )
            }

          {:error, reason} ->
            %{
              result
              | failure_count: result.failure_count + 1,
                failures:
                  Enum.take(result.failures ++ [%{event_id: event.id, reason: reason}], 128)
            }
        end
      end)

    if length(events) == 128,
      do: reconcile_page(repo, goal_id, List.last(events).id, result),
      else: {:ok, result}
  end
end
