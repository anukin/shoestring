defmodule Shoestring.Toolchains do
  @moduledoc """
  Provision pinned Go distributions in the Shoestring state directory.

  Additional trusted checksums may be configured as `:toolchain_checksums`, a
  map keyed by `{version, os, arch}` with lowercase SHA-256 hex values. Only
  the official download host is used; project input cannot choose a URL.
  """

  @checksums %{
    {"1.25.3", "darwin", "arm64"} =>
      "7c083e3d2c00debfeb2f77d9a4c00a1aac97113b89b9ccc42a90487af3437382",
    {"1.25.3", "darwin", "amd64"} =>
      "1641050b422b80dfd6299f8aa7eb8798d1cd23eac7e79f445728926e881b7bcd",
    {"1.25.3", "linux", "amd64"} =>
      "0335f314b6e7bfe08c3d0cfaa7c19db961b7b99fb20be62b0a826c992ad14e0f",
    {"1.25.3", "linux", "arm64"} =>
      "1d42ebc84999b5e2069f5e31b67d6fc5d67308adad3e178d5a2ee2c9ff2001f5"
  }
  @max_archive 150_000_000
  @max_extracted 1_000_000_000
  @max_entries 100_000

  def validate(%{"go" => version} = requirement)
      when map_size(requirement) == 1 and is_binary(version) do
    if byte_size(version) <= 32 and
         Regex.match?(~r/\A1\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/, version),
       do: :ok,
       else: {:error, :invalid_go_version}
  end

  def validate(_), do: {:error, :invalid_toolchain_requirement}

  def install_root(%{"go" => version} = requirement) do
    with :ok <- validate(requirement),
         {:ok, os, arch} <- platform(),
         state when is_binary(state) <- Application.get_env(:shoestring, :state_dir) do
      {:ok, Path.expand(Path.join([state, "toolchains", "go#{version}-#{os}-#{arch}", "go"]))}
    else
      nil -> {:error, :missing_state_dir}
      error -> error
    end
  end

  def install_root(_), do: {:error, :invalid_toolchain_requirement}

  @doc "Checks the local cache without downloading or installing anything."
  def cached_root(%{"go" => version} = requirement) do
    with :ok <- validate(requirement),
         {:ok, os, arch} <- platform(),
         {:ok, checksum} <- checksum(version, os, arch),
         {:ok, root} <- install_root(requirement) do
      if ready?(root, checksum), do: {:ok, root}, else: {:error, :not_cached}
    end
  end

  def cached_root(_), do: {:error, :invalid_toolchain_requirement}

  @doc "Reports readiness without contacting the download host."
  def cache_status(requirement) do
    case cached_root(requirement) do
      {:ok, _root} -> "ready"
      {:error, :not_cached} -> "download_needed"
      {:error, _reason} -> "unavailable"
    end
  end

  def prepare(%{"go" => version} = requirement) do
    with :ok <- validate(requirement),
         {:ok, os, arch} <- platform(),
         {:ok, checksum} <- checksum(version, os, arch),
         {:ok, root} <- install_root(requirement) do
      :global.trans(
        {{__MODULE__, root}, self()},
        fn ->
          if ready?(root, checksum),
            do: {:ok, root},
            else: install(root, version, os, arch, checksum)
        end,
        [node()]
      )
    end
  end

  def prepare(_), do: {:error, :invalid_toolchain_requirement}

  defp platform do
    os =
      case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, :linux} -> "linux"
        _ -> nil
      end

    arch =
      case to_string(:erlang.system_info(:system_architecture)) do
        "aarch64" <> _ -> "arm64"
        "arm64" <> _ -> "arm64"
        "x86_64" <> _ -> "amd64"
        _ -> nil
      end

    if os && arch, do: {:ok, os, arch}, else: {:error, :unsupported_platform}
  end

  defp checksum(version, os, arch) do
    checksums = Map.merge(@checksums, Application.get_env(:shoestring, :toolchain_checksums, %{}))

    case Map.get(checksums, {version, os, arch}) do
      hash when is_binary(hash) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, hash),
          do: {:ok, hash},
          else: {:error, :invalid_checksum_config}

      nil ->
        {:error, :unsupported_go_version}

      _ ->
        {:error, :invalid_checksum_config}
    end
  end

  defp ready?(root, checksum) do
    File.read(Path.join(root, ".shoestring-sha256")) == {:ok, checksum} and
      File.regular?(Path.join(root, "bin/go"))
  end

  defp install(root, version, os, arch, checksum) do
    parent = Path.dirname(root)
    base = Path.dirname(parent)
    url = "https://dl.google.com/go/go#{version}.#{os}-#{arch}.tar.gz"

    stage =
      Path.join(
        base,
        ".go-stage-#{System.unique_integer([:positive, :monotonic])}-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    with {:ok, data} <- download(url),
         true <-
           Base.encode16(:crypto.hash(:sha256, data), case: :lower) == checksum ||
             {:error, :checksum_mismatch},
         :ok <- validate_archive(data),
         :ok <- File.mkdir_p(base),
         :ok <- File.mkdir(stage),
         :ok <-
           :erl_tar.extract({:binary, data}, [
             :compressed,
             {:cwd, String.to_charlist(stage)}
           ]),
         true <- File.regular?(Path.join(stage, "go/bin/go")) || {:error, :invalid_archive},
         :ok <- File.write(Path.join(stage, "go/.shoestring-sha256"), checksum, [:exclusive]),
         :ok <- publish(stage, parent, root, checksum) do
      {:ok, root}
    else
      {:error, _} = error -> error
      other -> {:error, {:install_failed, other}}
    end
  end

  defp publish(stage, parent, root, checksum) do
    # Renaming the complete staging directory publishes the Go tree atomically.
    case File.rename(stage, parent) do
      :ok -> :ok
      {:error, _} = error -> if ready?(root, checksum), do: :ok, else: error
    end
  end

  defp download(url) do
    task = Task.async(fn -> download_archive(url) end)

    case Task.yield(task, 180_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :download_timeout}
      {:exit, reason} -> {:error, {:download_failed, reason}}
    end
  end

  defp download_archive(url) do
    case {Application.get_env(:shoestring, :environment),
          Application.get_env(:shoestring, :toolchain_test_download)} do
      {:test, fun} when is_function(fun, 1) -> fun.(url)
      _ -> download_http(url)
    end
  end

  defp download_http(url) do
    case Req.get(url,
           into: &collect_download/2,
           redirect: false,
           retry: false,
           receive_timeout: 30_000,
           connect_options: [timeout: 15_000]
         ) do
      {:ok, %{status: 200, body: {_size, chunks}}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, %{body: :too_large}} ->
        {:error, :archive_too_large}

      {:ok, %{status: status}} ->
        {:error, {:download_status, status}}

      {:error, reason} ->
        {:error, {:download_failed, reason}}
    end
  end

  defp collect_download({:data, data}, {request, response}) do
    {size, chunks} = if is_tuple(response.body), do: response.body, else: {0, []}
    size = size + byte_size(data)

    if size <= @max_archive do
      {:cont, {request, %{response | body: {size, [data | chunks]}}}}
    else
      {:halt, {request, %{response | body: :too_large}}}
    end
  end

  defp validate_archive(data) do
    case :erl_tar.table({:binary, data}, [:compressed, :verbose]) do
      {:ok, entries} when length(entries) <= @max_entries ->
        result =
          Enum.reduce_while(entries, {MapSet.new(), 0}, fn {name, type, size, _, _, _, _},
                                                           {seen, total} ->
            name = List.to_string(name)
            parts = String.split(name, "/", trim: true)
            canonical = Enum.join(parts, "/")

            valid =
              type in [:regular, :directory] and parts != [] and hd(parts) == "go" and
                Enum.all?(parts, &(&1 not in [".", "..", ""])) and
                (name == canonical or (type == :directory and name == canonical <> "/")) and
                not String.starts_with?(name, "/") and
                not MapSet.member?(seen, canonical) and is_integer(size) and size >= 0 and
                total + size <= @max_extracted

            if valid,
              do: {:cont, {MapSet.put(seen, canonical), total + size}},
              else: {:halt, :invalid}
          end)

        if result == :invalid, do: {:error, :invalid_archive}, else: :ok

      _ ->
        {:error, :invalid_archive}
    end
  end
end
