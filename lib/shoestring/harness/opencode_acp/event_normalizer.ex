defmodule Shoestring.Harness.OpencodeAcp.EventNormalizer do
  @moduledoc """
  Normalizes `opencode acp` (Agent Client Protocol, JSON-RPC over stdio)
  frames into canonical `Shoestring.Harness.HarnessEvent` structs.

  Evidence: `plans/evidence/13-opencode-harness/README.md`. The handshake,
  session and error shapes are VERIFIED against opencode 2.0.31. The
  `session/update` prompt-stream shapes (`agent_message_chunk`, `tool_call`,
  `tool_call_update`, `plan`) and the `session/prompt` stop reasons follow the
  published Agent Client Protocol schema and are SCHEMA-ONLY until a live
  prompt is recorded.

  - Hidden reasoning (`agent_thought_chunk`) is never kept.
  - Provider fields are namespaced `opencode-acp:*`.
  - Paths, bearer tokens, API keys and home directories are scrubbed.
  - Nothing maps to `:quota_refused`: no opencode limit refusal has been
    observed, so provider failures surface as `:task_failed` (the Gate 0A
    rule the Claude adapter follows). An authentication refusal, VERIFIED to
    arrive before any model call, maps to `:authentication_required`.
  """

  alias Shoestring.Harness.{Error, HarnessEvent}

  @namespace "opencode-acp"

  @secret_patterns [
    {~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i, "[REDACTED_BEARER]"},
    {~r/\b(?:api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*[^\s,]+/i,
     "[REDACTED_SECRET]"},
    {~r/\bsk-[A-Za-z0-9_-]{12,}/, "[REDACTED_KEY]"},
    {~r/\/Users\/[^\/]+/, "$HOME"}
  ]

  # ACP tool kinds. `execute` runs a shell command; every other kind (or a
  # missing one) is potentially mutating and is tracked as a tool.
  @command_kind "execute"
  @end_statuses ["completed", "failed"]

  @doc """
  Normalizes a decoded `session/update` notification.

  Options: `:process_id`, `:provider_session_id`, `:clock`, and `:tool_kinds`
  (the kind each open tool call started with, keyed by `toolCallId`; a
  `tool_call_update` carries no kind of its own).

  Returns `{:ok, event}`, `{:skip, reason}` or `{:error, reason}`.
  """
  @spec normalize(map(), String.t(), pos_integer(), map()) ::
          {:ok, HarnessEvent.t()} | {:skip, atom()} | {:error, term()}
  def normalize(frame, run_id, ordinal, opts \\ %{})

  def normalize(
        %{"method" => "session/update", "params" => %{"update" => %{} = update} = params},
        run_id,
        ordinal,
        opts
      ) do
    base = %{
      run_id: run_id,
      ordinal: ordinal,
      occurred_at: now(opts),
      process_id: Map.get(opts, :process_id),
      provider_session_id:
        sanitize_string(params["sessionId"]) || Map.get(opts, :provider_session_id)
    }

    update(update["sessionUpdate"], update, base, opts)
  end

  def normalize(%{"method" => "session/update"}, _run_id, _ordinal, _opts),
    do: {:error, :unshaped_session_update}

  def normalize(_frame, _run_id, _ordinal, _opts), do: {:skip, :unhandled_frame}

  defp update("agent_message_chunk", update, base, _opts) do
    case chunk_text(update["content"]) do
      {:ok, text} ->
        build(base, "message-delta-#{base.ordinal}", :output, %{"delta" => text})

      {:error, _} = error ->
        error
    end
  end

  defp update(kind, _update, _base, _opts) when kind in ["agent_thought_chunk"],
    do: {:skip, :hidden_reasoning}

  # A loaded session replays the user's own turns; they are input, not work.
  defp update("user_message_chunk", _update, _base, _opts), do: {:skip, :user_message}

  defp update("tool_call", update, base, _opts) do
    id = sanitize_string(update["toolCallId"])
    kind = update["kind"]
    status = update["status"] || "pending"
    boundary = if status in @end_statuses, do: "end", else: "start"

    tool_event(base, "tool-call-#{id || base.ordinal}", kind, %{
      "tool_call_id" => id,
      "tool_kind" => kind,
      "title" => sanitize_string(update["title"]),
      "command" => command(update),
      "status" => status,
      "boundary" => boundary
    })
  end

  defp update("tool_call_update", update, base, opts) do
    id = sanitize_string(update["toolCallId"])
    status = update["status"]

    if status in @end_statuses do
      kind = update["kind"] || get_in(opts, [:tool_kinds, update["toolCallId"]])

      tool_event(base, "tool-call-end-#{id || base.ordinal}", kind, %{
        "tool_call_id" => id,
        "tool_kind" => kind,
        "status" => status,
        "boundary" => "end"
      })
    else
      # Progress on an open call (`in_progress`, new content) is not a
      # boundary and never spends.
      build(base, "tool-call-progress-#{base.ordinal}", :lifecycle, %{
        "tool_call_id" => id,
        "status" => status
      })
    end
  end

  defp update("plan", update, base, _opts) do
    entries = if is_list(update["entries"]), do: update["entries"], else: []

    build(base, "plan-#{base.ordinal}", :lifecycle, %{
      "update" => "plan",
      "entries" => length(entries)
    })
  end

  defp update(kind, _update, _base, _opts)
       when kind in [
              "available_commands_update",
              "current_mode_update",
              "config_option_update",
              "session_info_update",
              "usage_update"
            ],
       do: {:skip, :session_metadata}

  defp update(_other, _update, _base, _opts), do: {:skip, :unhandled_update}

  defp tool_event(base, source_event_id, @command_kind, extensions),
    do: build(base, source_event_id, :command, extensions)

  defp tool_event(base, source_event_id, _kind, extensions),
    do: build(base, source_event_id, :tool, extensions)

  @doc """
  The completed message an agent wrote, as one `:output` event carrying its
  text. ACP streams messages only as chunks, so the session emits this when a
  message ends (a tool call starts, or the prompt returns); it is the
  response-completion boundary the lease counts.
  """
  @spec message_completed(String.t(), String.t(), pos_integer(), map()) ::
          {:ok, HarnessEvent.t()} | {:error, term()}
  def message_completed(text, run_id, ordinal, opts \\ %{}) do
    build(
      base(run_id, ordinal, opts),
      "message-completed-#{ordinal}",
      :output,
      %{"text" => sanitize_string(text)}
    )
  end

  @doc """
  Normalizes the `session/prompt` response: the turn outcome.

  `{:ok, %{"stopReason" => reason}}` for a result, `{:error, rpc_error}` for
  a JSON-RPC error.
  """
  @spec prompt_outcome({:ok, map()} | {:error, term()}, String.t(), pos_integer(), map()) ::
          {:ok, HarnessEvent.t()} | {:error, term()}
  def prompt_outcome(outcome, run_id, ordinal, opts \\ %{})

  def prompt_outcome({:ok, %{"stopReason" => "end_turn"}}, run_id, ordinal, opts) do
    build(
      base(run_id, ordinal, opts),
      "prompt-completed-#{ordinal}",
      :result,
      %{
        "stop_reason" => "end_turn",
        "status" => "completed"
      }, result: %{status: "completed", artifact_id: nil})
  end

  def prompt_outcome({:ok, %{"stopReason" => "cancelled"}}, run_id, ordinal, opts) do
    build(
      base(run_id, ordinal, opts),
      "prompt-cancelled-#{ordinal}",
      :result,
      %{
        "stop_reason" => "cancelled",
        "status" => "interrupted",
        "interrupted" => true
      }, result: %{status: "interrupted", artifact_id: nil})
  end

  def prompt_outcome({:ok, %{"stopReason" => reason}}, run_id, ordinal, opts)
      when is_binary(reason) do
    error =
      Error.new(:task_failed, sanitize_string(reason), "Turn stopped: #{sanitize_string(reason)}")

    build(
      base(run_id, ordinal, opts),
      "prompt-stopped-#{ordinal}",
      :error,
      %{
        "stop_reason" => sanitize_string(reason),
        "status" => "failed"
      }, error: error)
  end

  def prompt_outcome({:ok, _other}, run_id, ordinal, opts) do
    error = Error.new(:task_failed, "unshaped_prompt_result", "Prompt returned no stop reason")

    build(
      base(run_id, ordinal, opts),
      "prompt-unshaped-#{ordinal}",
      :error,
      %{"status" => "failed"}, error: error)
  end

  def prompt_outcome({:error, rpc_error}, run_id, ordinal, opts) do
    error = normalize_rpc_error(rpc_error)

    build(
      base(run_id, ordinal, opts),
      "prompt-failed-#{ordinal}",
      :error,
      %{
        "status" => "failed",
        "rpc_code" => rpc_code(rpc_error)
      }, error: error)
  end

  @doc """
  Maps a JSON-RPC error object into a canonical `Shoestring.Harness.Error`.

  opencode answers a prompt whose provider login is missing or stale with
  `-32000` "Authentication required: …" before any model call (VERIFIED,
  2.0.31); that is `:authentication_required`. Everything else is
  `:task_failed`.
  """
  @spec normalize_rpc_error(term()) :: Error.t()
  def normalize_rpc_error(%{"message" => message} = error) when is_binary(message) do
    text = sanitize_string(message)

    if error["code"] == -32000 and String.starts_with?(message, "Authentication required") do
      Error.new(:authentication_required, "provider_auth_required", text,
        details: %{"#{@namespace}:rpc_code" => -32000}
      )
    else
      Error.new(:task_failed, "prompt_failed", text,
        details: %{"#{@namespace}:rpc_code" => rpc_code(error)}
      )
    end
  end

  def normalize_rpc_error(_other),
    do: Error.new(:task_failed, "prompt_failed", "Prompt failed without an error message")

  defp rpc_code(%{"code" => code}) when is_integer(code), do: code
  defp rpc_code(_other), do: nil

  defp base(run_id, ordinal, opts) do
    %{
      run_id: run_id,
      ordinal: ordinal,
      occurred_at: now(opts),
      process_id: Map.get(opts, :process_id),
      provider_session_id: Map.get(opts, :provider_session_id)
    }
  end

  defp build(base, source_event_id, kind, extensions, extra \\ []) do
    base
    |> Map.merge(%{
      version: 1,
      source_event_id: source_event_id,
      kind: kind,
      artifact_id: nil,
      capacity_snapshot_id: nil,
      error: Keyword.get(extra, :error),
      result: Keyword.get(extra, :result),
      extensions: namespace(extensions)
    })
    |> HarnessEvent.new()
  end

  defp namespace(extensions) do
    extensions
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {"#{@namespace}:#{key}", value} end)
  end

  # ACP content blocks: text is the only kind an agent message needs; other
  # blocks (images, resources) contribute no text.
  defp chunk_text(%{"type" => "text", "text" => text}) when is_binary(text),
    do: {:ok, sanitize_string(text)}

  defp chunk_text(%{"type" => type}) when is_binary(type), do: {:ok, ""}
  defp chunk_text(_other), do: {:error, :unshaped_message_chunk}

  defp command(%{"rawInput" => %{"command" => command}}) when is_binary(command),
    do: sanitize_string(command)

  defp command(_update), do: nil

  defp now(opts) do
    case Map.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _ -> DateTime.utc_now()
    end
  end

  @doc "Strips secret patterns and personal home directories from a string."
  @spec sanitize_string(term()) :: String.t() | nil
  def sanitize_string(nil), do: nil

  def sanitize_string(value) when is_binary(value) do
    Enum.reduce(@secret_patterns, value, fn {regex, replacement}, acc ->
      Regex.replace(regex, acc, replacement)
    end)
  end

  def sanitize_string(value), do: to_string(value)
end
