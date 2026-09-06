defmodule Shoestring.Harness.ClaudeHeadless do
  @moduledoc """
  Execution adapter targeting Claude Code headless mode:
  `claude --print --verbose --output-format stream-json`, a one-shot
  process streaming JSONL on stdout.

  Conforms to `Shoestring.Harness.Adapter`. Contract areas map as follows
  (`Shoestring.Harness.ContractSuite`):

  1. Identity and compatibility reporting — implemented.
  2. Normalized start, stream, completion, failure, cancellation —
     implemented. Cancellation is process-kill only.
  3. Resume — NOT declared. Resume mechanics are VERIFIED (the CLI accepts
     `--resume <session_id>` and re-emits the same `session_id`), but a
     resumed turn's *completion* is UNVERIFIED (auth blocked the model
     call in every observed resume attempt), so `:resume` is honestly
     absent and the ContractSuite's resume test is legitimately skipped.
  4. Quota refusal classification — the refusal shape is UNVERIFIED (only
     `"allowed"` status frames were ever captured), so NOTHING maps to
     `:quota_refused`: provider errors surface as `:task_failed` on the
     stream and `probe/1` has no live refusal path. Standing Gate 0A rule.
  5. Missing / malformed capacity behavior — implemented (same
     snapshot-degradation pattern as the Codex adapter).
  6. Secret-free persistence and diagnostics — implemented (same scrubber
     pattern as the Codex normalizer).
  7. Terminal cancellation idempotency — implemented.

  Evidence: `plans/evidence/04-single-elf/claude-exec-events.md` and the
  committed fixtures under `plans/evidence/04-single-elf/fixtures/claude/`.
  NO live runs were used to build this adapter.
  """

  @behaviour Shoestring.Harness.Adapter

  alias Shoestring.Harness.{
    CapacitySnapshot,
    Error,
    HarnessEvent,
    Identity,
    RunIdentity,
    RunRequest
  }

  alias Shoestring.Harness.ClaudeHeadless.{EventNormalizer, Session}

  @adapter_id "claude_headless_stream_json"
  # Pinned to the CLI version the wire contract was captured against
  # (VERIFIED — `claude_code_version: "2.1.261"` in both committed init
  # frames), mirroring the Codex adapter's CLI-version pinning.
  @adapter_version "2.1.261"
  @provider "claude"
  @table :claude_headless_sessions

  # --- Shoestring.Harness.Adapter Callbacks ---

  @impl Shoestring.Harness.Adapter
  @spec identity() :: Identity.t()
  def identity do
    {:ok, id} =
      Identity.new(%{
        adapter_id: @adapter_id,
        provider: @provider,
        adapter_version: @adapter_version,
        schema_version: 1,
        invocation_mode: :process
      })

    id
  end

  @impl Shoestring.Harness.Adapter
  @spec capabilities() :: MapSet.t(Shoestring.Harness.Adapter.capability())
  def capabilities do
    # Deliberately narrow: :resume is withheld because resumed-turn
    # completion is UNVERIFIED (see moduledoc), and there is no :send —
    # the one-shot protocol has no in-band input channel.
    MapSet.new([:cancel])
  end

  @impl Shoestring.Harness.Adapter
  @spec probe(map()) :: {:ok, CapacitySnapshot.t()} | {:error, Error.t()}
  def probe(opts \\ %{}) do
    case Map.get(opts, :simulate) do
      :quota_refused ->
        {:error,
         Error.new(:quota_refused, "quota_refused", "Quota limit reached for this period",
           retryable: false
         )}

      :missing_config ->
        {:error,
         Error.new(
           :schema_incompatible,
           "missing_required_config",
           "Required probe configuration absent"
         )}

      :incompatible ->
        {:ok, build_incompatible_snapshot()}

      _ ->
        do_probe(opts)
    end
  end

  @impl Shoestring.Harness.Adapter
  @spec start(RunRequest.t(), map()) :: {:ok, RunIdentity.t()} | {:error, Error.t()}
  def start(%RunRequest{} = request, opts \\ %{}) do
    ensure_table()

    case Map.get(opts, :simulate) do
      :failure ->
        {:error, Error.new(:task_failed, "start_failed", "Simulated start failure")}

      :quota_refused ->
        {:error, Error.new(:quota_refused, "quota_refused", "Quota limit exceeded for this turn")}

      _ ->
        if live_or_transport?(opts) do
          start_session(request, opts)
        else
          start_simulated(request, opts)
        end
    end
  end

  @doc """
  Cancels a running session by killing the whole owned process group.

  Options:

    * `:boundary` — when `:safe`, `:item`, or `:lease`, the kill is
      deferred until the in-flight tool set drains (the in-flight
      command's `tool_result` is observed first). Deferred or not, the
      outcome is always `killpg`: Claude has no in-band interrupt, and
      this path does not pretend otherwise.
  """
  @impl Shoestring.Harness.Adapter
  @spec cancel(RunIdentity.t(), map()) :: {:ok, :cancelled} | {:error, Error.t()}
  def cancel(%RunIdentity{} = identity, opts \\ %{}) do
    ensure_table()

    if Map.get(opts, :simulate) == :already_cancelled do
      {:ok, :cancelled}
    else
      case lookup_session(identity.run_id) do
        {:ok, session_pid} when is_pid(session_pid) ->
          Session.cancel(session_pid, opts)

        _ ->
          # Already cancelled or finished; terminal idempotency returns :ok
          {:ok, :cancelled}
      end
    end
  end

  @impl Shoestring.Harness.Adapter
  @spec status(RunIdentity.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def status(%RunIdentity{} = identity, _opts \\ %{}) do
    ensure_table()

    case lookup_session(identity.run_id) do
      {:ok, session_pid} when is_pid(session_pid) ->
        Session.status(session_pid)

      _ ->
        {:ok, %{status: :unknown}}
    end
  end

  @impl Shoestring.Harness.Adapter
  @spec stream(RunIdentity.t(), map()) ::
          {:ok, Enumerable.t(HarnessEvent.t())} | {:error, Error.t()}
  def stream(%RunIdentity{} = identity, opts \\ %{}) do
    ensure_table()

    case Map.get(opts, :simulate) do
      :failure ->
        {:ok, simulated_failure_events(identity)}

      _ ->
        case lookup_session(identity.run_id) do
          {:ok, session_pid} when is_pid(session_pid) ->
            Session.stream_events(session_pid)

          _ ->
            {:ok, simulated_completion_events(identity, opts)}
        end
    end
  end

  @doc """
  Builds the exact argv for a headless run from a prompt.

  Evidence-backed shape (VERIFIED): `--verbose` is mandatory alongside
  `--print` + `stream-json`, and `--tools` is variadic so the `=` form is
  required (the space form swallows the positional prompt). There is no
  `-C/--cd` flag — the working directory is pinned via the spawned
  process's cwd (`:workdir` start option), not here.
  """
  @spec build_argv(String.t(), map()) :: [String.t()]
  def build_argv(prompt, opts \\ %{}) when is_binary(prompt) do
    tools = Map.get(opts, :tools, "Bash")
    argv = ["claude", "--print", "--verbose", "--output-format", "stream-json"]

    argv =
      if Map.get(opts, :permission_bypass, true) do
        argv ++ ["--dangerously-skip-permissions"]
      else
        argv
      end

    argv ++ ["--tools=#{tools}", prompt]
  end

  # --- Session Management ---

  defp live_or_transport?(opts) do
    Map.get(opts, :live) == true or
      Map.get(opts, :mode) == :live or
      Map.has_key?(opts, :transport_pid) or
      Map.has_key?(opts, :transport)
  end

  defp start_session(%RunRequest{} = request, opts) do
    session_opts =
      opts
      |> Map.to_list()
      |> Keyword.put(:run_request, request)
      |> Keyword.put(:run_id, request.dispatch_id)
      |> Keyword.put_new(:tools, "Bash")
      |> Keyword.put_new(:permission_bypass, true)

    case Session.start_link(session_opts) do
      {:ok, pid} ->
        case Session.await_run_identity(pid) do
          {:ok, run_identity} ->
            store_session(run_identity.run_id, pid)
            {:ok, run_identity}

          {:error, %Error{} = err} ->
            {:error, err}

          {:error, reason} ->
            {:error, Error.new(:transport, "session_start_failed", inspect(reason))}
        end

      {:error, reason} ->
        {:error, Error.new(:transport, "session_start_failed", inspect(reason))}
    end
  end

  defp start_simulated(%RunRequest{} = request, _opts) do
    run_id = request.dispatch_id
    session_id = "aaaaaaaa-0000-4000-a000-000000000001"
    pid_str = "os-pid-#{System.unique_integer([:positive])}"

    RunIdentity.new(%{
      run_id: run_id,
      harness_id: @adapter_id,
      process_id: pid_str,
      provider_session_id: session_id
    })
  end

  # --- Simulated Event Streams (Contract Conforming) ---

  defp simulated_completion_events(%RunIdentity{} = identity, opts) do
    now = DateTime.utc_now()
    run_id = identity.run_id
    sess_id = identity.provider_session_id
    proc_id = identity.process_id

    frames = Map.get(opts, :frames)

    if is_list(frames) and length(frames) > 0 do
      {events, _} =
        Enum.reduce(frames, {[], 1}, fn frame, {acc, ord} ->
          case EventNormalizer.normalize(frame, run_id, ord, %{
                 process_id: proc_id,
                 provider_session_id: sess_id
               }) do
            {:ok, normalized} -> {acc ++ normalized, ord + length(normalized)}
            _ -> {acc, ord}
          end
        end)

      events
    else
      tool_id = "toolu_000000000000000000000001"

      [
        build_simulated_event(run_id, 1, now, :lifecycle, proc_id, sess_id, %{
          "frame_type" => "system",
          "subtype" => "init"
        }),
        build_simulated_event(run_id, 2, now, :command, proc_id, sess_id, %{
          "boundary" => "start",
          "tool_use_id" => tool_id,
          "tool_name" => "Bash",
          "command" => "printf hello",
          "status" => "started"
        }),
        build_simulated_event(run_id, 3, now, :command, proc_id, sess_id, %{
          "boundary" => "end",
          "tool_use_id" => tool_id,
          "tool_name" => "Bash",
          "status" => "completed",
          "is_error" => false
        }),
        build_simulated_event(run_id, 4, now, :output, proc_id, sess_id, %{
          "output_text" => "Done."
        }),
        build_simulated_event(
          run_id,
          5,
          now,
          :result,
          proc_id,
          sess_id,
          %{
            "frame_type" => "result",
            "terminal_reason" => "completed",
            "status" => "completed"
          },
          result: %{status: "completed", artifact_id: nil}
        )
      ]
    end
  end

  defp simulated_failure_events(%RunIdentity{} = identity) do
    now = DateTime.utc_now()
    run_id = identity.run_id
    sess_id = identity.provider_session_id
    proc_id = identity.process_id

    error = Error.new(:task_failed, "run_failed", "Run execution failed")

    [
      build_simulated_event(run_id, 1, now, :lifecycle, proc_id, sess_id, %{
        "frame_type" => "system",
        "subtype" => "init"
      }),
      build_simulated_event(
        run_id,
        2,
        now,
        :error,
        proc_id,
        sess_id,
        %{
          "frame_type" => "result",
          "terminal_reason" => "api_error"
        },
        error: error
      )
    ]
  end

  defp build_simulated_event(
         run_id,
         ordinal,
         now,
         kind,
         proc_id,
         sess_id,
         extensions,
         extra \\ []
       ) do
    attrs =
      [
        version: 1,
        run_id: run_id,
        source_event_id: "evt-#{ordinal}",
        ordinal: ordinal,
        occurred_at: now,
        kind: kind,
        process_id: proc_id,
        provider_session_id: sess_id,
        artifact_id: Keyword.get(extra, :artifact_id),
        capacity_snapshot_id: Keyword.get(extra, :capacity_snapshot_id),
        error: Keyword.get(extra, :error),
        result: Keyword.get(extra, :result),
        extensions: namespace_extensions(extensions)
      ]
      |> Enum.into(%{})

    {:ok, event} = HarnessEvent.new(attrs)
    event
  end

  defp namespace_extensions(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key_str = to_string(k)

      namespaced =
        if String.contains?(key_str, ":") do
          key_str
        else
          "claude-headless:#{key_str}"
        end

      {namespaced, v}
    end)
  end

  defp namespace_extensions(_), do: %{}

  # --- Capacity Probe Helpers ---

  # The headless protocol has no live quota/status poll (unlike the
  # Codex monitor's account reads): the default probe is an honest
  # :unknown snapshot, never an invented utilization figure.
  defp do_probe(_opts) do
    {:ok, build_unknown_snapshot()}
  end

  defp build_unknown_snapshot do
    now = DateTime.utc_now()

    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: "00000000-0000-4000-8000-000000000089",
          capacity_state: :unknown,
          windows: [],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @adapter_id,
            provider_id: @provider,
            invocation_mode: "headless_stream_json",
            event: :explicit_read
          },
          scope: "account",
          confidence: :low,
          support_tier: :reactive_only,
          compatibility_state: :compatible,
          reason: "headless_no_live_signal",
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  defp build_incompatible_snapshot do
    now = DateTime.utc_now()

    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: "00000000-0000-4000-8000-000000000089",
          capacity_state: :unknown,
          windows: [],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @adapter_id,
            provider_id: @provider,
            invocation_mode: "headless_stream_json",
            event: :explicit_read
          },
          scope: "account",
          confidence: :none,
          support_tier: :unsupported,
          compatibility_state: :incompatible,
          reason: "cli_incompatible",
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  # --- Table Helpers ---

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
  rescue
    _ -> :ok
  end

  defp store_session(run_id, pid) do
    ensure_table()
    :ets.insert(@table, {run_id, pid})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Looks up a live session PID for the given run ID."
  @spec lookup_session(term()) :: {:ok, pid()} | {:error, :not_found}
  def lookup_session(run_id) do
    ensure_table()

    case :ets.lookup(@table, run_id) do
      [{^run_id, pid}] when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end
end
