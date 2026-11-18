defmodule Shoestring.DispatchSetup do
  @moduledoc """
  Runs a dispatch's setup script in an isolated, private installation directory.

  The setup process has no network access. Its output is never returned.
  Attempts use private directories, and a successful attempt is published
  atomically for the dispatch and script.
  """

  alias Shoestring.Cobbler.GateProcess
  alias Shoestring.DispatchSetup.Downloads
  alias Shoestring.Harness.CodexAppServer.GitSandbox
  alias Shoestring.Harness.Security
  alias Shoestring.State

  @max_script_bytes 65_536
  @timeout_ms 300_000
  @max_output_bytes 1_048_576
  @sandbox "/usr/bin/sandbox-exec"

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%{"script" => script} = setup) when is_binary(script) do
    downloads = Map.get(setup, "downloads", [])

    if Map.keys(setup) -- ["script", "downloads"] == [] and
         byte_size(script) > 0 and byte_size(script) <= @max_script_bytes and
         String.valid?(script) and not String.contains?(script, <<0>>) and
         Security.redact_retained(script) == script and
         Downloads.validate(downloads) == :ok do
      :ok
    else
      {:error, :invalid_setup}
    end
  end

  def validate(_), do: {:error, :invalid_setup}

  @spec cached_root(term(), term()) :: {:ok, Path.t()} | {:error, atom()}
  def cached_root(dispatch_id, setup) do
    with :ok <- validate(setup),
         {:ok, key} <- key(dispatch_id, setup) do
      lookup(key)
    end
  end

  @spec prepare(term(), term()) :: {:ok, Path.t()} | {:error, atom()}
  def prepare(dispatch_id, setup) do
    with :ok <- validate(setup),
         {:ok, key} <- key(dispatch_id, setup),
         :ok <- mechanism() do
      case :global.trans({{__MODULE__, key}, self()}, fn -> prepare_once(key, setup) end, [node()]) do
        :aborted -> {:error, :setup_failed}
        result -> result
      end
    end
  end

  defp prepare_once(key, setup) do
    case lookup(key) do
      {:error, :not_cached} -> run(key, setup)
      result -> result
    end
  end

  defp key(id, setup) when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 512 do
    {:ok,
     :crypto.hash(:sha256, :erlang.term_to_binary({id, setup})) |> Base.encode16(case: :lower)}
  end

  defp key(_, _), do: {:error, :invalid_dispatch}

  defp base, do: Path.join(State.root(), "dispatch-setups") |> GitSandbox.physical_path()
  defp bucket(key), do: Path.join(base(), key)
  defp marker(key), do: Path.join(bucket(key), "ready")

  defp lookup(key) do
    case File.read(marker(key)) do
      {:error, :enoent} -> {:error, :not_cached}
      {:ok, name} -> cached_attempt(key, name)
      _ -> {:error, :invalid_cache}
    end
  end

  defp cached_attempt(key, name) do
    with true <- Regex.match?(~r/\Aattempt-[0-9a-f]{32}\z/, name),
         root = Path.join(bucket(key), name),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.join(root, "bin")) do
      {:ok, root}
    else
      _ -> {:error, :invalid_cache}
    end
  end

  defp mechanism do
    if :os.type() == {:unix, :darwin} and File.regular?(@sandbox),
      do: :ok,
      else: {:error, :sandbox_unavailable}
  end

  defp run(key, setup) do
    name = "attempt-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    root = Path.join(bucket(key), name)
    inputs = Path.join(bucket(key), "inputs-" <> String.replace_prefix(name, "attempt-", ""))

    with true <- quotable?(root),
         :ok <- File.mkdir_p(bucket(key)),
         :ok <- File.chmod(bucket(key), 0o700),
         :ok <- File.mkdir(inputs),
         :ok <- File.chmod(inputs, 0o700),
         :ok <- Downloads.prepare(Map.get(setup, "downloads", []), inputs),
         :ok <- File.write(Path.join(inputs, ".setup-script"), setup["script"], [:exclusive]),
         :ok <- File.mkdir(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.mkdir(Path.join(root, "bin")),
         {:ok, %{exit_status: 0}} <-
           GateProcess.run(
             argv(root, inputs),
             root,
             @timeout_ms,
             @max_output_bytes
           ),
         {:ok, ^root} <- cached_attempt(key, name),
         :ok <- publish(key, name),
         {:ok, cached} <- lookup(key) do
      {:ok, cached}
    else
      _ -> {:error, :setup_failed}
    end
  end

  defp publish(key, name) do
    temp =
      Path.join(
        bucket(key),
        "marker-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )

    with :ok <- File.write(temp, name, [:exclusive]),
         result <- File.ln(temp, marker(key)) do
      case result do
        :ok -> :ok
        {:error, :eexist} -> :ok
        _ -> {:error, :publish_failed}
      end
    end
  end

  defp argv(root, inputs) do
    [
      @sandbox,
      "-p",
      profile(root, inputs),
      "/usr/bin/env",
      "-i",
      "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME=" <> root,
      "TMPDIR=" <> root,
      "SHOESTRING_SETUP_DIR=" <> root,
      "SHOESTRING_SETUP_DOWNLOADS=" <> inputs,
      "/bin/sh",
      "-e",
      Path.join(inputs, ".setup-script")
    ]
  end

  defp profile(root, inputs) do
    """
    (version 1)
    (deny default)
    (allow process-exec)
    (allow process-fork)
    (allow sysctl-read)
    (allow file-read-metadata)
    (allow file-read* (literal "/") (subpath "/System") (subpath "/usr/bin") (subpath "/usr/lib")
      (subpath "/usr/libexec") (subpath "/bin") (subpath "/sbin")
      (literal "/dev/null") (literal "/dev/zero") (literal "/dev/random")
      (literal "/dev/urandom") (subpath "/dev/fd") (subpath "#{root}") (subpath "#{inputs}"))
    (deny file-write*)
    (allow file-write* (subpath "#{root}") (literal "/dev/null") (regex #"^/dev/fd/"))
    """
  end

  defp quotable?(path) do
    String.starts_with?(path, "/") and not String.contains?(path, ["\"", "\\"]) and
      not String.match?(path, ~r/[[:cntrl:]]/u)
  end
end
