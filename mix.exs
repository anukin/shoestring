defmodule Shoestring.MixProject do
  use Mix.Project

  def project do
    [
      app: :shoestring,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Shoestring.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:oban, "~> 2.24.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:req, "~> 0.7"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "shoestring.state.prepare", "ecto.setup"],
      "db.setup": ["shoestring.state.prepare", "ecto.create", "ecto.migrate"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "ecto.migrate": &one_connection("ecto.migrate", &1),
      "ecto.rollback": &one_connection("ecto.rollback", &1),
      test: ["shoestring.state.prepare", "ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.deploy": ["phx.digest"],
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test",
        "gate_0a.node_test",
        "ui.node_test"
      ]
    ]
  end

  # Historical SQLite rebuilds switch connection-local PRAGMAs and rely on one
  # connection's schema view, so migrations run on a single connection, as
  # Shoestring.Release.migrate/0 and the CLI already do. The task's default
  # pool of 2 left fresh databases half-rebuilt. The test SQL sandbox shares
  # its connections and cannot run the migrator on one, so test keeps the
  # default. A caller's own --pool-size comes later and wins.
  defp one_connection(task, args) do
    args = if Mix.env() == :test, do: args, else: ["--pool-size", "1" | args]
    Mix.Task.run(task, args)
  end
end
