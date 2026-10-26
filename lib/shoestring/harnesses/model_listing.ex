defmodule Shoestring.Harnesses.ModelListing do
  @moduledoc """
  Asks a harness CLI which models it offers, over the CLI's own protocol and
  without sending a prompt (VERIFIED 2026-10-25 against Codex 0.164.0,
  opencode 2.0.31 and Claude Code 2.1.310):

    * Codex: `model/list` on `codex app-server --stdio`, following
      `nextCursor`. Hidden models are left out.
    * opencode: the `model` option in the reply to ACP `session/new` on
      `opencode acp`. The session is created in a temporary directory and
      never prompted.
    * Claude Code: `models` in the reply to the stream-json `initialize`
      control request. Nothing else in that reply is kept.

  The CLI and every process group under it are stopped as soon as the reply
  arrives or the deadline passes. A reply over the frame limit fails; it is
  never truncated. Entries whose identifier Shoestring could not store are
  counted in `skipped`, not dropped silently.
  """

  alias Shoestring.AgentProfiles.Settings
  alias Shoestring.Harness.Capacity.Codex.StdioTransport
  alias Shoestring.Harness.OpencodeAcp.ProcessTree

  @timeout_ms 30_000
  @max_models 500
  @max_pages 10
  @client %{"name" => "shoestring", "title" => "Shoestring model listing", "version" => "1"}

  @args %{
    "codex" => ["app-server", "--stdio"],
    "opencode" => ["acp"],
    "claude" => ~w(--print --verbose --input-format stream-json --output-format stream-json)
  }

  @type model :: %{required(String.t()) => term()}

  @doc """
  `{:ok, %{models: [model], skipped: n}}` or `{:error, reason}`. Each model
  has `"model"`, `"display_name"`, `"efforts"`, `"default_effort"`,
  `"default"` and `"resolves_to"`. Options: `:executable` (a path instead of
  the harness's command on `PATH`) and `:timeout_ms`.
  """
  def list(harness, opts \\ []) do
    case Map.fetch(@args, harness) do
      {:ok, args} -> run(harness, args, opts)
      :error -> {:error, :unsupported_harness}
    end
  end

  defp run(harness, args, opts) do
    transport_opts =
      [owner: self(), command: harness, args: args] ++ Keyword.take(opts, [:executable])

    deadline = now() + Keyword.get(opts, :timeout_ms, @timeout_ms)

    case StdioTransport.start_link(transport_opts) do
      {:ok, pid} ->
        os_pid = StdioTransport.os_pid(pid)

        try do
          with {:ok, reply} <- converse(harness, %{pid: pid, deadline: deadline}) do
            parse(harness, reply)
          end
        after
          stop(pid, os_pid)
        end

      {:error, :executable_not_found} ->
        {:error, :binary_missing}

      {:error, _reason} ->
        {:error, :start_failed}
    end
  end

  defp converse("codex", io) do
    with {:ok, _} <-
           call(io, %{"method" => "initialize", "id" => 1, "params" => %{"clientInfo" => @client}}),
         :ok <- send_frame(io, %{"method" => "initialized", "params" => %{}}) do
      codex_pages(io, nil, 2, [])
    end
  end

  defp converse("opencode", io) do
    initialize = %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false
      },
      "clientInfo" => %{"name" => "shoestring", "version" => "1"}
    }

    with {:ok, _} <- call(io, rpc(1, "initialize", initialize)) do
      call(io, rpc(2, "session/new", %{"cwd" => System.tmp_dir!(), "mcpServers" => []}))
    end
  end

  defp converse("claude", io) do
    request = %{"subtype" => "initialize"}

    with :ok <-
           send_frame(io, %{
             "type" => "control_request",
             "request_id" => "models",
             "request" => request
           }) do
      case await(io, &(&1["type"] == "control_response")) do
        {:ok, %{"response" => %{"subtype" => "success", "response" => %{} = reply}}} ->
          {:ok, reply}

        {:ok, _} ->
          {:error, :listing_refused}

        error ->
          error
      end
    end
  end

  defp codex_pages(io, cursor, id, acc) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case call(io, %{"method" => "model/list", "id" => id, "params" => params}) do
      {:ok, %{"data" => data} = page} when is_list(data) ->
        case page["nextCursor"] do
          next when is_binary(next) and next != "" and id - 1 < @max_pages ->
            codex_pages(io, next, id + 1, acc ++ data)

          next when is_binary(next) and next != "" ->
            {:error, :too_many_pages}

          _ ->
            {:ok, acc ++ data}
        end

      {:ok, _} ->
        {:error, :unexpected_reply}

      error ->
        error
    end
  end

  defp rpc(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp call(io, %{"id" => id} = frame) do
    with :ok <- send_frame(io, frame),
         {:ok, reply} <- await(io, &(&1["id"] == id and not Map.has_key?(&1, "method"))) do
      case reply do
        %{"error" => _} -> {:error, :listing_refused}
        %{"result" => result} -> {:ok, result}
        _ -> {:error, :unexpected_reply}
      end
    end
  end

  defp send_frame(%{pid: pid}, frame) do
    case StdioTransport.send_frame(pid, frame) do
      :ok -> :ok
      {:error, _} -> {:error, :exited}
    end
  end

  defp await(%{pid: pid, deadline: deadline} = io, match) do
    receive do
      {:codex_transport_frame, ^pid, line} ->
        case Jason.decode(line) do
          {:ok, %{} = frame} -> if match.(frame), do: {:ok, frame}, else: await(io, match)
          _ -> await(io, match)
        end

      {:codex_transport_error, ^pid, :oversized_frame} ->
        {:error, :oversized_reply}

      {:codex_transport_closed, ^pid, _reason} ->
        {:error, :exited}
    after
      max(deadline - now(), 0) -> {:error, :timeout}
    end
  end

  # Signal every process group under the CLI before closing its stdio, then
  # drop whatever the transport still had queued for this process.
  defp stop(pid, os_pid) do
    if is_integer(os_pid), do: ProcessTree.reap(os_pid)
    StdioTransport.close(pid)
    flush(pid)
  end

  defp flush(pid) do
    receive do
      {:codex_transport_connected, ^pid} -> flush(pid)
      {:codex_transport_frame, ^pid, _} -> flush(pid)
      {:codex_transport_error, ^pid, _} -> flush(pid)
      {:codex_transport_closed, ^pid, _} -> flush(pid)
    after
      0 -> :ok
    end
  end

  @doc "The models in a harness's reply, as `list/2` returns them."
  def parse("codex", data) when is_list(data) do
    data
    |> Enum.reject(&(is_map(&1) and &1["hidden"] == true))
    |> Enum.map(fn model ->
      %{
        "model" => model["model"] || model["id"],
        "display_name" => model["displayName"],
        "efforts" => Enum.map(List.wrap(model["supportedReasoningEfforts"]), &effort_value/1),
        "default_effort" => model["defaultReasoningEffort"],
        "default" => model["isDefault"] == true,
        "resolves_to" => nil
      }
    end)
    |> finish("codex")
  end

  def parse("opencode", %{"configOptions" => options}) when is_list(options) do
    case Enum.find(options, &(is_map(&1) and &1["id"] == "model")) do
      %{"options" => values} = option when is_list(values) ->
        values
        |> Enum.map(fn value ->
          %{
            "model" => value["value"],
            "display_name" => value["name"],
            "efforts" => [],
            "default_effort" => nil,
            "default" => value["value"] == option["currentValue"],
            "resolves_to" => nil
          }
        end)
        |> finish("opencode")

      _ ->
        {:error, :unexpected_reply}
    end
  end

  def parse("claude", %{"models" => models}) when is_list(models) do
    models
    |> Enum.map(fn model ->
      %{
        "model" => model["value"],
        "display_name" => model["displayName"],
        "efforts" => List.wrap(model["supportedEffortLevels"]),
        "default_effort" => nil,
        "default" => model["value"] == "default",
        "resolves_to" => model["resolvedModel"]
      }
    end)
    |> finish("claude")
  end

  def parse(_harness, _reply), do: {:error, :unexpected_reply}

  defp effort_value(%{"reasoningEffort" => effort}), do: effort
  defp effort_value(effort), do: effort

  defp finish(models, harness) do
    {kept, skipped} =
      models
      |> Enum.map(&clean(&1, harness))
      |> Enum.split_with(&is_map/1)

    kept = Enum.uniq_by(kept, & &1["model"])

    if length(kept) > @max_models,
      do: {:error, :too_many_models},
      else: {:ok, %{models: kept, skipped: length(skipped)}}
  end

  defp clean(model, harness) do
    if is_binary(model["model"]) and Settings.valid_model?(harness, model["model"]) do
      %{
        model
        | "display_name" => text(model["display_name"]),
          "efforts" => Enum.filter(model["efforts"], &effort?/1),
          "default_effort" => if(effort?(model["default_effort"]), do: model["default_effort"]),
          "resolves_to" =>
            if(
              is_binary(model["resolves_to"]) and
                Settings.valid_model?("claude", model["resolves_to"]),
              do: model["resolves_to"]
            )
      }
    else
      :skipped
    end
  end

  defp effort?(effort),
    do: is_binary(effort) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,19}\z/, effort)

  defp text(value) when is_binary(value) do
    if String.valid?(value) do
      case value |> String.replace(~r/[[:cntrl:]]/u, "") |> String.trim() do
        "" -> nil
        value -> String.slice(value, 0, 120)
      end
    end
  end

  defp text(_value), do: nil

  defp now, do: System.monotonic_time(:millisecond)
end
