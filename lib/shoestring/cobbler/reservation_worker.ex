defmodule Shoestring.Cobbler.ReservationWorker do
  @moduledoc "Service-owned delivery for explicit reservation recovery; no provider calls."
  use Oban.Worker,
    queue: :reservation_control,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete, keys: [:operation_id]]

  def perform(%Oban.Job{args: %{"operation_id" => id}}) do
    case Shoestring.Cobbler.ReservationControl.perform(id) do
      {:ok, _} -> :ok
      {:error, :operation_authority_mismatch} -> {:cancel, :operation_authority_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_), do: {:cancel, :invalid_reservation_job}
end
