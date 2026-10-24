defmodule Shoestring.Harness.OpencodeAcp do
  @moduledoc """
  Execution adapter for plan tasks run through the locally installed
  `opencode` CLI over the Agent Client Protocol (`opencode acp`).

  Conforms to `Shoestring.Harness.Adapter`. Contract areas
  (`Shoestring.Harness.ContractSuite`):

  1. Identity and compatibility reporting — implemented.
  2. Normalized start, stream, completion, failure, cancellation —
     implemented. The handshake is VERIFIED against opencode 2.0.31; the
     prompt stream is SCHEMA-ONLY until a live prompt is recorded.
  3. Resume — NOT declared. `session/resume` is VERIFIED to restore a
     session's model and effort, but a resumed prompt's completion is
     UNVERIFIED, so `:resume` is withheld (the Claude adapter's precedent).
  4. Quota refusal classification — no opencode limit refusal has been
     observed, so nothing maps to `:quota_refused`; an expired login maps to
     `:authentication_required` (VERIFIED, arrives before any model call).
  5. Missing / malformed capacity behavior — opencode exposes no remaining
     quota without inference, so the probe is an honest `:unknown`
     snapshot. An `openai/…` model draws on the same ChatGPT subscription as
     Codex, which Shoestring cannot observe.
  6. Secret-free persistence and diagnostics — the normalizer scrubs paths
     and secrets; Shoestring never reads opencode's login.
  7. Terminal cancellation idempotency — implemented.

  Model selection is per agent role (`provider/model`). opencode keeps its own
  login; Shoestring never signs in, stores or reads it. Planning and review
  stay on Claude and Codex.

  Evidence: `plans/evidence/13-opencode-harness/README.md`.
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

  alias Shoestring.Harness.OpencodeAcp.{EventNormalizer, Sandbox, Session}

  @adapter_id "opencode_acp"
  @adapter_version "2.0.31"
  @provider "opencode"
  @table :opencode_acp_sessions

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
  def capabilities, do: MapSet.new([:cancel])

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
        {:ok, snapshot(:incompatible, Map.get(opts, :scope, "subscription"))}

      _ ->
        {:ok, snapshot(:unknown, Map.get(opts, :scope, "subscription"))}
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
        if live_or_transport?(opts),
          do: start_session(request, opts),
          else: start_simulated(request)
    end
  end

  @doc """
  Cancels a running session. With `boundary: :safe | :item | :lease` it pends
  like a lease safe stop and the prompt outcome resolves it; by default it
  cancels and reaps the whole process tree at once.
  """
  @impl Shoestring.Harness.Adapter
  @spec cancel(RunIdentity.t(), map()) :: {:ok, :cancelled} | {:error, Error.t()}
  def cancel(%RunIdentity{} = identity, opts \\ %{}) do
    ensure_table()

    with false <- Map.get(opts, :simulate) == :already_cancelled,
         {:ok, pid} <- lookup_session(identity.run_id) do
      Session.cancel(pid, opts)
    else
      _ -> {:ok, :cancelled}
    end
  end

  @impl Shoestring.Harness.Adapter
  def status(%RunIdentity{} = identity, _opts \\ %{}) do
    ensure_table()

    case lookup_session(identity.run_id) do
      {:ok, pid} -> Session.status(pid)
      _ -> {:ok, %{status: :unknown}}
    end
  end

  @impl Shoestring.Harness.Adapter
  def stream(%RunIdentity{} = identity, opts \\ %{}) do
    ensure_table()

    cond do
      Map.get(opts, :simulate) == :failure ->
        {:ok, simulated_failure_events(identity)}

      match?({:ok, _}, lookup_session(identity.run_id)) ->
        {:ok, pid} = lookup_session(identity.run_id)
        Session.stream_events(pid)

      live_or_transport?(opts) ->
        {:error,
         Error.new(
           :transport,
           "session_not_found",
           "No live opencode session is registered for this run; no provider events can be read"
         )}

      true ->
        {:ok, simulated_completion_events(identity)}
    end
  end

  # --- Sessions ---

  defp live_or_transport?(opts) do
    Map.get(opts, :live) == true or Map.get(opts, :mode) == :live or
      Map.has_key?(opts, :transport_pid) or Map.has_key?(opts, :transport)
  end

  defp start_session(%RunRequest{} = request, opts) do
    workdir = Map.get(opts, :workdir) || request.workspace_ref
    timeout = Map.get(opts, :handshake_timeout_ms, 30_000)

    with {:ok, workdir} <- validate_workdir(workdir),
         {:ok, launch} <- launch(opts, workdir, request.workspace_ref) do
      session_opts =
        opts
        |> Map.to_list()
        |> Keyword.merge(launch)
        |> Keyword.merge(
          run_request: request,
          run_id: request.dispatch_id,
          workdir: workdir,
          handshake_timeout_ms: timeout
        )

      case Session.start_link(session_opts) do
        {:ok, pid} ->
          case Session.await_run_identity(pid, timeout + 2_000) do
            {:ok, run_identity} ->
              store_session(run_identity.run_id, pid)
              {:ok, run_identity}

            {:error, %Error{} = error} ->
              Session.shutdown(pid)
              {:error, error}
          end

        {:error, reason} ->
          {:error, Error.new(:transport, "session_start_failed", inspect(reason))}
      end
    end
  end

  # A sandboxed launch fails closed when its profile cannot be built; it never
  # falls back to an unsandboxed launch.
  defp launch(opts, workdir, workspace_ref) do
    if Map.get(opts, :sandbox) == true do
      sandbox_opts =
        [
          worktrees_dir: Map.get(opts, :sandbox_worktrees_dir),
          executable: Map.get(opts, :executable)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case Sandbox.prepare(workdir, workspace_ref, sandbox_opts) do
        {:ok, sandbox} ->
          {:ok,
           [
             command: sandbox.command,
             executable: sandbox.command,
             args: sandbox.args,
             env: sandbox.env ++ Map.get(opts, :env, []),
             sandboxed: true
           ]}

        {:error, reason} ->
          {:error, Error.new(:transport, "sandbox_unavailable", "Sandbox refused: #{reason}")}
      end
    else
      {:ok, [sandboxed: false]}
    end
  end

  defp validate_workdir(dir) when is_binary(dir) and dir != "" do
    if File.dir?(dir),
      do: {:ok, dir},
      else:
        {:error,
         Error.new(:transport, "invalid_workdir", "Working directory does not exist: #{dir}")}
  end

  defp validate_workdir(_dir),
    do: {:error, Error.new(:transport, "invalid_workdir", "Working directory is required")}

  defp start_simulated(%RunRequest{} = request) do
    RunIdentity.new(%{
      run_id: request.dispatch_id,
      harness_id: @adapter_id,
      process_id: "os-pid-#{System.unique_integer([:positive])}",
      provider_session_id: "ses_000000000000000000000001"
    })
  end

  # --- Simulated streams (contract conforming) ---

  defp simulated_completion_events(%RunIdentity{} = identity) do
    opts = %{process_id: identity.process_id, provider_session_id: identity.provider_session_id}

    update = fn update ->
      %{
        "method" => "session/update",
        "params" => %{"sessionId" => identity.provider_session_id, "update" => update}
      }
    end

    [
      fn o ->
        EventNormalizer.normalize(
          update.(%{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "call_000000000000000000000001",
            "kind" => "execute",
            "status" => "pending",
            "title" => "printf hello",
            "rawInput" => %{"command" => "printf hello"}
          }),
          identity.run_id,
          o,
          opts
        )
      end,
      fn o ->
        EventNormalizer.normalize(
          update.(%{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => "call_000000000000000000000001",
            "status" => "completed"
          }),
          identity.run_id,
          o,
          Map.put(opts, :tool_kinds, %{"call_000000000000000000000001" => "execute"})
        )
      end,
      fn o -> EventNormalizer.message_completed("Done.", identity.run_id, o, opts) end,
      fn o ->
        EventNormalizer.prompt_outcome(
          {:ok, %{"stopReason" => "end_turn"}},
          identity.run_id,
          o,
          opts
        )
      end
    ]
    |> Enum.with_index(1)
    |> Enum.map(fn {build, ordinal} ->
      {:ok, %HarnessEvent{} = event} = build.(ordinal)
      event
    end)
  end

  defp simulated_failure_events(%RunIdentity{} = identity) do
    opts = %{process_id: identity.process_id, provider_session_id: identity.provider_session_id}

    {:ok, event} =
      EventNormalizer.prompt_outcome(
        {:ok, %{"stopReason" => "refusal"}},
        identity.run_id,
        1,
        opts
      )

    [event]
  end

  # --- Capacity ---

  # opencode reports no remaining quota without inference: the snapshot is an
  # honest unknown, never an invented figure.
  defp snapshot(state, scope) do
    now = DateTime.utc_now()

    {tier, compatibility, confidence, reason} =
      case state do
        :unknown -> {:reactive_only, :compatible, :none, "opencode_no_capacity_signal"}
        :incompatible -> {:unsupported, :incompatible, :none, "cli_incompatible"}
      end

    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :unknown,
          windows: [],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @adapter_id,
            provider_id: @provider,
            invocation_mode: "acp_stdio",
            event: :explicit_read
          },
          scope: scope,
          confidence: confidence,
          support_tier: tier,
          compatibility_state: compatibility,
          reason: reason,
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  # --- Session table ---

  defp ensure_table do
    Shoestring.Harness.SessionTables.ensure_table(@table)
  rescue
    _ -> :ok
  end

  defp store_session(run_id, pid) do
    :ets.insert(@table, {run_id, pid})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Looks up a live session pid for a run id."
  @spec lookup_session(term()) :: {:ok, pid()} | {:error, :not_found}
  def lookup_session(run_id) do
    ensure_table()

    case :ets.lookup(@table, run_id) do
      [{^run_id, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc false
  @spec release(RunIdentity.t()) :: :ok
  def release(%RunIdentity{run_id: run_id}), do: release_by_run(run_id)

  defp release_by_run(run_id) do
    case lookup_session(run_id) do
      {:ok, pid} -> Session.shutdown(pid)
      _ -> :ok
    end

    :ets.delete(@table, run_id)
    :ok
  rescue
    _ -> :ok
  end
end
