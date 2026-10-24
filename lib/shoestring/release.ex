defmodule Shoestring.Release do
  @moduledoc """
  Release tasks that run without Mix or development tooling.
  """

  @app :shoestring

  def initialize do
    load_application()

    unless Shoestring.Release.Doctor.port_check() == "available",
      do:
        refuse(
          "Initialization refused: configured endpoint port is unavailable; stop the old service before upgrading"
        )

    _ =
      Shoestring.Release.Bootstrap.endpoint_secret!(
        Shoestring.State.root(),
        System.get_env("SECRET_KEY_BASE")
      )

    migrate()
  end

  @spec migrate() :: :ok
  def migrate do
    load_application()
    Shoestring.State.ensure_writable_root!()
    Shoestring.State.configure_repo!()

    existed? = File.regular?(Shoestring.State.database_path())

    for repo <- repos() do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(
          repo,
          fn started_repo ->
            migrations = Application.app_dir(@app, "priv/repo/migrations")

            pending? =
              Enum.any?(Ecto.Migrator.migrations(started_repo, migrations), fn {status, _, _} ->
                status == :down
              end)

            if existed? and pending? do
              case Shoestring.Release.Backup.create(started_repo, Shoestring.State.root()) do
                {:ok, _name} -> :ok
                {:error, reason} -> refuse("Migration refused: #{reason}")
              end
            end

            Ecto.Migrator.run(started_repo, migrations, :up, all: true)
          end,
          pool_size: 1
        )
    end

    :ok
  end

  def doctor do
    load_application()
    report = Shoestring.Release.Doctor.report()

    report =
      if System.get_env("SHOESTRING_DOCTOR_PROBE_PROVIDERS") == "1" do
        probes = Shoestring.Release.ProviderProbe.report()

        report
        |> Map.put("provider_probes", probes)
        |> Map.put("agents", Shoestring.Release.Doctor.agents(probes))
      else
        Map.put(report, "agents", Shoestring.Release.Doctor.agents())
      end

    report |> Jason.encode!(pretty: true) |> IO.puts()
  end

  def diagnostics_preview do
    load_application()

    print_result(
      Shoestring.CLI.Repository.with_existing_repo(fn _ -> Shoestring.Diagnostics.preview() end)
    )
  end

  def diagnostics_export do
    load_application()
    path = System.fetch_env!("SHOESTRING_DIAGNOSTIC_PATH")
    digest = System.fetch_env!("SHOESTRING_DIAGNOSTIC_CONFIRM")

    print_result(
      Shoestring.CLI.Repository.with_existing_repo(fn _ ->
        Shoestring.Diagnostics.export(path, digest)
      end)
    )
  end

  def text_enqueue do
    load_application()

    result =
      Shoestring.CLI.Repository.with_existing_repo(fn _ ->
        Shoestring.CLI.Jobs.with_client(fn client ->
          Shoestring.TextRuns.from_file(
            System.fetch_env!("SHOESTRING_TEXT_PROVIDER"),
            System.get_env("SHOESTRING_TEXT_GOAL"),
            System.get_env("SHOESTRING_TEXT_TASK"),
            System.fetch_env!("SHOESTRING_TEXT_PATH"),
            oban: client
          )
        end)
      end)

    case result do
      {:ok, dispatch, _} ->
        print_result(
          {:ok,
           %{
             goal_id: dispatch.goal_id,
             task_id: dispatch.task_id,
             dispatch_id: dispatch.dispatch_id,
             run_id: dispatch.run_id
           }}
        )

      _ ->
        refuse("Text dispatch refused; check operator policy and bounded input.")
    end
  end

  defp print_result({:ok, result}), do: result |> Jason.encode!(pretty: true) |> IO.puts()
  defp print_result({:error, reason}), do: refuse("Operation refused: #{reason}")

  # These run under `bin/shoestring eval`, where a raise prints an Elixir
  # stack trace. A refusal is an expected outcome: say why and exit 1.
  defp refuse(message) do
    IO.puts(:stderr, message)
    Application.get_env(@app, :release_halt, &System.halt/1).(1)
    # Reached only when tests inject a halt that returns.
    exit(:release_refused)
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_application do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end
end
