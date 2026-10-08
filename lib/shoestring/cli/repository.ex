defmodule Shoestring.CLI.Repository do
  @moduledoc "Repository-only CLI startup; no application workers or provider monitors."

  def with_repo(fun) do
    Shoestring.State.ensure_writable_root!()
    Shoestring.State.configure_repo!()
    previous = Application.fetch_env!(:shoestring, Shoestring.Repo)

    Application.put_env(
      :shoestring,
      Shoestring.Repo,
      previous |> Keyword.put(:log, false) |> Keyword.put(:pool, DBConnection.ConnectionPool)
    )

    try do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(
          Shoestring.Repo,
          fn repo ->
            Ecto.Migrator.run(repo, :up, all: true, log: false)
            fun.(repo)
          end,
          pool_size: 1
        )

      result
    after
      Application.put_env(:shoestring, Shoestring.Repo, previous)
    end
  end
end
