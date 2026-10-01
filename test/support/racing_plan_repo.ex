defmodule Shoestring.Test.RacingPlanRepo do
  @moduledoc """
  Hermetic fault-injection repo that reproduces ONE lost idempotency race
  deterministically, with no concurrency and no sleeping.

  It delegates every call to `Shoestring.Repo` except the goal-scoped
  decision lookup in `Shoestring.Cobbler.Plans`, which — once, when armed —
  answers `nil` even though a row exists.

  That is exactly what a writer observes when its read of
  `cobbler_plan_decisions` happens before a competing writer's commit
  becomes visible: it concludes the decision id is new, and its INSERT then
  meets the `(goal_id, decision_id)` unique index. Simulating the stale read
  is what makes the window testable at all — racing two real writers only
  reproduces it when the scheduler cooperates, and `mode: :immediate` hides
  it entirely on a connection that actually takes SQLite's write lock.

  The window is not hypothetical: inside an enclosing transaction — the
  ExUnit SQL sandbox, or any caller that wraps this store in its own
  transaction — Exqlite issues a SAVEPOINT rather than `BEGIN IMMEDIATE`,
  so no write lock is taken and nothing serializes the read against the
  write.

  Never backed by its own database and never touches the network.
  """

  @armed_key :racing_plan_repo_armed

  @doc "Arms exactly one stale decision read. Disarms itself when it fires."
  @spec lose_next_decision_read() :: :ok
  def lose_next_decision_read, do: arm("cobbler_plan_decisions")

  @doc """
  Arms exactly one stale proposal read — the twin window on the propose
  side, where `(goal_id, proposal_id)` is read before the insert.
  """
  @spec lose_next_revision_read() :: :ok
  def lose_next_revision_read, do: arm("cobbler_plan_revisions")

  @doc "True while a stale read is still armed."
  @spec armed?() :: boolean()
  def armed?, do: Process.get(@armed_key) != nil

  defp arm(source) do
    Process.put(@armed_key, source)
    :ok
  end

  def one(%Ecto.Query{from: %{source: {source, _schema}}} = query) do
    if Process.get(@armed_key) == source do
      Process.delete(@armed_key)
      nil
    else
      Shoestring.Repo.one(query)
    end
  end

  def one(query), do: Shoestring.Repo.one(query)

  defdelegate all(query), to: Shoestring.Repo
  defdelegate exists?(query), to: Shoestring.Repo
  defdelegate insert(changeset), to: Shoestring.Repo
  defdelegate update(changeset), to: Shoestring.Repo
  defdelegate rollback(reason), to: Shoestring.Repo
  defdelegate transaction(fun, opts), to: Shoestring.Repo
end
