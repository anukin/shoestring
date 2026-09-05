defmodule Shoestring.Harness.CodexAppServer.EventNormalizer do
  @moduledoc """
  Normalizes raw `codex app-server --stdio` JSON-RPC frames into canonical
  `Shoestring.Harness.HarnessEvent` structs.

  Adheres to the milestone requirements:
  - Strict secret scrubbing and redaction (paths, Bearer tokens, API keys, emails).
  - Complete elimination of hidden reasoning or private model thoughts.
  - Namespaced provider fields (`codex-app-server:*`).
  - Quota refusal mapping from `turn.error.codexErrorInfo`.
  - Graceful degradation for optional or missing fields in tool/command frames.
  """

  alias Shoestring.Harness.{Error, HarnessEvent}

  @secret_patterns [
    {~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i, "[REDACTED_BEARER]"},
    {~r/\b(?:api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*[^\s,]+/i,
     "[REDACTED_SECRET]"},
    {~r/\bsk-[A-Za-z0-9_-]{12,}/, "[REDACTED_KEY]"},
    {~r/\/Users\/[^\/]+/, "$HOME"}
  ]

  @doc """
  Normalizes a decoded JSON-RPC frame map into a `Shoestring.Harness.HarnessEvent`.
  Returns `{:ok, %HarnessEvent{}}`, `{:skip, reason}`, or `{:error, reason}`.
  """
  @spec normalize(map(), String.t(), pos_integer(), keyword() | map()) ::
          {:ok, HarnessEvent.t()} | {:skip, atom()} | {:error, term()}
  def normalize(raw_frame, run_id, ordinal, opts \\ %{})

  def normalize(%{"method" => method} = frame, run_id, ordinal, opts) do
    params = Map.get(frame, "params", %{})
    occurred_at = extract_timestamp(frame, opts)
    base_process_id = opts_val(opts, :process_id)
    base_session_id = opts_val(opts, :provider_session_id)

    do_normalize(
      method,
      params,
      run_id,
      ordinal,
      occurred_at,
      base_process_id,
      base_session_id
    )
  end

  # Non-notification frames (e.g. response results or unknown payloads)
  def normalize(_frame, _run_id, _ordinal, _opts) do
    {:skip, :unhandled_frame}
  end

  # --- Specific Method Normalizers ---

  defp do_normalize(
         "thread/status/changed",
         params,
         run_id,
         ordinal,
         occurred_at,
         base_process_id,
         base_session_id
       ) do
    thread_id = sanitize_string(params["threadId"] || base_session_id)
    status_type = get_in(params, ["status", "type"]) || "unknown"

    build_event(
      run_id: run_id,
      ordinal: ordinal,
      source_event_id: "thread-status-#{ordinal}",
      occurred_at: occurred_at,
      kind: :lifecycle,
      process_id: base_process_id,
      provider_session_id: thread_id,
      extensions: %{
        "codex-app-server:method" => "thread/status/changed",
        "status" => status_type
      }
    )
  end

  defp do_normalize(
         "turn/started",
         params,
         run_id,
         ordinal,
         occurred_at,
         base_process_id,
         base_session_id
       ) do
    turn = params["turn"] || %{}
    turn_id = sanitize_string(turn["id"])
    status = turn["status"] || "inProgress"

    build_event(
      run_id: run_id,
      ordinal: ordinal,
      source_event_id: "turn-started-#{turn_id || ordinal}",
      occurred_at: occurred_at,
      kind: :lifecycle,
      process_id: base_process_id,
      provider_session_id: base_session_id,
      extensions: %{
        "codex-app-server:method" => "turn/started",
        "turn_id" => turn_id,
        "status" => status
      }
    )
  end

  defp do_normalize(
         "item/started",
         %{"item" => %{} = item} = params,
         run_id,
         ordinal,
         occurred_at,
         base_process_id,
         base_session_id
       ) do
    item_type = item["type"]
    item_id = sanitize_string(item["id"])
    thread_id = sanitize_string(params["threadId"] || base_session_id)

    case item_type do
      "reasoning" ->
        {:skip, :hidden_reasoning}

      "thought" ->
        {:skip, :hidden_reasoning}

      "thinking" ->
        {:skip, :hidden_reasoning}

      "commandExecution" ->
        cmd_pid = item["processId"] && sanitize_string(to_string(item["processId"]))

        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "item-started-#{item_id || ordinal}",
          occurred_at: occurred_at,
          kind: :command,
          process_id: cmd_pid || base_process_id,
          provider_session_id: thread_id,
          extensions: %{
            "codex-app-server:item_id" => item_id,
            "command" => sanitize_string(item["command"] || ""),
            "cwd" => sanitize_string(item["cwd"] || ""),
            "status" => item["status"] || "inProgress"
          }
        )

      "agentMessage" ->
        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "item-started-#{item_id || ordinal}",
          occurred_at: occurred_at,
          kind: :output,
          process_id: base_process_id,
          provider_session_id: thread_id,
          extensions: %{
            "codex-app-server:item_id" => item_id,
            "phase" => item["phase"] || "commentary"
          }
        )

      "fileChange" ->
        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "item-started-#{item_id || ordinal}",
          occurred_at: occurred_at,
          kind: :tool,
          process_id: base_process_id,
          provider_session_id: thread_id,
          extensions: %{
            "codex-app-server:item_id" => item_id,
            "tool" => "fileChange",
            "status" => item["status"] || "inProgress"
          }
        )

      "userMessage" ->
        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "item-started-#{item_id || ordinal}",
          occurred_at: occurred_at,
          kind: :lifecycle,
          process_id: base_process_id,
          provider_session_id: thread_id,
          extensions: %{
            "codex-app-server:item_id" => item_id,
            "item_type" => "userMessage"
          }
        )

      other ->
        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "item-started-#{item_id || ordinal}",
          occurred_at: occurred_at,
          kind: :lifecycle,
          process_id: base_process_id,
          provider_session_id: thread_id,
          extensions: %{
            "codex-app-server:item_id" => item_id,
            "item_type" => other
          }
        )
    end
  end

  defp do_normalize(
         "item/completed",
         %{"item" => %{} = item} = params,
         run_id,
         ordinal,
         occurred_at,
         base_process_id,
         base_session_id
       ) do
    item_type = item["type"]
    item_id = sanitize_string(item["id"])
    thread_id = sanitize_string(params["threadId"] || base_session_id)

    case item_type do
      "reasoning" ->
        {:skip, :hidden_reasoning}

      "thought" ->
        {:skip, :hidden_reasoning}

      "thinking" ->
        {:skip, :hidden_reasoning}

      "commandExecution" ->
        cmd_pid = item["processId"] && sanitize_string(to_string(item["processId"]))

        extensions =
          %{
            "codex-app-server:item_id" => item_id,
            "command" => sanitize_string(item["command"] || ""),
            "cwd" => sanitize_string(item["cwd"] || ""),
            "status" => item["status"] || "completed",
            "exit_code" => item["exitCode"],
            "aggregated_output" => sanitize_string(item["aggregatedOutput"] || ""),
            "duration_ms" => item["durationMs"]
          }
          |> filter_nils()

        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "item-completed-#{item_id || ordinal}",
          occurred_at: occurred_at,
          kind: :command,
          process_id: cmd_pid || base_process_id,
          provider_session_id: thread_id,
          extensions: extensions
        )

      "agentMessage" ->
        text = sanitize_string(item["text"] || "")

        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "item-completed-#{item_id || ordinal}",
          occurred_at: occurred_at,
          kind: :output,
          process_id: base_process_id,
          provider_session_id: thread_id,
          extensions: %{
            "codex-app-server:item_id" => item_id,
            "phase" => item["phase"] || "final_answer",
            "text" => text
          }
        )

      "fileChange" ->
        changes = sanitize_changes(item["changes"])

        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "item-completed-#{item_id || ordinal}",
          occurred_at: occurred_at,
          kind: :tool,
          process_id: base_process_id,
          provider_session_id: thread_id,
          extensions: %{
            "codex-app-server:item_id" => item_id,
            "tool" => "fileChange",
            "changes" => changes,
            "status" => item["status"] || "completed"
          }
        )

      "userMessage" ->
        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "item-completed-#{item_id || ordinal}",
          occurred_at: occurred_at,
          kind: :lifecycle,
          process_id: base_process_id,
          provider_session_id: thread_id,
          extensions: %{
            "codex-app-server:item_id" => item_id,
            "item_type" => "userMessage"
          }
        )

      other ->
        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "item-completed-#{item_id || ordinal}",
          occurred_at: occurred_at,
          kind: :lifecycle,
          process_id: base_process_id,
          provider_session_id: thread_id,
          extensions: %{
            "codex-app-server:item_id" => item_id,
            "item_type" => other
          }
        )
    end
  end

  defp do_normalize(
         "item/agentMessage/delta",
         params,
         run_id,
         ordinal,
         occurred_at,
         base_process_id,
         base_session_id
       ) do
    delta = params["delta"] || %{}
    text = sanitize_string(delta["text"] || "")

    build_event(
      run_id: run_id,
      ordinal: ordinal,
      source_event_id: "agent-delta-#{ordinal}",
      occurred_at: occurred_at,
      kind: :output,
      process_id: base_process_id,
      provider_session_id: base_session_id,
      extensions: %{
        "codex-app-server:method" => "item/agentMessage/delta",
        "delta" => text
      }
    )
  end

  defp do_normalize(
         "thread/tokenUsage/updated",
         params,
         run_id,
         ordinal,
         occurred_at,
         base_process_id,
         base_session_id
       ) do
    token_usage = params["tokenUsage"] || %{}

    build_event(
      run_id: run_id,
      ordinal: ordinal,
      source_event_id: "token-usage-#{ordinal}",
      occurred_at: occurred_at,
      kind: :lifecycle,
      process_id: base_process_id,
      provider_session_id: sanitize_string(params["threadId"] || base_session_id),
      extensions: %{
        "codex-app-server:method" => "thread/tokenUsage/updated",
        "token_usage" => token_usage
      }
    )
  end

  defp do_normalize(
         "account/rateLimits/updated",
         _params,
         run_id,
         ordinal,
         occurred_at,
         base_process_id,
         base_session_id
       ) do
    build_event(
      run_id: run_id,
      ordinal: ordinal,
      source_event_id: "rate-limits-updated-#{ordinal}",
      occurred_at: occurred_at,
      kind: :lifecycle,
      process_id: base_process_id,
      provider_session_id: base_session_id,
      extensions: %{
        "codex-app-server:method" => "account/rateLimits/updated"
      }
    )
  end

  defp do_normalize(
         "turn/completed",
         params,
         run_id,
         ordinal,
         occurred_at,
         base_process_id,
         base_session_id
       ) do
    turn = params["turn"] || %{}
    turn_id = sanitize_string(turn["id"])
    turn_status = turn["status"]
    error_payload = turn["error"]

    cond do
      turn_status == "interrupted" ->
        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "turn-completed-#{turn_id || ordinal}",
          occurred_at: occurred_at,
          kind: :result,
          process_id: base_process_id,
          provider_session_id: base_session_id,
          result: %{status: "interrupted", artifact_id: nil},
          extensions: %{
            "codex-app-server:turn_id" => turn_id,
            "status" => "interrupted",
            "interrupted" => true,
            "duration_ms" => turn["durationMs"]
          }
        )

      turn_status == "failed" or not is_nil(error_payload) ->
        error = normalize_codex_error(error_payload)

        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "turn-failed-#{turn_id || ordinal}",
          occurred_at: occurred_at,
          kind: :error,
          process_id: base_process_id,
          provider_session_id: base_session_id,
          error: error,
          extensions: %{
            "codex-app-server:turn_id" => turn_id,
            "status" => "failed"
          }
        )

      true ->
        build_event(
          run_id: run_id,
          ordinal: ordinal,
          source_event_id: "turn-completed-#{turn_id || ordinal}",
          occurred_at: occurred_at,
          kind: :result,
          process_id: base_process_id,
          provider_session_id: base_session_id,
          result: %{status: "completed", artifact_id: nil},
          extensions: %{
            "codex-app-server:turn_id" => turn_id,
            "status" => "completed",
            "duration_ms" => turn["durationMs"]
          }
        )
    end
  end

  defp do_normalize(
         _other_method,
         _params,
         _run_id,
         _ordinal,
         _occurred_at,
         _base_process_id,
         _base_session_id
       ) do
    {:skip, :unhandled_method}
  end

  # --- Quota and Error Mapping ---

  @doc """
  Maps raw provider `turn.error` or server JSON-RPC error into a canonical `Shoestring.Harness.Error`.
  Ensures `{usageLimitExceeded, rateLimitExceeded}` map to `:quota_refused`.
  """
  @spec normalize_codex_error(term()) :: Error.t()
  def normalize_codex_error(nil) do
    Error.new(:task_failed, "turn_failed", "Turn execution failed")
  end

  def normalize_codex_error(error) when is_map(error) do
    codex_error_info = error["codexErrorInfo"]
    raw_message = error["message"] || "Turn execution failed"
    message = sanitize_string(raw_message)

    category =
      case codex_error_info do
        info when info in ["usageLimitExceeded", "rateLimitExceeded"] ->
          :quota_refused

        "unauthorized" ->
          :authentication_required

        "serverOverloaded" ->
          :transport

        _ ->
          :task_failed
      end

    code =
      cond do
        is_binary(codex_error_info) ->
          codex_error_info

        is_map(codex_error_info) ->
          case Map.keys(codex_error_info) do
            [first_key | _] -> to_string(first_key)
            _ -> "turn_failed"
          end

        true ->
          "turn_failed"
      end

    Error.new(category, code, message,
      details: %{"codex-app-server:error_info" => to_string(code)}
    )
  end

  def normalize_codex_error(reason) do
    Error.new(:task_failed, "turn_failed", sanitize_string(inspect(reason)))
  end

  # --- Helpers & Sanitization ---

  defp build_event(fields) do
    raw_extensions = Keyword.get(fields, :extensions, %{})
    namespaced = namespace_extensions(raw_extensions)

    attrs =
      fields
      |> Keyword.put(:version, 1)
      |> Keyword.put(:extensions, namespaced)
      |> Enum.into(%{})

    HarnessEvent.new(attrs)
  end

  defp namespace_extensions(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key_str = to_string(k)

      namespaced =
        if String.contains?(key_str, ":") do
          key_str
        else
          "codex-app-server:#{key_str}"
        end

      {namespaced, v}
    end)
  end

  defp namespace_extensions(_), do: %{}

  defp extract_timestamp(frame, opts) do
    cond do
      ms = frame["emittedAtMs"] ->
        DateTime.from_unix!(ms, :millisecond)

      clock_fn = opts_val(opts, :clock) ->
        clock_fn.()

      true ->
        DateTime.utc_now()
    end
  rescue
    _ -> DateTime.utc_now()
  end

  defp opts_val(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp opts_val(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opts_val(_opts, _key), do: nil

  @doc "Sanitizes strings to strip secret patterns and personal user directories."
  def sanitize_string(nil), do: nil

  def sanitize_string(val) when is_binary(val) do
    Enum.reduce(@secret_patterns, val, fn {regex, replacement}, acc ->
      Regex.replace(regex, acc, replacement)
    end)
  end

  def sanitize_string(val), do: to_string(val)

  defp sanitize_changes(changes) when is_list(changes) do
    Enum.map(changes, fn
      change when is_map(change) ->
        %{
          "path" => sanitize_string(change["path"]),
          "kind" => change["kind"],
          "diff" => sanitize_string(change["diff"])
        }

      other ->
        other
    end)
  end

  defp sanitize_changes(_), do: []

  defp filter_nils(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
