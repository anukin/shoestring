defmodule Shoestring.Harness.ClaudeHeadless.EventNormalizer do
  @moduledoc """
  Normalizes raw `claude --print --verbose --output-format stream-json`
  JSONL frames into canonical `Shoestring.Harness.HarnessEvent` structs.

  Wire contract (VERIFIED against committed live captures in
  `plans/evidence/04-single-elf/fixtures/claude/` — see
  `plans/evidence/04-single-elf/claude-exec-events.md`):

  - Tool START = `assistant` frame with a content block
    `{type: "tool_use", id: "toolu_…"}`. Tool END = `user` frame with a
    content block `{type: "tool_result", tool_use_id: "toolu_…"}` plus a
    frame-level `tool_use_result` carrying stdio verbatim. Correlation is
    by the `toolu_` id ONLY: both STARTs may precede both ENDs (observed),
    and one assistant message spans multiple frames (observed — `message.id`
    and `request_id` are shared across frames, so they are recorded but
    never used for correlation).
  - Terminal classification keys on `is_error` and `terminal_reason`,
    NEVER on `subtype`: the committed auth-failure fixture proves `subtype`
    stays `"success"` while `is_error` is `true`.
  - `session_id` (UUIDv4) is top-level on every frame.
  - Quota: `rate_limit_event` frames carry status / rateLimitType /
    unifiedWindows (status signal only). No refusal shape has ever been
    observed, so NOTHING here maps to `:quota_refused` (standing Gate 0A
    rule: errors map to `:task_failed` + checkpoint, never `:quota_refused`).

  Shape deviation from `CodexAppServer.EventNormalizer`: `normalize/4`
  returns `{:ok, [event]}` (a list, usually one element) because a single
  Claude frame can carry several content blocks, each of which is its own
  boundary signal. Callers assign successive ordinals.

  The normalizer is total: malformed input yields `{:skip, reason}` or
  `{:error, reason}`, never a raise, so a corrupt line cannot crash the
  owning session (adapter-isolation requirement).
  """

  alias Shoestring.Harness.{Error, HarnessEvent}

  @secret_patterns [
    {~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i, "[REDACTED_BEARER]"},
    {~r/\b(?:api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*[^\s,]+/i,
     "[REDACTED_SECRET]"},
    {~r/\bsk-[A-Za-z0-9_-]{12,}/, "[REDACTED_KEY]"},
    {~r/\/Users\/[^\/]+/, "$HOME"}
  ]

  @max_message_chars 500

  @doc """
  Normalizes one decoded stream-json frame map into zero or more
  `Shoestring.Harness.HarnessEvent` structs (ordinals assigned by the
  caller, starting at `ordinal`).

  Returns `{:ok, events}`, `{:skip, reason}`, or `{:error, reason}`.
  """
  @spec normalize(map(), String.t(), pos_integer(), keyword() | map()) ::
          {:ok, [HarnessEvent.t()]} | {:skip, atom()} | {:error, term()}
  def normalize(frame, run_id, ordinal, opts \\ %{})

  def normalize(%{"type" => type} = frame, run_id, ordinal, opts)
      when is_binary(type) and is_binary(run_id) and is_integer(ordinal) and ordinal > 0 do
    occurred_at = extract_timestamp(frame)
    base_process_id = opts_val(opts, :process_id)
    base_session_id = opts_val(opts, :provider_session_id) || sanitize_string(frame["session_id"])

    do_normalize(
      type,
      frame,
      run_id,
      ordinal,
      occurred_at,
      base_process_id,
      base_session_id
    )
  end

  def normalize(_frame, _run_id, _ordinal, _opts) do
    {:skip, :unhandled_frame}
  end

  # --- Frame dispatch ---

  defp do_normalize("system", frame, run_id, ordinal, occurred_at, proc_id, sess_id) do
    subtype = frame["subtype"] || "unknown"

    extensions =
      %{
        "claude-headless:frame_type" => "system",
        "claude-headless:subtype" => sanitize_string(to_string(subtype)),
        "claude-headless:session_id" => sanitize_string(frame["session_id"])
      }
      |> maybe_put("claude-headless:model", sanitize_string(frame["model"]))
      |> maybe_put(
        "claude-headless:claude_code_version",
        sanitize_string(frame["claude_code_version"])
      )
      |> maybe_put("claude-headless:permission_mode", sanitize_string(frame["permissionMode"]))
      |> maybe_put("claude-headless:cwd", sanitize_string(frame["cwd"]))
      |> maybe_put_tools(frame["tools"])
      |> maybe_put_retry(frame)

    build_events(
      run_id,
      ordinal,
      "claude-system-#{subtype}-#{ordinal}",
      occurred_at,
      :lifecycle,
      proc_id,
      sess_id,
      [extensions]
    )
  end

  defp do_normalize("assistant", frame, run_id, ordinal, occurred_at, proc_id, sess_id) do
    message = if is_map(frame["message"]), do: frame["message"], else: %{}
    blocks = if is_list(message["content"]), do: message["content"], else: []
    message_id = sanitize_string(message["id"])
    request_id = sanitize_string(frame["request_id"])

    {ext_list, _} =
      Enum.reduce(blocks, {[], 0}, fn block, {acc, idx} ->
        case assistant_block_extensions(block, frame, message_id, request_id) do
          {:command, ext} -> {[{:command, idx, ext} | acc], idx + 1}
          {:output, ext} -> {[{:output, idx, ext} | acc], idx + 1}
          :skip -> {acc, idx}
        end
      end)

    case Enum.reverse(ext_list) do
      [] ->
        {:skip, :no_emittable_content}

      tagged ->
        events =
          tagged
          |> Enum.with_index()
          |> Enum.map(fn {{kind, _idx, ext}, offset} ->
            source = source_id(frame, "claude-assistant-#{offset}-#{ordinal}")

            build_event(
              run_id: run_id,
              ordinal: ordinal + offset,
              source_event_id: source,
              occurred_at: occurred_at,
              kind: kind,
              process_id: proc_id,
              provider_session_id: sess_id,
              extensions: ext
            )
          end)
          |> collect_events()

        {:ok, events}
    end
  end

  defp do_normalize("user", frame, run_id, ordinal, occurred_at, proc_id, sess_id) do
    message = if is_map(frame["message"]), do: frame["message"], else: %{}
    blocks = if is_list(message["content"]), do: message["content"], else: []
    tool_use_result = if is_map(frame["tool_use_result"]), do: frame["tool_use_result"], else: %{}

    tagged =
      blocks
      |> Enum.reduce([], fn block, acc ->
        case user_block_extensions(block, tool_use_result) do
          {:command, ext} -> [{:command, ext} | acc]
          {:output, ext} -> [{:output, ext} | acc]
          :skip -> acc
        end
      end)
      |> Enum.reverse()

    case tagged do
      [] ->
        {:skip, :no_emittable_content}

      _ ->
        events =
          tagged
          |> Enum.with_index()
          |> Enum.map(fn {{kind, ext}, offset} ->
            source = source_id(frame, "claude-user-#{offset}-#{ordinal}")

            build_event(
              run_id: run_id,
              ordinal: ordinal + offset,
              source_event_id: source,
              occurred_at: occurred_at,
              kind: kind,
              process_id: proc_id,
              provider_session_id: sess_id,
              extensions: ext
            )
          end)
          |> collect_events()

        {:ok, events}
    end
  end

  defp do_normalize("rate_limit_event", frame, run_id, ordinal, occurred_at, proc_id, sess_id) do
    info = if is_map(frame["rate_limit_info"]), do: frame["rate_limit_info"], else: %{}
    windows = if is_map(info["unifiedWindows"]), do: info["unifiedWindows"], else: %{}

    extensions =
      %{
        "claude-headless:frame_type" => "rate_limit_event",
        "claude-headless:rate_limit_status" => sanitize_string(info["status"]),
        "claude-headless:rate_limit_type" => sanitize_string(info["rateLimitType"])
      }
      |> maybe_put_window("claude-headless:five_hour_utilization", windows["five_hour"])
      |> maybe_put_window("claude-headless:seven_day_utilization", windows["seven_day"])

    build_events(
      run_id,
      ordinal,
      source_id(frame, "claude-rate-limit-#{ordinal}"),
      occurred_at,
      :lifecycle,
      proc_id,
      sess_id,
      [extensions]
    )
  end

  defp do_normalize("result", frame, run_id, ordinal, occurred_at, proc_id, sess_id) do
    # VERIFIED quirk: subtype stays "success" even when is_error is true —
    # classification keys on is_error / terminal_reason ONLY.
    is_error = frame["is_error"] == true
    terminal_reason = frame["terminal_reason"]
    source = source_id(frame, "claude-result-#{ordinal}")

    if is_error do
      code =
        case terminal_reason do
          reason when is_binary(reason) and reason != "" -> sanitize_string(reason)
          _ -> "claude_error"
        end

      message =
        case frame["result"] do
          text when is_binary(text) and text != "" -> truncate(sanitize_string(text))
          _ -> "Claude run reported an error (#{code})"
        end

      # Gate 0A rule: refusal shape UNVERIFIED — errors are :task_failed,
      # NEVER :quota_refused.
      error = Error.new(:task_failed, code, message, details: %{"claude-headless:code" => code})

      extensions = %{
        "claude-headless:frame_type" => "result",
        "claude-headless:terminal_reason" => sanitize_string(terminal_reason),
        "claude-headless:subtype" => sanitize_string(frame["subtype"])
      }

      case build_event(
             run_id: run_id,
             ordinal: ordinal,
             source_event_id: source,
             occurred_at: occurred_at,
             kind: :error,
             process_id: proc_id,
             provider_session_id: sess_id,
             error: error,
             extensions: extensions
           ) do
        {:ok, event} -> {:ok, [mark_terminal(event)]}
        {:error, _} = err -> err
      end
    else
      status = if terminal_reason == "completed", do: "completed", else: "failed"

      extensions =
        %{
          "claude-headless:frame_type" => "result",
          "claude-headless:terminal_reason" => sanitize_string(terminal_reason),
          "claude-headless:status" => status
        }
        |> maybe_put_number("claude-headless:num_turns", frame["num_turns"])
        |> maybe_put_number("claude-headless:duration_ms", frame["duration_ms"])
        |> maybe_put_number("claude-headless:total_cost_usd", frame["total_cost_usd"])

      case build_event(
             run_id: run_id,
             ordinal: ordinal,
             source_event_id: source,
             occurred_at: occurred_at,
             kind: :result,
             process_id: proc_id,
             provider_session_id: sess_id,
             result: %{status: status, artifact_id: nil},
             extensions: extensions
           ) do
        {:ok, event} -> {:ok, [mark_terminal(event)]}
        {:error, _} = err -> err
      end
    end
  end

  defp do_normalize(_type, _frame, _run_id, _ordinal, _occurred_at, _proc_id, _sess_id) do
    {:skip, :unhandled_frame}
  end

  # --- Content blocks ---

  # START boundary: assistant tool_use block. Correlate by toolu_ id only.
  defp assistant_block_extensions(%{"type" => "tool_use"} = block, _frame, message_id, request_id) do
    input = if is_map(block["input"]), do: block["input"], else: %{}

    ext =
      %{
        "claude-headless:boundary" => "start",
        "claude-headless:tool_use_id" => sanitize_string(block["id"]),
        "claude-headless:tool_name" => sanitize_string(block["name"])
      }
      |> maybe_put("claude-headless:command", sanitize_string(input["command"]))
      |> maybe_put("claude-headless:description", sanitize_string(input["description"]))
      |> maybe_put("claude-headless:message_id", message_id)
      |> maybe_put("claude-headless:request_id", request_id)

    {:command, ext}
  end

  defp assistant_block_extensions(%{"type" => "text", "text" => text}, _frame, _mid, _rid)
       when is_binary(text) and text != "" do
    {:output, %{"claude-headless:output_text" => truncate(sanitize_string(text))}}
  end

  # Reasoning-adjacent blocks are never persisted (Codex parity).
  defp assistant_block_extensions(%{"type" => type}, _frame, _mid, _rid)
       when type in ["thinking", "reasoning", "redacted_thinking"] do
    :skip
  end

  defp assistant_block_extensions(_block, _frame, _mid, _rid), do: :skip

  # END boundary: user tool_result block. Correlate by toolu_ id only.
  defp user_block_extensions(%{"type" => "tool_result"} = block, tool_use_result) do
    is_error = block["is_error"] == true

    ext =
      %{
        "claude-headless:boundary" => "end",
        "claude-headless:tool_use_id" => sanitize_string(block["tool_use_id"]),
        "claude-headless:is_error" => is_error,
        "claude-headless:status" => if(is_error, do: "failed", else: "completed")
      }
      |> maybe_put(
        "claude-headless:tool_result_text",
        truncate(sanitize_string(block_text(block)))
      )
      |> maybe_put(
        "claude-headless:tool_stdout",
        truncate(sanitize_string(tool_use_result["stdout"]))
      )
      |> maybe_put(
        "claude-headless:tool_stderr",
        truncate(sanitize_string(tool_use_result["stderr"]))
      )
      |> maybe_put_bool("claude-headless:interrupted", tool_use_result["interrupted"])

    {:command, ext}
  end

  defp user_block_extensions(%{"type" => "text", "text" => text}, _result)
       when is_binary(text) and text != "" do
    {:output, %{"claude-headless:output_text" => truncate(sanitize_string(text))}}
  end

  defp user_block_extensions(_block, _result), do: :skip

  # --- Event construction ---

  defp build_events(run_id, ordinal, source, occurred_at, kind, proc_id, sess_id, ext_list) do
    events =
      ext_list
      |> Enum.with_index()
      |> Enum.map(fn {ext, offset} ->
        build_event(
          run_id: run_id,
          ordinal: ordinal + offset,
          source_event_id: if(offset == 0, do: source, else: "#{source}-#{offset}"),
          occurred_at: occurred_at,
          kind: kind,
          process_id: proc_id,
          provider_session_id: sess_id,
          extensions: ext
        )
      end)
      |> collect_events()

    {:ok, events}
  end

  # Drops events that fail contract validation (e.g. an extension value
  # that still trips the secret filter) instead of raising: a corrupt
  # frame must never crash the owning session.
  defp collect_events(results) do
    Enum.flat_map(results, fn
      {:ok, event} -> [event]
      {:error, _} -> []
    end)
  end

  defp build_event(fields) do
    attrs =
      fields
      |> Keyword.put(:version, 1)
      |> Enum.into(%{})

    HarnessEvent.new(attrs)
  end

  # Marks result/error events that terminate the one-shot run so the
  # session can transition without re-interpreting provider vocabulary.
  defp mark_terminal(%HarnessEvent{extensions: ext} = event) do
    %{event | extensions: Map.put(ext, "claude-headless:terminal", true)}
  end

  # --- Field helpers ---

  defp block_text(%{"content" => content}) when is_binary(content), do: content

  defp block_text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp block_text(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_bool(map, _key, nil), do: map
  defp maybe_put_bool(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp maybe_put_bool(map, _key, _value), do: map

  defp maybe_put_number(map, _key, nil), do: map
  defp maybe_put_number(map, key, value) when is_number(value), do: Map.put(map, key, value)
  defp maybe_put_number(map, _key, _value), do: map

  defp maybe_put_tools(map, tools) when is_list(tools) do
    names = tools |> Enum.filter(&is_binary/1) |> Enum.take(64)

    if names == [] do
      map
    else
      Map.put(map, "claude-headless:tools", names)
    end
  end

  defp maybe_put_tools(map, _tools), do: map

  defp maybe_put_retry(map, %{"subtype" => "api_retry"} = frame) do
    map
    |> maybe_put_number("claude-headless:retry_attempt", frame["attempt"])
    |> maybe_put_number("claude-headless:retry_max", frame["max_retries"])
    |> maybe_put("claude-headless:retry_error", sanitize_string(frame["error"]))
    |> maybe_put_number("claude-headless:retry_error_status", frame["error_status"])
  end

  defp maybe_put_retry(map, _frame), do: map

  defp maybe_put_window(map, _key, nil), do: map

  defp maybe_put_window(map, key, %{"utilization" => util}) when is_number(util) do
    Map.put(map, key, util)
  end

  defp maybe_put_window(map, _key, _window), do: map

  defp source_id(%{"uuid" => uuid}, _fallback)
       when is_binary(uuid) and byte_size(uuid) > 0 and byte_size(uuid) <= 200 do
    "claude-#{uuid}"
  end

  defp source_id(_frame, fallback), do: fallback

  defp extract_timestamp(%{"timestamp" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp extract_timestamp(_frame), do: DateTime.utc_now()

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

  defp truncate(nil), do: nil

  defp truncate(val) when is_binary(val) do
    if String.length(val) > @max_message_chars do
      String.slice(val, 0, @max_message_chars)
    else
      val
    end
  end
end
