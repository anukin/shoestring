defmodule Shoestring.Coordinator.Mcp do
  @moduledoc """
  The JSON-RPC side of the coordinator's MCP tool endpoint (iteration 15,
  package B), over streamable HTTP with plain JSON replies (no event
  stream). `ShoestringWeb.McpController` authenticates the request and calls
  `handle/2` with the token's binding.

  Phase 0 saw the three coordinators connect this way: Claude Code (which
  asks `server/discover` first and carries on when it is not supported),
  Codex (protocol `2025-06-18`) and opencode (`2025-11-25`).
  """

  require Logger

  alias Shoestring.Coordinator.Tools

  @versions ["2025-11-25", "2025-06-18", "2025-03-26"]

  @doc "The protocol versions served, newest first."
  def versions, do: @versions

  @doc """
  `{:reply, response}` for a request, `:accepted` for a notification or a
  response from the client (HTTP 202, no body).
  """
  @spec handle(term(), Shoestring.Coordinator.ToolTokens.binding()) :: {:reply, map()} | :accepted
  def handle(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = message, binding)
      when is_binary(method) and (is_binary(id) or is_integer(id)) do
    case request(method, Map.get(message, "params") || %{}, binding) do
      {:ok, result} -> {:reply, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}
      {:error, code, text} -> {:reply, error(id, code, text)}
    end
  end

  def handle(%{"jsonrpc" => "2.0", "method" => method} = message, _binding)
      when is_binary(method) and not is_map_key(message, "id"),
      do: :accepted

  def handle(%{"jsonrpc" => "2.0", "id" => _id} = message, _binding)
      when is_map_key(message, "result") or is_map_key(message, "error"),
      do: :accepted

  def handle(_message, _binding), do: {:reply, error(nil, -32_600, "Invalid Request")}

  defp request("initialize", params, _binding) do
    requested = params["protocolVersion"]

    {:ok,
     %{
       "protocolVersion" => if(requested in @versions, do: requested, else: hd(@versions)),
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => "shoestring", "version" => version()}
     }}
  end

  defp request("ping", _params, _binding), do: {:ok, %{}}
  defp request("tools/list", _params, _binding), do: {:ok, %{"tools" => Tools.list()}}

  defp request("tools/call", %{"name" => name} = params, binding) when is_binary(name) do
    arguments = Map.get(params, "arguments") || %{}

    if is_map(arguments),
      do: {:ok, result(call(name, arguments, binding))},
      else: {:error, -32_602, "arguments must be an object"}
  end

  defp request("tools/call", _params, _binding), do: {:error, -32_602, "tools/call needs a name"}
  defp request(method, _params, _binding), do: {:error, -32_601, "Method not found: #{method}"}

  # A tool that raises is reported to the coordinator as a failed call, not
  # an HTTP error; the exception is logged without its arguments.
  defp call(name, arguments, binding) do
    Tools.call(name, arguments, binding)
  rescue
    exception ->
      Logger.error("coordinator tool #{name} raised #{inspect(exception.__struct__)}")
      {:error, "The #{name} tool failed inside Shoestring; nothing was retried."}
  end

  defp result({:ok, data}),
    do: %{"content" => [%{"type" => "text", "text" => Jason.encode!(data)}], "isError" => false}

  defp result({:error, message}),
    do: %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp version, do: :shoestring |> Application.spec(:vsn) |> to_string()
end
