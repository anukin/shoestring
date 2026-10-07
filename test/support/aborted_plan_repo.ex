defmodule Shoestring.Test.AbortedPlanRepo do
  @moduledoc """
  Injects DBConnection's documented aborted-transaction result at the repo
  boundary. Reads use the real sandbox; no write callback runs or commits.
  """
  defdelegate exists?(query), to: Shoestring.Repo
  defdelegate one(query), to: Shoestring.Repo

  def transaction(_fun, _opts), do: {:error, :rollback}
end
