defmodule Shoestring.Release.Bootstrap do
  @moduledoc "Private, persistent endpoint initialization. Secrets are never returned in diagnostics."
  @filename ".endpoint-secret"

  def endpoint_secret!(root, override \\ nil) do
    case endpoint_secret(root, override) do
      {:ok, secret} -> secret
      {:error, reason} -> raise "Endpoint initialization refused: #{reason}"
    end
  end

  def endpoint_secret(root, override \\ nil)

  def endpoint_secret(_root, override) when is_binary(override) and byte_size(override) >= 64,
    do: {:ok, override}

  def endpoint_secret(root, nil) do
    path = Path.join(root, @filename)

    with :ok <- File.mkdir_p(root) do
      case File.lstat(path) do
        {:ok, _} -> read_private(path)
        {:error, :enoent} -> create_private(path)
        _ -> {:error, :endpoint_secret_unavailable}
      end
    else
      _ -> {:error, :state_directory_unavailable}
    end
  end

  def endpoint_secret(_, _), do: {:error, :invalid_endpoint_override}

  def status(root, override \\ nil)

  def status(_root, override) when is_binary(override) and byte_size(override) >= 64,
    do: "operator_override"

  def status(_root, override) when not is_nil(override), do: "invalid_operator_override"

  def status(root, nil) do
    case read_private(Path.join(root, @filename)) do
      {:ok, _} -> "private"
      {:error, _} -> "missing_or_invalid"
    end
  end

  defp read_private(path) do
    with {:ok, %{type: :regular, size: 88, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, secret} <- File.read(path),
         {:ok, decoded} <- Base.decode64(secret),
         true <- byte_size(decoded) == 64 do
      {:ok, secret}
    else
      _ -> {:error, :endpoint_secret_not_private_or_valid}
    end
  end

  defp create_private(path) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        try do
          secret = Base.encode64(:crypto.strong_rand_bytes(64))

          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(file, secret),
               :ok <- :file.sync(file) do
            {:ok, secret}
          else
            _ -> {:error, :endpoint_secret_write_failed}
          end
        after
          File.close(file)
        end

      {:error, :eexist} ->
        read_private(path)

      _ ->
        {:error, :endpoint_secret_write_failed}
    end
  end
end
