defmodule Mix.Tasks.Shoestring.Agents do
  use Mix.Task
  @shortdoc "List saved agents or read a named/default immutable configuration"
  @moduledoc """
  mix shoestring.agents list
  mix shoestring.agents show [NAME] [--revision NUMBER]

  Starts only the repository. No provider, monitor, or execution process starts.
  Omitting NAME reads the saved default. A returned profile_id/revision/digest
  identifies a configuration snapshot; this task does not submit or approve work.
  """
  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [revision: :integer])
    revision = opts[:revision]

    unless invalid == [] and (is_nil(revision) or revision > 0) and
             (positional in [["show"], ["list"]] or match?(["show", _], positional)) and
             (positional != ["list"] or opts == []) do
      Mix.raise("Use list or show [NAME] [--revision positive-number]")
    end

    Shoestring.State.ensure_writable_root!()
    Shoestring.State.configure_repo!()
    previous = Application.fetch_env!(:shoestring, Shoestring.Repo)

    Application.put_env(
      :shoestring,
      Shoestring.Repo,
      previous |> Keyword.put(:log, false) |> Keyword.put(:pool, DBConnection.ConnectionPool)
    )

    try do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          Shoestring.Repo,
          fn repo ->
            Ecto.Migrator.run(repo, :up, all: true, log: false)

            case positional do
              ["list"] ->
                Enum.each(
                  Shoestring.AgentProfiles.list(),
                  &Mix.shell().info("#{&1.slug}\t#{&1.name}\trevision #{&1.revision}")
                )

              ["show"] ->
                output(Shoestring.AgentProfiles.default_snapshot(revision))

              ["show", name] ->
                output(Shoestring.AgentProfiles.snapshot(name, revision))
            end
          end, pool_size: 1)
    after
      Application.put_env(:shoestring, Shoestring.Repo, previous)
    end
  end

  defp output({:ok, snapshot}), do: Mix.shell().info(Jason.encode!(snapshot, pretty: true))

  defp output({:error, :no_default}),
    do: Mix.raise("Choose a default agent in Settings or provide its CLI name")

  defp output({:error, :not_found}), do: Mix.raise("Agent or revision not found")
end
