defmodule Shoestring.Cobbler.PlanCancellation do
  @moduledoc """
  Explicit user cancellation of one fan-out child or of the whole execution.

  A repository-only CLI records the durable request and queues a service job;
  only the service, which owns the Elves, stops anything. For each target the
  worker either fences a provably never-started intent
  (`ReservationRecovery.cancel_unstarted/3`) or calls `Elves.cancel_run/2`.
  `cancel_run/2` terminates the owned process group (TERM, bounded grace,
  then KILL) and records `run.cancelled` under the shared single-terminal
  key. Terminal settlement then releases verified owners.
  `cobbler.plan.cancellation.completed` is appended only once every target is
  stopped. Otherwise the job fails and Oban retries it within its bounded
  attempts, and startup repair re-queues any request still pending.

  Goal cancellation also fences further work for that execution: fan-out
  dispatch, sequential advancement and plan continuations refuse with
  `:execution_cancelled`. Child cancellation stops only its target; the task
  stays unresolved for an explicit continuation or amendment and is never
  replaced automatically. A deadline or elapsed time never triggers
  cancellation.
  """

  import Ecto.Query

  alias Shoestring.Cobbler.{
    PlanCancellationWorker,
    PlanExecutor,
    Plans,
    ReservationRecord,
    ReservationRecovery,
    Reservations,
    ReservationWriter
  }

  alias Shoestring.Harness.RunRecord
  alias Shoestring.{Repo, Trajectory}
  alias Shoestring.Trajectory.TrajectoryEvent

  @requested "cobbler.plan.cancellation.requested"
  @completed "cobbler.plan.cancellation.completed"
  @human ~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/
  @started ~w(run.starting run.running run.pausing run.suspended run.completed run.failed run.interrupted run.cancelling run.cancelled)

  def event_types, do: [@requested, @completed]

  @doc "Records one cancellation request and queues its service-owned worker."
  def request(goal_id, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- Ecto.UUID.cast(goal_id),
         {:ok, command} <- command(attrs, goal_id, opts) do
      ReservationWriter.run(repo, fn ->
        repo.transaction(
          fn ->
            event =
              case existing(repo, goal_id, command.id) do
                nil ->
                  case record(repo, goal_id, command) do
                    {:ok, event} -> event
                    {:error, reason} -> repo.rollback(reason)
                  end

                event ->
                  if same?(event.payload, command),
                    do: event,
                    else: repo.rollback(:cancellation_conflict)
              end

            job =
              if completed(repo, goal_id, command.id),
                do: nil,
                else: enqueue!(repo, goal_id, command.id, opts)

            %{
              cancellation_id: command.id,
              event_id: event.id,
              scope: event.payload["scope"],
              run_id: event.payload["run_id"],
              job_id: job && job.id,
              completed?: is_nil(job)
            }
          end,
          mode: :immediate
        )
      end)
    else
      :error -> {:error, :invalid_cancellation}
      {:error, _} = error -> error
    end
  end

  @doc "Stops every target of one request; appends completion only when all stopped."
  def perform(goal_id, cancellation_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- Ecto.UUID.cast(goal_id),
         %TrajectoryEvent{payload: request} <- existing(repo, goal_id, cancellation_id) do
      case completed(repo, goal_id, cancellation_id) do
        %TrajectoryEvent{} = event ->
          {:ok, %{outcome: :replayed, event_id: event.id}}

        nil ->
          stop_targets(repo, goal_id, request, opts)
      end
    else
      nil -> {:error, :cancellation_not_found}
      :error -> {:error, :cancellation_not_found}
    end
  end

  @doc "Startup repair: re-queues requests whose completion was never recorded."
  def repair(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    pending =
      repo.all(
        from event in TrajectoryEvent,
          where: event.type == @requested,
          select: {event.goal_id, event.payload}
      )
      |> Enum.reject(fn {goal_id, payload} ->
        completed(repo, goal_id, payload["cancellation_id"])
      end)

    Enum.reduce(pending, {:ok, %{repaired_count: 0, failures: []}}, fn {goal_id, payload},
                                                                       {:ok, acc} ->
      case Oban.insert(
             Keyword.get(opts, :oban, Oban),
             PlanCancellationWorker.new(%{
               "goal_id" => goal_id,
               "cancellation_id" => payload["cancellation_id"]
             })
           ) do
        {:ok, _job} -> {:ok, %{acc | repaired_count: acc.repaired_count + 1}}
        {:error, _} -> {:ok, %{acc | failures: Enum.take([goal_id | acc.failures], 128)}}
      end
    end)
  end

  @doc "True once a goal-scope cancellation exists for the execution."
  def goal_cancelled?(_repo, _goal_id, nil), do: false

  def goal_cancelled?(repo, goal_id, execution_id) do
    repo.exists?(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == @requested and
            fragment("json_extract(?, '$.scope')", event.payload) == "goal" and
            fragment("json_extract(?, '$.execution_id')", event.payload) == ^execution_id
    )
  end

  @doc "Bounded per-execution view for status."
  def summary(repo, goal_id, execution_id) do
    requests =
      repo.all(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^goal_id and event.type == @requested and
              fragment("json_extract(?, '$.execution_id')", event.payload) == ^execution_id,
          order_by: [asc: event.sequence],
          limit: 64,
          select: event.payload
      )

    Enum.map(requests, fn payload ->
      done = completed(repo, goal_id, payload["cancellation_id"])

      %{
        cancellation_id: payload["cancellation_id"],
        scope: payload["scope"],
        run_id: payload["run_id"],
        requested_by: payload["requested_by"],
        completed?: not is_nil(done),
        outcomes: done && done.payload["outcomes"]
      }
    end)
  end

  # A person cancels, or a person's grant cancels its own dispatch (the
  # dispatch code passes the dispatch record as `opts[:dispatch]`).
  defp command(attrs, goal_id, opts) do
    with {:ok, id} <- Ecto.UUID.cast(attrs[:command_id]),
         {:ok, execution_id} <- Ecto.UUID.cast(attrs[:execution_id]),
         {:ok, run_id} <- optional_uuid(attrs[:run_id]),
         by when is_binary(by) <- attrs[:requested_by],
         true <-
           Regex.match?(@human, by) or
             Shoestring.Authority.check(by, goal_id, nil, opts) == :ok,
         reason when is_binary(reason) <- attrs[:reason],
         reason = String.trim(reason),
         true <- reason != "" and String.length(reason) <= 2000 do
      {:ok,
       %{
         id: id,
         execution_id: execution_id,
         run_id: run_id,
         scope: if(run_id, do: "child", else: "goal"),
         by: by,
         reason: reason
       }}
    else
      _ -> {:error, :invalid_cancellation}
    end
  end

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: Ecto.UUID.cast(value)

  defp record(repo, goal_id, command) do
    with {:ok, status} <- PlanExecutor.status(goal_id, repo: repo),
         %{execution: execution, completed?: false} <- status,
         true <- execution.execution_id == command.execution_id,
         %{revision: revision} <- Plans.authority(goal_id, repo: repo),
         true <- revision.digest == execution.plan_digest,
         :ok <- target(status, command) do
      payload =
        %{
          "cancellation_id" => command.id,
          "execution_id" => execution.execution_id,
          "revision_number" => execution.revision_number,
          "plan_digest" => execution.plan_digest,
          "scope" => command.scope,
          "requested_by" => command.by,
          "reason" => command.reason
        }
        |> then(&if(command.run_id, do: Map.put(&1, "run_id", command.run_id), else: &1))

      Trajectory.append(
        goal_id,
        %{
          "type" => @requested,
          "schema_version" => 1,
          "actor" => "human",
          "occurred_at" => DateTime.utc_now(),
          "idempotency_key" => key("requested", command.id),
          "payload" => payload
        },
        writer_opts: [transaction_repo: repo]
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :cancellation_mismatch}
    end
  end

  # A child target must be the current run of an unresolved child.
  defp target(_status, %{scope: "goal"}), do: :ok

  defp target(status, %{run_id: run_id}) do
    if Enum.any?(status.children, &(&1.run_id == run_id and not &1.resolved?)),
      do: :ok,
      else: {:error, :cancellation_target_not_active}
  end

  defp stop_targets(repo, goal_id, request, opts) do
    {:ok, status} = PlanExecutor.status(goal_id, repo: repo)

    targets =
      case request["scope"] do
        "child" ->
          [request["run_id"]]

        "goal" ->
          status.children
          |> Enum.filter(&(&1.execution_id == request["execution_id"] and not &1.resolved?))
          |> Enum.map(& &1.run_id)
      end

    results = Enum.map(targets, &{&1, stop(repo, goal_id, &1, request, opts)})

    _ =
      Reservations.reconcile_terminals(
        goal_id,
        Keyword.merge(Keyword.get(opts, :reconciliation_opts, []), repo: repo, now: now(opts))
      )

    case Enum.filter(results, &match?({_, {:error, _}}, &1)) do
      [] ->
        outcomes = Enum.map(results, fn {run_id, {:ok, outcome}} -> {run_id, outcome} end)
        complete(repo, goal_id, request, outcomes, opts)

      failures ->
        {:error, {:cancellation_incomplete, Enum.map(failures, &elem(&1, 0))}}
    end
  end

  defp stop(repo, goal_id, run_id, request, opts) do
    case repo.get_by(RunRecord, id: run_id, goal_id: goal_id) do
      nil ->
        {:error, :run_not_found}

      run ->
        if started?(repo, run, opts) do
          case Shoestring.Elves.cancel_run(
                 run.id,
                 Keyword.take(opts, [:repo, :clock, :kill_grace_ms])
               ) do
            {:ok, :cancelled} -> {:ok, "cancelled"}
            {:ok, :already_terminal} -> {:ok, "already_terminal"}
            {:error, reason} -> {:error, reason}
          end
        else
          fence_unstarted(repo, run, request, opts)
        end
    end
  end

  defp started?(repo, run, opts) do
    lookup = Keyword.get(opts, :elf_lookup, &Shoestring.Elves.whereis/1)

    lookup.(run.id) != nil or
      repo.exists?(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^run.goal_id and event.run_id == ^run.id and event.type in ^@started
      )
  end

  defp fence_unstarted(repo, run, request, opts) do
    ReservationWriter.run(repo, fn ->
      repo.transaction(
        fn ->
          case repo.get_by(ReservationRecord, run_id: run.id) do
            nil ->
              repo.rollback(:reservation_owner_unknown)

            owner ->
              result =
                ReservationRecovery.cancel_unstarted(
                  owner,
                  request["cancellation_id"],
                  Keyword.merge(opts, repo: repo, now: now(opts))
                )

              case result do
                %{reason: :never_started_intent_fenced} ->
                  # Keep the harness read model in step with the fenced terminal.
                  case Shoestring.Harness.Projector.project(run.goal_id,
                         clock: Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
                       ) do
                    {:ok, _} -> "fenced_unstarted"
                    {:error, reason} -> repo.rollback(reason)
                  end

                %{reason: :already_settled} ->
                  "fenced_unstarted"

                %{reason: reason} ->
                  repo.rollback({:unstarted_cancellation_retained, reason})
              end
          end
        end,
        mode: :immediate
      )
    end)
  end

  defp complete(repo, goal_id, request, outcomes, opts) do
    with :ok <- release_claim(repo, goal_id, request, opts),
         do: append_completed(goal_id, request, outcomes, opts)
  end

  # A cancelled execution never dispatches again, so the sequential task
  # claim it may still hold (a retry waiting for its next attempt, say) is
  # released once every target has stopped. Child cancellation leaves the
  # execution running and keeps it.
  defp release_claim(repo, goal_id, %{"scope" => "goal"} = request, opts) do
    PlanExecutor.release_goal_claim(
      repo,
      goal_id,
      "plan-cancel-release-#{request["cancellation_id"]}",
      "execution cancelled",
      Keyword.merge(opts, repo: repo, now: now(opts))
    )
  end

  defp release_claim(_repo, _goal_id, _request, _opts), do: :ok

  defp append_completed(goal_id, request, outcomes, opts) do
    payload = %{
      "cancellation_id" => request["cancellation_id"],
      "execution_id" => request["execution_id"],
      "outcomes" =>
        outcomes
        |> Enum.take(64)
        |> Enum.map(fn {run_id, outcome} -> %{"run_id" => run_id, "outcome" => outcome} end),
      "outcomes_complete" => length(outcomes) <= 64
    }

    with {:ok, event} <-
           Trajectory.append(goal_id, %{
             "type" => @completed,
             "schema_version" => 1,
             "actor" => "cobbler",
             "occurred_at" => now(opts),
             "idempotency_key" => key("completed", request["cancellation_id"]),
             "payload" => payload
           }) do
      {:ok, %{outcome: :completed, event_id: event.id, outcomes: payload["outcomes"]}}
    end
  end

  defp existing(repo, goal_id, id) do
    repo.one(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.idempotency_key == ^key("requested", id)
    )
  end

  defp completed(repo, goal_id, id) do
    repo.one(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.idempotency_key == ^key("completed", id)
    )
  end

  defp same?(payload, command) do
    payload["execution_id"] == command.execution_id and payload["scope"] == command.scope and
      payload["run_id"] == command.run_id and payload["requested_by"] == command.by and
      payload["reason"] == command.reason
  end

  defp enqueue!(repo, goal_id, id, opts) do
    case Oban.insert(
           Keyword.get(opts, :oban, Oban),
           PlanCancellationWorker.new(%{"goal_id" => goal_id, "cancellation_id" => id})
         ) do
      {:ok, job} -> job
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp key(suffix, id), do: "plan-cancellation-#{suffix}:#{id}"

  defp now(opts),
    do:
      Keyword.get_lazy(opts, :now, fn ->
        Shoestring.Harness.Clock.now(Keyword.get(opts, :clock, Shoestring.Harness.SystemClock))
      end)
end
