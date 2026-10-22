defmodule Shoestring.Harness.HTTP.Transport do
  @moduledoc "One bounded HTTP response. No redirects, decompression, retries or body logging."
  @limit 65_536
  def request(method, url, body, headers, opts) do
    into = fn {:data, bytes}, {req, response} ->
      previous = if is_binary(response.body), do: response.body, else: ""

      if byte_size(previous) + byte_size(bytes) <= @limit do
        {:cont, {req, %{response | body: previous <> bytes}}}
      else
        {:halt, {req, %{response | body: :oversized}}}
      end
    end

    options = [
      method: method,
      url: url,
      headers: [{"accept-encoding", "identity"} | headers],
      raw: true,
      compressed: false,
      retry: false,
      redirect: false,
      # Quiet model work is not a terminal fact. Explicit cancellation or a
      # transport/size failure ends this request; silence alone never does.
      receive_timeout: :infinity,
      connect_options: [timeout: 5_000],
      into: into
    ]

    options = if body, do: Keyword.put(options, :json, body), else: options
    options = if opts[:plug], do: Keyword.put(options, :plug, opts[:plug]), else: options

    case Req.request(options) do
      {:ok, %{body: :oversized}} ->
        {:error, :http_response_oversized}

      {:ok, %{status: status, body: bytes}}
      when is_binary(bytes) and byte_size(bytes) <= @limit ->
        case Jason.decode(bytes) do
          {:ok, %{} = value} -> {:ok, status, value}
          _ -> {:error, :http_schema_incompatible}
        end

      _ ->
        {:error, :http_transport_uncertain}
    end
  rescue
    _ -> {:error, :http_transport_uncertain}
  end
end
