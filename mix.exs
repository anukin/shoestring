defmodule Shoestring.MixProject do
  use Mix.Project

  def project do
    [
      app: :shoestring,
      version: "0.2.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: [
        shoestring: [
          include_erts: true,
          include_executables_for: [:unix],
          cookie: "shoestring_distribution_disabled",
          steps: [&prepare_release/1, :assemble, &seal_release/1]
        ]
      ]
    ]
  end

  defp prepare_release(release) do
    unless :os.type() == {:unix, :darwin} and
             String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64") do
      Mix.raise("Only natively built macOS arm64 releases are supported")
    end

    Mix.Task.run("assets.deploy", [])
    release
  end

  defp seal_release(release) do
    helper =
      Path.join([
        release.path,
        "lib",
        "shoestring-#{release.version}",
        "priv",
        "bin",
        "shoestring-terminal"
      ])

    {os_version, 0} = System.cmd("/usr/bin/sw_vers", ["-productVersion"])
    {revision, status} = System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true)

    {_, dirty_status} =
      System.cmd("git", ["diff", "--quiet", "HEAD", "--"], stderr_to_stdout: true)

    revision =
      if status == 0 and Regex.match?(~r/\A[0-9a-f]{40}\s*\z/, revision),
        do: String.trim(revision),
        else: "unknown"

    manifest = %{
      "format" => "shoestring-release",
      "version" => 1,
      "application_version" => release.version,
      "target" => "aarch64-apple-darwin",
      "tested_macos" => String.trim(os_version),
      "source_revision" => revision,
      "source_dirty" => dirty_status != 0,
      "erts" => to_string(:erlang.system_info(:version)),
      "terminal_protocol" => Shoestring.Terminal.Protocol.version(),
      "helper_version" => Shoestring.Terminal.Protocol.helper_version(),
      "helper_sha256" => :crypto.hash(:sha256, File.read!(helper)) |> Base.encode16(case: :lower),
      "files_sha256" =>
        Path.wildcard(Path.join(release.path, "**/*"), match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(
          &(Path.basename(&1) == "manifest.json" and Path.dirname(&1) == release.path)
        )
        |> Map.new(fn path ->
          {Path.relative_to(path, release.path),
           :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
        end),
      "external_runtime_dependencies" => ["openssl@3", "git", "python3"],
      "openssl_library" => openssl_library!(release.path),
      "distribution" => "disabled",
      "signing" => "no_developer_id_or_notarization"
    }

    File.write!(Path.join(release.path, "manifest.json"), Jason.encode!(manifest, pretty: true))
    File.chmod!(Path.join(release.path, "bin/shoestringctl"), 0o755)
    release
  end

  # The bundled crypto NIF links OpenSSL 3 at an absolute path. Record it so
  # the launcher can name a missing dependency instead of crashing at load.
  defp openssl_library!(path) do
    [nif] = Path.wildcard(Path.join(path, "lib/crypto-*/priv/lib/crypto.so"))
    {output, 0} = System.cmd("/usr/bin/otool", ["-L", nif])

    case Regex.run(~r{^\s+(/\S+/libcrypto\.3\.dylib)\s}m, output) do
      [_, library] -> library
      _ -> Mix.raise("The crypto NIF does not link a recognised OpenSSL 3 library")
    end
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
      preferred_envs: [precommit: :test, "test.partitioned": :test]
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
      "assets.deploy": ["terminal.build", "phx.digest"],
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "terminal.check",
        "test.partitioned",
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
