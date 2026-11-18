defmodule Shoestring.DispatchSetup.Downloads do
  @moduledoc """
  Fetches checksum-pinned setup assets into a runner-owned directory.

  Operators may add exact HTTPS hostnames using `:dispatch_setup_download_hosts`.
  GitHub release CDN URLs are accepted only as redirects, since their query
  strings contain temporary signatures. Errors never contain URLs or bodies.
  """

  @hosts ~w(github.com builds.hex.pm repo.hex.pm hex.pm erlang.org www.erlang.org builds.erlang.org
    nodejs.org static.rust-lang.org go.dev dl.google.com www.python.org)
  @cdn "release-assets.githubusercontent.com"
  @max_assets 8
  @max_bytes 100_000_000
  @max_redirects 5
  @timeout 120_000

  def validate(assets) when is_list(assets) and length(assets) <= @max_assets do
    names = Enum.map(assets, fn asset -> if is_map(asset), do: Map.get(asset, "name") end)

    if Enum.uniq(names) == names and Enum.all?(assets, &valid_asset?/1),
      do: :ok,
      else: {:error, :invalid_downloads}
  end

  def validate(_), do: {:error, :invalid_downloads}

  def prepare(assets, destination) when is_binary(destination) do
    with :ok <- validate(assets),
         true <- File.dir?(destination) do
      task = Task.async(fn -> download_all(assets, destination, 0) end)

      case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :download_failed}
      end
    else
      _ -> {:error, :invalid_downloads}
    end
  end

  def prepare(_, _), do: {:error, :invalid_downloads}

  defp valid_asset?(%{"name" => name, "url" => url, "sha256" => hash} = asset)
       when map_size(asset) == 3 and is_binary(name) and is_binary(url) and is_binary(hash) do
    Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/, name) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, hash) and byte_size(url) <= 2_048 and
      valid_url?(url, false)
  end

  defp valid_asset?(_), do: false

  defp valid_url?(url, redirect?) do
    uri = URI.parse(url)
    additions = Application.get_env(:shoestring, :dispatch_setup_download_hosts, [])
    hosts = if is_list(additions), do: @hosts ++ additions, else: @hosts
    host = uri.host
    cdn? = redirect? and host == @cdn

    uri.scheme == "https" and is_binary(host) and
      (host in hosts or cdn?) and uri.userinfo == nil and uri.fragment == nil and
      uri.port == 443 and (uri.query == nil or cdn?) and
      is_binary(uri.path) and String.starts_with?(uri.path, "/") and
      (host != "github.com" or
         Regex.match?(~r{\A/[^/]+/[^/]+/releases/download/[^/]+/[^/]+\z}, uri.path))
  rescue
    _ -> false
  end

  defp download_all([], _destination, _bytes), do: :ok

  defp download_all([asset | rest], destination, bytes) do
    with {:ok, body, used} <- fetch(asset["url"], @max_bytes - bytes, @max_redirects),
         true <- Base.encode16(:crypto.hash(:sha256, body), case: :lower) == asset["sha256"],
         :ok <- write_verified(destination, asset["name"], body) do
      download_all(rest, destination, bytes + used)
    else
      _ -> {:error, :download_failed}
    end
  end

  defp fetch(url, remaining, redirects) do
    into = fn {:data, chunk}, {request, response} ->
      previous = if is_binary(response.body), do: response.body, else: ""

      if byte_size(previous) + byte_size(chunk) <= remaining do
        {:cont, {request, %{response | body: previous <> chunk}}}
      else
        {:halt, {request, %{response | body: :oversized}}}
      end
    end

    options = [
      url: url,
      redirect: false,
      retry: false,
      raw: true,
      compressed: false,
      headers: [{"accept-encoding", "identity"}],
      receive_timeout: 15_000,
      connect_options: [timeout: 5_000],
      into: into
    ]

    options =
      case {Application.get_env(:shoestring, :environment),
            Application.get_env(:shoestring, :dispatch_setup_download_test_plug)} do
        {:test, plug} when not is_nil(plug) -> Keyword.put(options, :plug, plug)
        _ -> options
      end

    case Req.get(options) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= remaining ->
        {:ok, body, byte_size(body)}

      {:ok, %{status: status, body: body} = response}
      when status in [301, 302, 303, 307, 308] and redirects > 0 and is_binary(body) and
             byte_size(body) <= remaining ->
        with [location] <- Req.Response.get_header(response, "location"),
             next <- URI.merge(url, location) |> URI.to_string(),
             true <- valid_url?(next, true),
             {:ok, result, used} <- fetch(next, remaining - byte_size(body), redirects - 1) do
          {:ok, result, used + byte_size(body)}
        else
          _ -> {:error, :download_failed}
        end

      _ ->
        {:error, :download_failed}
    end
  rescue
    _ -> {:error, :download_failed}
  end

  defp write_verified(destination, name, body) do
    target = Path.join(destination, name)

    temporary =
      Path.join(
        destination,
        ".download-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )

    with {:error, :enoent} <- File.lstat(target),
         :ok <- File.write(temporary, body, [:binary, :exclusive]),
         :ok <- File.rename(temporary, target) do
      :ok
    else
      _ -> {:error, :download_failed}
    end
  end
end
