defmodule Shoestring.Test.LiveBufferedAdapter do
  @moduledoc """
  Hermetic adapter double for the Elf's adapter-owned process path.

  It owns a real local process group, exposes cumulative buffered snapshots,
  and releases its terminal result only after a later stream poll. No provider
  CLI or network access is used.
  """

  @behaviour Shoestring.Harness.Adapter

  alias Shoestring.Elves.PortRunner
  alias Shoestring.Harness.{Error, HarnessEvent, Identity, RunIdentity}

  @table :shoestring_test_live_buffered_adapter_sessions

  @impl true
  def identity do
    {:ok, identity} =
      Identity.new(%{
        adapter_id: "shoestring.test.live_buffered",
        provider: "test",
        adapter_version: "1",
        schema_version: 1,
        invocation_mode: :process
      })

    identity
  end

  @impl true
  def capabilities, do: MapSet.new([:cancel])

  @impl true
  def probe(_opts),
    do: {:error, Error.new(:unsupported_capability, "probe_not_supported", "Test adapter")}

  @impl true
  def start(request, opts) do
    ensure_table()
    workdir = Map.get(opts, :workdir) || File.cwd!()
    runner_opts = [cd: workdir, kill_grace_ms: 200, reap_timeout_ms: 2_000]

    with {:ok, runner} <- PortRunner.spawn(["sleep", "30"], runner_opts),
         {:ok, identity} <-
           RunIdentity.new(%{
             run_id: request.dispatch_id,
             harness_id: "shoestring.test.live_buffered",
             process_id: to_string(runner.pgid),
             provider_session_id: "test-session"
           }) do
      session = %{
        runner: runner,
        poll: 0,
        scenario: Map.get(opts, :test_scenario, :complete),
        test_pid: Map.get(opts, :test_pid),
        workdir: workdir
      }

      true = :ets.insert(@table, {identity.run_id, session})
      notify(session, {:live_buffered_adapter_started, identity.run_id, workdir, runner.pgid})
      {:ok, identity}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:transport, "test_spawn_failed", inspect(reason))}
    end
  end

  @impl true
  def status(%RunIdentity{} = identity, _opts) do
    case lookup(identity.run_id) do
      {:ok, session} -> {:ok, %{status: :running, poll: session.poll}}
      :error -> {:ok, %{status: :unknown}}
    end
  end

  @impl true
  def stream(%RunIdentity{} = identity, _opts) do
    case lookup(identity.run_id) do
      {:ok, session} ->
        session = %{session | poll: session.poll + 1}
        true = :ets.insert(@table, {identity.run_id, session})
        notify(session, {:live_buffered_adapter_polled, identity.run_id, session.poll})
        {:ok, buffered_events(identity, session)}

      :error ->
        {:error, Error.new(:transport, "test_session_missing", "Test session is missing")}
    end
  end

  @impl true
  def cancel(%RunIdentity{} = identity, _opts) do
    case lookup(identity.run_id) do
      {:ok, session} ->
        notify(session, {:live_buffered_adapter_cancelled, identity.run_id})
        _ = PortRunner.terminate(session.runner, kill_grace_ms: 200, reap_timeout_ms: 2_000)
        {:ok, :cancelled}

      :error ->
        {:ok, :cancelled}
    end
  end

  @doc false
  def cleanup(run_id) do
    case lookup(run_id) do
      {:ok, session} ->
        _ = PortRunner.terminate(session.runner, kill_grace_ms: 200, reap_timeout_ms: 2_000)
        :ets.delete(@table, run_id)
        :ok

      :error ->
        :ok
    end
  end

  @doc false
  def release(%RunIdentity{run_id: run_id}) do
    :ets.delete(@table, run_id)
    :ok
  rescue
    _error -> :ok
  end

  defp buffered_events(identity, session) do
    lifecycle = event(identity, 1, :lifecycle, nil, "test-lifecycle")

    cond do
      session.scenario == :quiet ->
        [lifecycle]

      session.poll == 1 ->
        [lifecycle]

      true ->
        [
          lifecycle,
          event(identity, 2, :output, nil, "test-output"),
          event(identity, 3, :result, %{status: "completed", artifact_id: nil}, "test-result")
        ]
    end
  end

  defp event(identity, ordinal, kind, result, source_event_id) do
    %HarnessEvent{
      version: 1,
      run_id: identity.run_id,
      source_event_id: source_event_id,
      ordinal: ordinal,
      occurred_at: DateTime.utc_now(),
      kind: kind,
      process_id: identity.process_id,
      provider_session_id: identity.provider_session_id,
      artifact_id: nil,
      capacity_snapshot_id: nil,
      error: nil,
      result: result,
      extensions: %{"shoestring.test:event" => source_event_id}
    }
  end

  defp notify(%{test_pid: pid}, message) when is_pid(pid), do: send(pid, message)
  defp notify(_session, _message), do: :ok

  defp lookup(run_id) do
    ensure_table()

    case :ets.lookup(@table, run_id) do
      [{^run_id, session}] -> {:ok, session}
      [] -> :error
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      table ->
        table
    end
  end
end
