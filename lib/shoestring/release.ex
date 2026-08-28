defmodule Shoestring.Release do
  @moduledoc """
  Release tasks that run without Mix or development tooling.
  """

  @app :shoestring

  @spec migrate() :: :ok
  def migrate do
    load_application()
    Shoestring.State.ensure_writable_root!()
    Shoestring.State.configure_repo!()

    for repo <- repos() do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(
          repo,
          fn started_repo ->
            Ecto.Migrator.run(started_repo, :up, all: true)
          end,
          pool_size: 1
        )
    end

    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_application do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end
end
