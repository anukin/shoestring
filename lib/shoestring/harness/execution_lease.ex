defmodule Shoestring.Harness.ExecutionLease do
  @moduledoc "Versioned admission grant, budget, and safe checkpoint cadence."

  alias Shoestring.Harness.Contract

  @version 1
  @renewal_states [:none, :eligible, :due, :renewed, :expired, :revoked]

  @enforce_keys [
    :version,
    :grant_id,
    :run_id,
    :admitted_snapshot_id,
    :reserves,
    :response_budget,
    :tool_budget,
    :deadline,
    :checkpoint_cadence,
    :renewal_state,
    :extensions
  ]
  defstruct [
    :version,
    :grant_id,
    :run_id,
    :admitted_snapshot_id,
    :reserves,
    :response_budget,
    :tool_budget,
    :deadline,
    :checkpoint_cadence,
    :renewal_state,
    :extensions
  ]

  @type t :: %__MODULE__{
          version: 1,
          grant_id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t(),
          admitted_snapshot_id: Ecto.UUID.t(),
          reserves: %{response: non_neg_integer(), tool: non_neg_integer()},
          response_budget: pos_integer(),
          tool_budget: pos_integer(),
          deadline: DateTime.t(),
          checkpoint_cadence: pos_integer(),
          renewal_state: atom(),
          extensions: map()
        }

  @spec version() :: 1
  def version, do: @version

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, version} <- Contract.version(attrs, @version),
         {:ok, grant_id} <-
           attrs |> Contract.required(:grant_id) |> then(&uuid_result(&1, :grant_id)),
         {:ok, run_id} <- attrs |> Contract.required(:run_id) |> then(&uuid_result(&1, :run_id)),
         {:ok, admitted_snapshot_id} <-
           attrs
           |> Contract.required(:admitted_snapshot_id)
           |> then(&uuid_result(&1, :admitted_snapshot_id)),
         {:ok, reserves} <- attrs |> Contract.required(:reserves) |> then(&reserves/1),
         {:ok, response_budget} <-
           attrs
           |> Contract.required(:response_budget)
           |> then(&Contract.positive_integer(&1, :response_budget)),
         {:ok, tool_budget} <-
           attrs
           |> Contract.required(:tool_budget)
           |> then(&Contract.positive_integer(&1, :tool_budget)),
         {:ok, deadline} <-
           attrs |> Contract.required(:deadline) |> then(&datetime_result(&1, :deadline)),
         {:ok, checkpoint_cadence} <-
           attrs
           |> Contract.required(:checkpoint_cadence)
           |> then(&Contract.positive_integer(&1, :checkpoint_cadence)),
         {:ok, renewal_state} <-
           attrs
           |> Contract.required(:renewal_state)
           |> then(&Contract.enum(&1, :renewal_state, @renewal_states)),
         {:ok, extensions} <-
           attrs |> Contract.optional(:extensions) |> then(&Contract.extensions/1) do
      {:ok,
       %__MODULE__{
         version: version,
         grant_id: grant_id,
         run_id: run_id,
         admitted_snapshot_id: admitted_snapshot_id,
         reserves: reserves,
         response_budget: response_budget,
         tool_budget: tool_budget,
         deadline: deadline,
         checkpoint_cadence: checkpoint_cadence,
         renewal_state: renewal_state,
         extensions: extensions
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:base, "must be an object")

  defp uuid_result({:ok, value}, field), do: Contract.uuid(value, field)
  defp uuid_result(error, _field), do: error
  defp datetime_result({:ok, value}, field), do: Contract.datetime(value, field)
  defp datetime_result(error, _field), do: error

  defp reserves(value) when is_map(value) do
    with {:ok, response} <-
           value
           |> Contract.required(:response)
           |> then(&Contract.nonnegative_integer(&1, :response_reserve)),
         {:ok, tool} <-
           value
           |> Contract.required(:tool)
           |> then(&Contract.nonnegative_integer(&1, :tool_reserve)),
         true <- Enum.all?(Map.keys(value), &(to_string(&1) in ["response", "tool"])) do
      {:ok, %{response: response, tool: tool}}
    else
      false -> Contract.invalid(:reserves, "contains unsupported fields")
      error -> error
    end
  end

  defp reserves({:ok, value}), do: reserves(value)

  defp reserves(_value), do: Contract.invalid(:reserves, "must be an object")
end
