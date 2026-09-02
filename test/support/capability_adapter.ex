defmodule Shoestring.Test.CapabilityAdapter do
  @behaviour Shoestring.Harness.Adapter

  alias Shoestring.Harness.{CapacitySnapshot, Error, HarnessEvent, Identity, RunIdentity}

  @adapter_id "test.adapter"
  @run_id "00000000-0000-4000-8000-000000000099"
  @snapshot_id "00000000-0000-4000-8000-000000000088"
  @observed_at ~U[2026-08-30 12:00:00.000000Z]
  @expires_at ~U[2026-08-30 12:05:00.000000Z]

  @impl true
  def identity do
    {:ok, identity} =
      Identity.new(%{
        adapter_id: @adapter_id,
        provider: "test",
        adapter_version: "1.0.0",
        schema_version: 1,
        invocation_mode: :fake
      })

    identity
  end

  @impl true
  def capabilities, do: MapSet.new([:resume, :cancel])

  @impl true
  def probe(opts) do
    case Map.get(opts, :simulate) do
      :quota_refused ->
        {:error,
         Error.new(:quota_refused, "quota_exceeded", "Quota limit reached for this period",
           retryable: false
         )}

      :unknown_capacity ->
        {:ok, unknown_snapshot()}

      :incompatible ->
        {:ok, incompatible_snapshot()}

      :missing_config ->
        {:error,
         Error.new(
           :schema_incompatible,
           "missing_required_config",
           "Required probe config absent"
         )}

      _ ->
        {:ok, known_snapshot()}
    end
  end

  @impl true
  def start(_request, opts) do
    case Map.get(opts, :simulate) do
      :failure ->
        {:error, Error.new(:task_failed, "start_failed", "Simulated start failure")}

      _ ->
        RunIdentity.new(%{
          run_id: @run_id,
          harness_id: @adapter_id,
          process_id: "pid-test-1",
          provider_session_id: "session-test-1"
        })
    end
  end

  @impl true
  def resume(run_identity, _request, _opts) do
    RunIdentity.new(%{
      run_id: run_identity.run_id,
      harness_id: @adapter_id,
      process_id: "pid-test-resumed",
      provider_session_id: "session-test-resumed"
    })
  end

  @impl true
  def cancel(_identity, opts) do
    case Map.get(opts, :simulate) do
      # Terminal idempotency: already cancelled is still ok
      :already_cancelled -> {:ok, :cancelled}
      _ -> {:ok, :cancelled}
    end
  end

  @impl true
  def status(_identity, _opts), do: {:ok, %{state: :running}}

  @impl true
  def stream(run_identity, opts) do
    run_id = run_identity.run_id

    case Map.get(opts, :simulate) do
      :failure -> {:ok, failure_events(run_id)}
      _ -> {:ok, completion_events(run_id)}
    end
  end

  defp completion_events(run_id) do
    [
      make_event(run_id, 1, :lifecycle),
      make_event(run_id, 2, :output),
      make_event(run_id, 3, :result, %{result: %{status: "completed", artifact_id: nil}})
    ]
  end

  defp failure_events(run_id) do
    [
      make_event(run_id, 1, :lifecycle),
      make_event(run_id, 2, :error, %{
        error: %{
          category: :task_failed,
          code: "task_failed",
          message: "Simulated task failure"
        }
      })
    ]
  end

  defp make_event(run_id, ordinal, kind, overrides \\ %{}) do
    {:ok, event} =
      HarnessEvent.new(
        Map.merge(
          %{
            version: 1,
            run_id: run_id,
            source_event_id: "event-#{ordinal}",
            ordinal: ordinal,
            occurred_at: @observed_at,
            kind: kind,
            process_id: "pid-test-1",
            provider_session_id: "session-test-1"
          },
          overrides
        )
      )

    event
  end

  defp known_snapshot do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: @snapshot_id,
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: 25.0, reset_at: @expires_at}
          ],
          observed_at: @observed_at,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @adapter_id,
            provider_id: "test",
            invocation_mode: "fake",
            event: :explicit_read
          },
          scope: "account",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: @observed_at
      )

    snapshot
  end

  defp unknown_snapshot do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: @snapshot_id,
          capacity_state: :unknown,
          windows: [],
          observed_at: @observed_at,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @adapter_id,
            provider_id: "test",
            invocation_mode: "fake",
            event: :explicit_read
          },
          scope: "account",
          confidence: :none,
          support_tier: :unsupported,
          compatibility_state: :degraded,
          reason: "probe_unconfigured",
          extensions: %{}
        },
        now: @observed_at
      )

    snapshot
  end

  defp incompatible_snapshot do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: @snapshot_id,
          capacity_state: :unknown,
          windows: [],
          observed_at: @observed_at,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @adapter_id,
            provider_id: "test",
            invocation_mode: "fake",
            event: :explicit_read
          },
          scope: "account",
          confidence: :none,
          support_tier: :unsupported,
          compatibility_state: :incompatible,
          reason: "adapter_version_incompatible",
          extensions: %{}
        },
        now: @observed_at
      )

    snapshot
  end
end
