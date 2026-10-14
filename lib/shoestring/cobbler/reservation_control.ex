defmodule Shoestring.Cobbler.ReservationControl do
  @moduledoc "Durable human recovery requests; the service, never a repository-only CLI, probes ownership."
  import Ecto.Query

  alias Shoestring.Cobbler.{
    ReservationOperationRecord,
    ReservationRecord,
    ReservationRecovery,
    Reservations,
    ReservationWorker,
    ReservationWriter
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  def request(reservation_id, action, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, id} <- Ecto.UUID.cast(attrs[:command_id]),
         {:ok, reservation_id} <- Ecto.UUID.cast(reservation_id),
         true <- action in ["reconcile", "cancel-unstarted"],
         by when is_binary(by) <- attrs[:requested_by],
         true <- Regex.match?(~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/, by),
         true <- Shoestring.Harness.Contract.safe_term?(by),
         %ReservationRecord{} = owner <- repo.get(ReservationRecord, reservation_id) do
      transact(repo, owner.goal_id, opts, fn ->
        existing = repo.get(ReservationOperationRecord, id)

        operation =
          if existing do
            if {existing.reservation_id, existing.action, existing.requested_by} !=
                 {reservation_id, action, by},
               do: repo.rollback(:operation_conflict)

            authorize!(repo, owner, existing)
            existing
          else
            event =
              append!(
                repo,
                owner,
                "requested",
                id,
                %{
                  "operation_id" => id,
                  "reservation_id" => owner.id,
                  "action" => action,
                  "requested_by" => by
                },
                opts
              )

            ReservationOperationRecord.request(%{
              id: id,
              reservation_id: owner.id,
              action: action,
              requested_by: by,
              request_event_id: event.id,
              inserted_at: now(opts),
              updated_at: now(opts)
            })
            |> repo.insert!()
          end

        job = if operation.status == "pending", do: enqueue!(operation.id, opts)

        %{
          operation_id: operation.id,
          status: operation.status,
          job_id: job && job.id,
          repaired?: not is_nil(job) and not job.conflict?,
          result:
            if(operation.status == "completed", do: completed_result!(repo, owner, operation))
        }
      end)
    else
      nil -> {:error, :reservation_not_found}
      _ -> {:error, :invalid_reservation_operation}
    end
  end

  def perform(id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, id} <- Ecto.UUID.cast(id),
         %ReservationOperationRecord{} = operation <- repo.get(ReservationOperationRecord, id),
         %ReservationRecord{} = owner <- repo.get(ReservationRecord, operation.reservation_id) do
      ReservationWriter.run(repo, fn ->
        transact(repo, owner.goal_id, opts, fn ->
          operation = repo.get!(ReservationOperationRecord, id)
          authorize!(repo, owner, operation)

          case operation.status do
            "completed" ->
              completed_result!(repo, owner, operation)

            "pending" ->
              runtime_opts = Keyword.put(opts, :now, now(opts))

              result =
                case operation.action do
                  "reconcile" ->
                    case Reservations.reconcile(owner.id, runtime_opts) do
                      {:ok, result} -> result
                      {:error, reason} -> repo.rollback(reason)
                    end

                  "cancel-unstarted" ->
                    ReservationRecovery.cancel_unstarted(
                      repo.get!(ReservationRecord, owner.id),
                      id,
                      runtime_opts
                    )
                end

              output = %{
                "disposition" => to_string(result.disposition),
                "reason" => to_string(result.reason),
                "settlement_kind" => result.settlement && result.settlement.kind
              }

              if result.reason == :never_started_intent_fenced do
                case Shoestring.Harness.Projector.project(owner.goal_id,
                       clock: Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
                     ) do
                  {:ok, _} -> :ok
                  {:error, reason} -> repo.rollback(reason)
                end
              end

              append!(
                repo,
                owner,
                "completed",
                id,
                %{"operation_id" => id, "reservation_id" => owner.id, "result" => output},
                opts
              )

              operation
              |> Ecto.Changeset.change(status: "completed", result: output, updated_at: now(opts))
              |> repo.update!()

              output

            _ ->
              repo.rollback(:operation_authority_mismatch)
          end
        end)
      end)
    else
      _ -> {:error, :operation_not_found}
    end
  end

  def repair(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    operations = repo.all(from o in ReservationOperationRecord, where: o.status == "pending")

    Enum.reduce(operations, %{repaired_count: 0, failures: []}, fn operation, acc ->
      case request(
             operation.reservation_id,
             operation.action,
             %{command_id: operation.id, requested_by: operation.requested_by},
             opts
           ) do
        {:ok, %{repaired?: true}} -> Map.update!(acc, :repaired_count, &(&1 + 1))
        {:ok, _} -> acc
        {:error, _} -> Map.update!(acc, :failures, &[operation.id | &1])
      end
    end)
    |> then(&{:ok, &1})
  end

  defp completed_result!(repo, owner, operation) do
    completed =
      repo.get_by(TrajectoryEvent,
        goal_id: owner.goal_id,
        idempotency_key: key("completed", operation.id)
      )

    unless completed && completed.type == "cobbler.reservation.operation.completed" &&
             completed.payload == %{
               "operation_id" => operation.id,
               "reservation_id" => owner.id,
               "result" => operation.result
             },
           do: repo.rollback(:operation_authority_mismatch)

    operation.result
  end

  defp authorize!(repo, owner, operation) do
    event = repo.get(TrajectoryEvent, operation.request_event_id)

    completed? =
      repo.exists?(
        from e in TrajectoryEvent,
          where:
            e.goal_id == ^owner.goal_id and e.idempotency_key == ^key("completed", operation.id)
      )

    unless operation.status in ["pending", "completed"] and
             (operation.status == "completed" or not completed?),
           do: repo.rollback(:operation_authority_mismatch)

    payload = %{
      "operation_id" => operation.id,
      "reservation_id" => owner.id,
      "action" => operation.action,
      "requested_by" => operation.requested_by
    }

    unless event && event.goal_id == owner.goal_id &&
             event.type == "cobbler.reservation.operation.requested" &&
             event.idempotency_key == key("requested", operation.id) && event.payload == payload,
           do: repo.rollback(:operation_authority_mismatch)
  end

  defp append!(repo, owner, suffix, id, payload, opts) do
    case Trajectory.append(
           owner.goal_id,
           %{
             "type" => "cobbler.reservation.operation.#{suffix}",
             "schema_version" => 1,
             "actor" => "cobbler",
             "occurred_at" => now(opts),
             "idempotency_key" => key(suffix, id),
             "payload" => payload
           },
           writer_opts: [transaction_repo: repo]
         ) do
      {:ok, event} -> event
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp key(suffix, id), do: "reservation-operation-#{suffix}:#{id}"

  defp now(opts),
    do:
      Keyword.get_lazy(opts, :now, fn ->
        Shoestring.Harness.Clock.now(Keyword.get(opts, :clock, Shoestring.Harness.SystemClock))
      end)

  defp enqueue!(id, opts) do
    case Oban.insert(
           Keyword.get(opts, :oban, Oban),
           ReservationWorker.new(%{"operation_id" => id})
         ) do
      {:ok, job} -> job
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transact(repo, goal_id, _opts, fun) do
    nested? = repo.in_transaction?()

    case repo.transaction(
           fn ->
             sequence =
               repo.one(
                 from e in TrajectoryEvent, where: e.goal_id == ^goal_id, select: max(e.sequence)
               ) || 0

             result = fun.()

             events =
               repo.all(
                 from e in TrajectoryEvent,
                   where: e.goal_id == ^goal_id and e.sequence > ^sequence,
                   order_by: [asc: e.sequence]
               )

             {result, events}
           end,
           mode: :immediate
         ) do
      {:ok, {result, events}} ->
        if not nested? and Process.whereis(Shoestring.PubSub),
          do:
            Enum.each(
              events,
              &Phoenix.PubSub.broadcast(
                Shoestring.PubSub,
                Trajectory.topic(goal_id),
                {:trajectory_event_committed, &1}
              )
            )

        {:ok, result}

      error ->
        error
    end
  end
end
