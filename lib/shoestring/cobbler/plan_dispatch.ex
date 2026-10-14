defmodule Shoestring.Cobbler.PlanDispatch do
  @moduledoc """
  Opt-in atomic reservation, claim, lease and delivery for sequential plans.

  Only trusted runtime options/configuration select the reservation policy.
  No model output enables this boundary. Parallel claims remain disabled.
  The callback must only persist intent, never launch an external effect.
  """
  import Ecto.Query
  require Logger
  alias Shoestring.Cobbler.{ReservationPolicy, Reservations, ReservationWriter}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  def run(attrs, opts, persist) do
    policy =
      Keyword.get(
        opts,
        :reservation_policy,
        Application.get_env(:shoestring, :plan_reservation_policy)
      )

    case policy do
      nil ->
        persist.(opts)

      policy ->
        values =
          if match?(%ReservationPolicy{}, policy),
            do: ReservationPolicy.to_map(policy),
            else: policy

        with {:ok, policy} <- ReservationPolicy.new(values) do
          atomic(attrs, policy, opts, persist)
        end
    end
  end

  defp atomic(attrs, policy, opts, persist) do
    repo = Keyword.get(opts, :repo, Repo)
    nested? = repo.in_transaction?()

    result =
      ReservationWriter.run(repo, fn ->
        repo.transaction(
          fn ->
            sequence =
              repo.one(
                from e in TrajectoryEvent,
                  where: e.goal_id == ^attrs.goal_id,
                  select: max(e.sequence)
              ) || 0

            writer_opts =
              Keyword.put(Keyword.get(opts, :writer_opts, []), :transaction_repo, repo)

            transactional_opts =
              opts
              |> Keyword.put(:writer_opts, writer_opts)
              |> Keyword.put(:publish_fun, fn _ -> :ok end)
              |> Keyword.put(:reservation_id, attrs.id)

            with :ok <- settle_parent(attrs, repo, opts),
                 {:ok, reservation} <-
                   Reservations.hold(attrs, policy, repo: repo, now: Keyword.fetch!(opts, :now)),
                 {:ok, dispatched} <- persist.(transactional_opts) do
              events =
                repo.all(
                  from e in TrajectoryEvent,
                    where: e.goal_id == ^attrs.goal_id and e.sequence > ^sequence,
                    order_by: [asc: e.sequence]
                )

              Map.merge(dispatched, %{reservation_id: reservation.id, dispatch_events: events})
            else
              {:error, {:reservation_parent_unsettled, _} = reason} -> {:blocked, reason}
              {:error, reason} -> repo.rollback(reason)
            end
          end,
          mode: :immediate
        )
      end)

    # Nested transaction callers own the final commit and notification boundary.
    # Returned events are durable input for their eventual notification; no
    # subscriber may observe an event while an outer transaction can roll back.
    case result do
      {:ok, {:blocked, reason}} ->
        {:error, reason}

      {:ok, dispatched} ->
        unless nested?, do: Enum.each(dispatched.dispatch_events, &publish(&1, opts))
        {:ok, dispatched}

      error ->
        error
    end
  end

  defp settle_parent(%{parent_id: parent_id}, repo, opts) when not is_nil(parent_id) do
    probe_opts =
      Keyword.get(opts, :reconciliation_opts, [])
      |> Keyword.merge(repo: repo, now: Keyword.fetch!(opts, :now))

    case Reservations.reconcile(parent_id, probe_opts) do
      {:ok, %{settlement: %{kind: "consumed_closed"}}} -> :ok
      {:ok, %{reason: reason}} -> {:error, {:reservation_parent_unsettled, reason}}
      error -> error
    end
  end

  defp settle_parent(_, _, _), do: :ok

  defp publish(event, opts) do
    publish =
      Keyword.get(opts, :publish_fun, fn event ->
        Phoenix.PubSub.broadcast(
          Shoestring.PubSub,
          Shoestring.Trajectory.topic(event.goal_id),
          {:trajectory_event_committed, event}
        )
      end)

    publish.(event)
  rescue
    _ -> Logger.warning("plan dispatch committed; event notification failed")
  catch
    _, _ -> Logger.warning("plan dispatch committed; event notification failed")
  end
end
