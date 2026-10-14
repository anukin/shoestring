defmodule Shoestring.Cobbler.ReservationContinuation do
  @moduledoc "Fresh continuation ownership; an inherited marker never authorizes a successor."
  alias Shoestring.Cobbler.{PlanDispatch, ReservationRecord, Reservations}
  alias Shoestring.Repo

  def run(nil, _child_id, _admission, opts, persist), do: persist.(opts)

  def run(parent_run, child_id, admission, opts, persist) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get_by(ReservationRecord, run_id: parent_run.id) do
      nil ->
        if Map.has_key?(parent_run.extensions || %{}, Reservations.key()),
          do: {:error, :reservation_missing},
          else: persist.(opts)

      parent ->
        attrs = %{
          id: child_id,
          run_id: child_id,
          parent_id: parent.id,
          goal_id: parent.goal_id,
          execution_id: parent.execution_id,
          plan_task_id: parent.plan_task_id,
          attempt: parent.attempt,
          admission_event_id: admission.id
        }

        # The predecessor's trusted policy governs until all owners settle.
        # Disabling/changing runtime configuration cannot bypass a held chain.
        opts =
          opts
          |> Keyword.put(:reservation_policy, parent.concurrency_policy)
          |> Keyword.put(:reservation_child_run_id, child_id)
          |> Keyword.put_new(
            :now,
            Shoestring.Harness.Clock.now(
              Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
            )
          )

        PlanDispatch.run(attrs, opts, persist)
    end
  end

  def bind(request, opts) do
    case Keyword.get(opts, :reservation_id) do
      nil -> request
      id -> %{request | extensions: Map.put(request.extensions || %{}, Reservations.key(), id)}
    end
  end
end
