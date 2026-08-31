defmodule Shoestring.Harness.RunIdentity do
  @moduledoc "Normalized process and provider-session identity for one running harness."

  alias Shoestring.Harness.Contract

  @enforce_keys [:run_id, :harness_id, :process_id, :provider_session_id]
  defstruct [:run_id, :harness_id, :process_id, :provider_session_id]

  @type t :: %__MODULE__{
          run_id: Ecto.UUID.t(),
          harness_id: String.t(),
          process_id: String.t() | nil,
          provider_session_id: String.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, run_id} <- attrs |> Contract.required(:run_id) |> then(&uuid_result(&1, :run_id)),
         {:ok, harness_id} <-
           attrs
           |> Contract.required(:harness_id)
           |> then(&Contract.text(&1, :harness_id, max: 200)),
         {:ok, process_id} <-
           attrs |> Contract.optional(:process_id) |> then(&optional_text(&1, :process_id)),
         {:ok, provider_session_id} <-
           attrs
           |> Contract.optional(:provider_session_id)
           |> then(&optional_text(&1, :provider_session_id)) do
      {:ok,
       %__MODULE__{
         run_id: run_id,
         harness_id: harness_id,
         process_id: process_id,
         provider_session_id: provider_session_id
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:base, "must be an object")

  defp uuid_result({:ok, value}, field), do: Contract.uuid(value, field)
  defp uuid_result(error, _field), do: error
  defp optional_text(nil, _field), do: {:ok, nil}
  defp optional_text({:ok, value}, field), do: optional_text(value, field)
  defp optional_text(value, field), do: Contract.text(value, field, max: 500)
end
