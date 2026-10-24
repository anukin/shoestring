defmodule Shoestring.Release.Doctor do
  @moduledoc "Bounded local release checks. Provider discovery is passive; credentials are never inspected."
  alias Shoestring.Harness.Capacity.Registry
  alias Shoestring.Terminal.Protocol
  @helper_version Protocol.helper_version()

  def report do
    manifest = manifest()
    helper = helper_check(manifest)

    %{
      "version" => 1,
      "application_version" => to_string(Application.spec(:shoestring, :vsn)),
      "target" => if(supported?(), do: "aarch64-apple-darwin", else: "unsupported"),
      "manifest" => if(is_map(manifest), do: "present", else: "missing_or_invalid"),
      "helper" => helper,
      "git" => installed("git"),
      "python3" => installed("python3"),
      "providers" =>
        Map.new(
          ~w(claude codex),
          &{&1, %{"installation" => installed(&1), "authentication" => "not_checked"}}
        ),
      "endpoint_secret" =>
        Shoestring.Release.Bootstrap.status(
          Shoestring.State.root(),
          System.get_env("SECRET_KEY_BASE")
        ),
      "database" => database_check(),
      "port" => port_check(),
      "forecast_enforcement" => "disabled",
      "api_dispatch" =>
        if(match?({:ok, _}, Shoestring.Harness.HTTP.Providers.configuration("openai_responses")),
          do: "configured",
          else: "disabled_or_refused"
        )
    }
  end

  @agents [{"claude", :headless_stream_json}, {"codex", :app_server_stdio}]

  @doc """
  Whether each supported agent CLI can take task work, without inference:
  `binary_missing`, `not_checked` (installed; run `doctor --probe-providers`
  to check it), `needs_sign_in`, `version_untested` (outside the versions its
  worker mode was tested with), `ready`, or `unknown`. `probes` is
  `Shoestring.Release.ProviderProbe.report/1`, or `nil` for the passive
  doctor, which runs no provider command. `find` locates an executable.
  """
  def agents(probes \\ nil, find \\ &System.find_executable/1) do
    Map.new(@agents, fn {name, mode} ->
      {:ok, entry} = Registry.lookup(name, mode)
      probe = probes && probes[name]
      version = probe && probe["cli_version"]

      readiness =
        cond do
          is_nil(find.(name)) -> "binary_missing"
          is_nil(probe) -> "not_checked"
          probe["authentication"] == "reported_unauthenticated" -> "needs_sign_in"
          is_nil(version) -> "unknown"
          not Registry.tested_version?(entry, version) -> "version_untested"
          probe["authentication"] == "reported_authenticated" -> "ready"
          true -> "unknown"
        end

      {name,
       %{
         "readiness" => readiness,
         "cli_version" => version,
         "worker_mode" => Atom.to_string(mode),
         "tested_versions" => entry.tested_versions
       }}
    end)
  end

  def supported? do
    :os.type() == {:unix, :darwin} and
      String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64")
  end

  def manifest do
    root = System.get_env("RELEASE_ROOT")

    with true <- is_binary(root),
         {:ok, %{size: size}} when size <= 1_048_576 <-
           File.stat(Path.join(root, "manifest.json")),
         {:ok, bytes} <- File.read(Path.join(root, "manifest.json")),
         {:ok, %{"format" => "shoestring-release", "version" => 1} = value} <- Jason.decode(bytes) do
      value
    else
      _ -> nil
    end
  end

  def helper_check(manifest) when is_map(manifest) do
    with true <- manifest["target"] == "aarch64-apple-darwin" and supported?(),
         true <- manifest["application_version"] == to_string(Application.spec(:shoestring, :vsn)),
         true <- manifest["terminal_protocol"] == Protocol.version(),
         true <- manifest["helper_version"] == Protocol.helper_version(),
         {:ok, path} <- Shoestring.Terminal.Launch.helper(),
         {:ok, %{type: :regular, size: size}} when size > 0 and size <= 32 * 1024 * 1024 <-
           File.stat(path),
         {:ok, bytes} <- File.read(path),
         true <-
           Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == manifest["helper_sha256"],
         :ok <- handshake(path) do
      "compatible"
    else
      _ -> "missing_or_incompatible"
    end
  end

  def helper_check(_), do: "manifest_required"

  def handshake(path) do
    previous = Process.flag(:trap_exit, true)

    try do
      port =
        Port.open({:spawn_executable, String.to_charlist(path)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: []
        ])

      try do
        {:ok, hello} = Protocol.encode(%{"op" => "hello", "version" => Protocol.version()})
        true = Port.command(port, hello)
        read_hello(port, "", System.monotonic_time(:millisecond) + 2_000)
      after
        if Port.info(port), do: Port.close(port)
      end
    rescue
      _ -> {:error, :helper_incompatible}
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp read_hello(port, buffer, deadline) do
    receive do
      {^port, {:data, data}} ->
        case Protocol.feed(buffer, data) do
          {:ok,
           [
             %{
               "op" => "hello",
               "version" => 1,
               "helper_version" => version,
               "max_frame" => 65_536
             }
           ], ""}
          when version == @helper_version ->
            :ok

          {:ok, [], rest} ->
            read_hello(port, rest, deadline)

          _ ->
            {:error, :helper_incompatible}
        end

      {^port, {:exit_status, _}} ->
        {:error, :helper_incompatible}

      {:EXIT, ^port, _} ->
        {:error, :helper_incompatible}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :helper_timeout}
    end
  end

  defp database_check do
    if File.regular?(Shoestring.State.database_path()) do
      Shoestring.CLI.Repository.with_existing_repo(fn repo ->
        case repo.query("PRAGMA quick_check", [], log: false) do
          {:ok, %{rows: [["ok"]]}} -> "ok"
          _ -> "needs_attention"
        end
      end)
    else
      "needs_init"
    end
  rescue
    _ -> "unavailable"
  end

  defp installed(name), do: if(System.find_executable(name), do: "present", else: "missing")

  def port_check do
    config =
      Application.get_env(:shoestring, ShoestringWeb.Endpoint, []) |> Keyword.get(:http, [])

    port = Keyword.get(config, :port, 4000)
    ip = Keyword.get(config, :ip, {127, 0, 0, 1})

    case :gen_tcp.listen(port, [:binary, active: false, ip: ip]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        "available"

      {:error, :eaddrinuse} ->
        "in_use"

      _ ->
        "unavailable"
    end
  end
end
