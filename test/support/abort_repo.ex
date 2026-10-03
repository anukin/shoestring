defmodule Shoestring.Test.AbortRepo do
  @moduledoc """
  Deterministic transaction-abort simulator for the shared transaction
  helpers (`Plans.run_transaction/2`, `Planner.run_transaction/2`).

  Everything delegates to `Shoestring.Repo` except the outermost
  `transaction/2`: there the statements execute genuinely inside a real
  transaction, and then the wrapper simulates the adapter abort at
  conclude by rolling everything back and reporting the bare
  `{:error, :rollback}` reason a disconnected/aborted connection returns
  — with no sleeps and no timing involved. Nested `transaction/2` calls
  (savepoints) delegate untouched, and an intentional domain rollback
  thrown by the work itself passes through unchanged, so tests can prove
  the helpers normalize *only* the bare abort into the existing
  structured `database_busy` error while preserving domain reasons and
  success semantics.

  No production code references this module.
  """

  @backend Shoestring.Repo
  @conclude_abort :abort_repo_conclude
  @depth_key :abort_repo_depth

  @doc """
  Runs `fun` with abort-at-conclude semantics on the outermost call.

  Returns `{:error, :rollback}` exactly like an aborted adapter conclude;
  intentional domain rollbacks and raised errors propagate as the real
  transaction reports them.
  """
  @spec transaction((-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def transaction(fun, opts \\ [])

  def transaction(fun, opts) when is_function(fun, 0) and is_list(opts) do
    case Process.get(@depth_key, 0) do
      0 ->
        Process.put(@depth_key, 1)

        try do
          @backend.transaction(
            fn ->
              _ = fun.()
              @backend.rollback(@conclude_abort)
            end,
            opts
          )
          |> case do
            {:error, @conclude_abort} -> {:error, :rollback}
            other -> other
          end
        after
          Process.delete(@depth_key)
        end

      _nested ->
        @backend.transaction(fun, opts)
    end
  end

  @spec rollback(term()) :: no_return()
  def rollback(value), do: @backend.rollback(value)

  @spec insert(struct() | Ecto.Changeset.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def insert(struct_or_changeset, opts \\ []), do: @backend.insert(struct_or_changeset, opts)

  @spec update(Ecto.Changeset.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update(changeset, opts \\ []), do: @backend.update(changeset, opts)

  @spec one(Ecto.Queryable.t(), keyword()) :: term() | nil
  def one(queryable, opts \\ []), do: @backend.one(queryable, opts)

  @spec all(Ecto.Queryable.t(), keyword()) :: [term()]
  def all(queryable, opts \\ []), do: @backend.all(queryable, opts)

  @spec exists?(Ecto.Queryable.t(), keyword()) :: boolean()
  def exists?(queryable, opts \\ []), do: @backend.exists?(queryable, opts)
end
