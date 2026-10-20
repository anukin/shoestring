defmodule Shoestring.Cobbler.PlanChildWorker do
  @moduledoc "Observe one committed child message; never admits, dispatches or replaces an Elf."
  use Oban.Worker, queue: :plan_child_inbox, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => id}}) do
    opts = Application.get_env(:shoestring, :plan_child_inbox_opts, [])

    case Shoestring.Cobbler.PlanChildInbox.process(id, opts) do
      {:ok, %{outcome: outcome}} when outcome in [:awaiting_quiescence, :awaiting_review] ->
        {:snooze, 5}

      {:ok, _} ->
        :ok

      {:error, reason}
      when reason in [
             :child_message_not_found,
             :child_message_binding_mismatch,
             :invalid_child_event_id
           ] ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(_), do: {:cancel, :invalid_child_inbox_job}
end
