defmodule Shoestring.Test.WakeupConflictRepo do
  @moduledoc """
  Models a scheduler that read an absent key before another delivery settled
  it. Only its first lookup is stale; the insert uses the real Repo and real
  unique index. No wake/goal/run state is synthesized or mutated here.
  """
  use Agent

  alias Shoestring.Cobbler.WakeupRecord
  alias Shoestring.Repo

  def start_link(opts) do
    Agent.start_link(
      fn ->
        %{key: Keyword.fetch!(opts, :key), owner: Keyword.fetch!(opts, :owner), missed: false}
      end,
      name: __MODULE__
    )
  end

  def get_by(WakeupRecord = schema, clauses) do
    {miss?, owner} =
      Agent.get_and_update(__MODULE__, fn state ->
        miss? = clauses[:idempotency_key] == state.key and not state.missed
        {{miss?, state.owner}, %{state | missed: state.missed or miss?}}
      end)

    if miss? do
      send(owner, :stale_wakeup_lookup)
      nil
    else
      Repo.get_by(schema, clauses)
    end
  end

  def transaction(multi) do
    result = Repo.transaction(multi)

    case result do
      {:error, :wakeup, %Ecto.Changeset{errors: errors}, _} ->
        if Enum.any?(errors, fn {field, {_message, opts}} ->
             field == :idempotency_key and opts[:constraint] == :unique
           end) do
          send(Agent.get(__MODULE__, & &1.owner), :database_wakeup_unique_conflict)
        end

      _ ->
        :ok
    end

    result
  end

  defdelegate get(schema, id), to: Repo
  defdelegate aggregate(query, aggregate, field), to: Repo
end
