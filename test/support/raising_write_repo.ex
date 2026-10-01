defmodule Shoestring.Test.RaisingWriteRepo do
  @moduledoc """
  Hermetic fault-injection repo whose first write raises a chosen exception.

  Used to prove that `Shoestring.Cobbler.Plans` keeps its structured-error
  contract against a storage layer that RAISES instead of returning — and,
  just as importantly, that the conversion is a closed list: a programming
  error must still crash loudly rather than be dressed up as a transient
  storage problem.

  Never backed by its own database and never touches the network.
  """

  @raise_key :raising_write_repo_raise

  @doc "Arms exactly one raising write. Disarms itself when it fires."
  @spec raise_next_write(:stale | :runtime) :: :ok
  def raise_next_write(kind) when kind in [:stale, :runtime] do
    Process.put(@raise_key, kind)
    :ok
  end

  def insert(changeset) do
    case Process.get(@raise_key) do
      nil ->
        Shoestring.Repo.insert(changeset)

      kind ->
        Process.delete(@raise_key)
        do_raise(kind, changeset)
    end
  end

  defp do_raise(:stale, changeset),
    do: raise(Ecto.StaleEntryError, action: :insert, changeset: changeset)

  defp do_raise(:runtime, _changeset),
    do: raise("boom: not a storage exception")

  defdelegate one(query), to: Shoestring.Repo
  defdelegate all(query), to: Shoestring.Repo
  defdelegate exists?(query), to: Shoestring.Repo
  defdelegate update(changeset), to: Shoestring.Repo
  defdelegate rollback(reason), to: Shoestring.Repo
  defdelegate transaction(fun, opts), to: Shoestring.Repo
end
