defmodule Shoestring.Test.PlanFaultRepo do
  @moduledoc false
  alias Shoestring.Repo
  defdelegate transaction(fun, opts), to: Repo
  defdelegate rollback(reason), to: Repo
  defdelegate get(schema, id), to: Repo
  defdelegate get_by(query, clauses), to: Repo
  defdelegate all(query), to: Repo
  defdelegate one(query), to: Repo
  defdelegate insert!(changeset), to: Repo
  def insert!(%Shoestring.Cobbler.PlanProjection{}, _opts), do: Repo.rollback(:projection_failed)
end
