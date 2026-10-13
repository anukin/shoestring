defmodule Shoestring.Cobbler.ReservationPolicy do
  @moduledoc """
  Operator-configured allowances for iteration 7, independent of model output.

  Units are conservative concurrency weights, never predicted token usage or
  provider percentages. Provider limits and units apply to a shared local
  `{provider, submission scope}` account bucket until account discovery exists.
  The same policy must govern all held reservations; changing it while owners
  remain unresolved requires reconciliation, never eviction.
  """
  alias Shoestring.Harness.Contract

  defstruct version: 1,
            global_limit: 1,
            provider_account_limit: 1,
            goal_limit: 1,
            account_units: 1,
            task_units: 1

  @fields [:global_limit, :provider_account_limit, :goal_limit, :account_units, :task_units]

  def new(attrs \\ %{})

  def new(attrs) when is_map(attrs) do
    defaults = %__MODULE__{}

    values =
      Map.new(@fields, fn key ->
        {key, Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), Map.fetch!(defaults, key)))}
      end)

    cond do
      Map.get(attrs, :version, Map.get(attrs, "version", 1)) != 1 ->
        Contract.invalid(:version, "must equal 1")

      Enum.any?(values, fn {_key, value} -> not (is_integer(value) and value in 1..64) end) ->
        Contract.invalid(:limits, "limits and configured weights must be integers from 1 to 64")

      values.task_units > values.account_units ->
        Contract.invalid(:task_units, "must not exceed the shared account allowance")

      true ->
        {:ok, struct!(__MODULE__, values)}
    end
  end

  def new(_), do: Contract.invalid(:policy, "must be an object")

  def to_map(%__MODULE__{} = policy) do
    policy |> Map.from_struct() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
