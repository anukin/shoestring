defmodule Shoestring.Harness.CodexProbeHonestyTest do
  @moduledoc """
  Hermetic regressions for `Shoestring.Harness.CodexAppServer.probe/1`.

  The adapter owns no independent quota source; the live account read
  belongs to `Shoestring.Harness.Capacity.CodexMonitor`. When the monitor is
  absent or unreadable, the probe must say so rather than invent a reading,
  because both admission and lease renewal consume the result as evidence.

  Both directions are asserted, per the standing contract: the fabricated
  reading is gone **and** a genuine monitor observation still passes through
  untouched.

  Hermetic: `Shoestring.Harness.Capacity.Codex.FakeTransport` and recorded
  Gate 0A fixtures only. No provider CLI, no network, no live quota.

  Locking note (standing contract): verified against base
  `6fd0ecd2e6929fcc7f393ac6e3f7166fc7a6b57d` in a separate checkout. Four of
  the five tests FAIL on base for a behavioural reason. "A genuine monitor
  observation passes through untouched" PASSES on base: it is a preservation
  test guarding the supported path against this change, not a lock on a fix.
  Each test's own comment records which it is.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionEvaluation, AdmissionPolicy}
  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Harness.Capacity.Fixtures
  alias Shoestring.Harness.{CapacitySnapshot, CodexAppServer}

  @monitor_clock ~U[2026-09-07 12:00:00.000000Z]

  setup do
    normal_fixture = Fixtures.load_fixture!("codex/normal-read.json")
    {:ok, normal_read: normal_fixture["payload"]["result"]}
  end

  describe "with no capacity monitor running" do
    setup do
      refute GenServer.whereis(CodexMonitor),
             "this suite requires no globally registered CodexMonitor"

      :ok
    end

    # REGRESSION LOCK. On base an absent monitor produced
    # `capacity_state: :observed`, `confidence: :high`, and a flat
    # `five_hour` window at `used_percent: 25.0` — a reading no one had
    # taken, presented as a high-confidence observation.
    test "the probe reports unknown rather than a fabricated observation" do
      assert {:ok, %CapacitySnapshot{} = snapshot} = CodexAppServer.probe(%{})

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none
      refute snapshot.support_tier == :proactive
      assert snapshot.reason == "monitor_not_running"

      # The fabricated utilization is gone, in both of its forms: there is
      # no invented percentage, and no manufactured zero standing in for
      # "no evidence" either.
      assert snapshot.windows == []
    end

    # REGRESSION LOCK. `Shoestring.Cobbler.Wakeups` keys its decision replay
    # guard on `snapshot_id`; a constant id made every unmonitored probe
    # indistinguishable from the one before it, so a recorded admit stayed
    # replayable under an id that never changed. Lease renewal chains to the
    # same id via `admitted_snapshot_id`.
    test "two probes are distinguishable observations, not one constant id" do
      assert {:ok, first} = CodexAppServer.probe(%{})
      assert {:ok, second} = CodexAppServer.probe(%{})

      refute first.snapshot_id == second.snapshot_id
      assert {:ok, _} = Ecto.UUID.cast(first.snapshot_id)
    end

    # REGRESSION LOCK on the recorded evidence, PRESERVATION on the verdict.
    # Base also reached `:require_confirmation` here — but only because its
    # fabricated snapshot happened to omit the weekly window; its five-hour
    # reading was consumed as genuine high-confidence evidence and written
    # into the durable decision as such. The verdict assertion is the
    # required-thing-still-present direction (a fabricated zero-usage weekly
    # would have destroyed it by reading as abundant headroom); the
    # observation assertions are the lock, because the decision payload is
    # what every later reader — operator surface, renewal, audit — explains
    # the outcome from.
    test "admission requires confirmation and records the absence of evidence as such" do
      assert {:ok, snapshot} = CodexAppServer.probe(%{})

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(
                 admission_request(),
                 admission_candidate(),
                 snapshot,
                 AdmissionPolicy.default(),
                 # The probe stamps its own `observed_at`; evaluating at a
                 # fixed literal instead would refuse as `future_observation`
                 # and never reach the gate under test.
                 now: snapshot.observed_at
               )

      assert decision.result == :require_confirmation

      observation = AdmissionDecision.to_payload(decision)["observation"]
      assert observation["capacity_state"] == "unknown"
      assert observation["confidence"] == "none"
      assert observation["snapshot_id"] == snapshot.snapshot_id
    end
  end

  describe "with a capacity monitor running" do
    # REGRESSION LOCK. On base a monitor that answered with anything other
    # than a snapshot — including the ordinary "running, but nothing read
    # yet" case — fell through to the same fabricated 25% observation.
    test "a monitor that has no observation yet yields unknown carrying the error reason" do
      start_monitor!(auto_respond: fn _frame -> nil end, emit_connected: false)

      assert {:ok, %CapacitySnapshot{} = snapshot} = CodexAppServer.probe(%{})

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none
      assert snapshot.windows == []
      assert snapshot.reason == "monitor_error:no_observation"
    end

    # PRESERVATION (passes on base). The other direction: a real supported
    # reading must reach the caller byte-for-byte, not be replaced by an
    # unknown. Without this the change above could "fix" honesty by making
    # the adapter blind.
    test "a genuine monitor observation passes through untouched", %{normal_read: normal_read} do
      monitor = start_monitor!(auto_respond: auto_respond(normal_read), emit_connected: false)

      assert %CapacitySnapshot{} = observed = await_observation!(monitor)
      assert observed.capacity_state == :observed
      assert observed.confidence == :high

      assert {:ok, probed} = CodexAppServer.probe(%{})
      assert probed == observed
    end
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  # Registered under the default name so `CodexAppServer.do_probe/1` finds
  # it exactly as it would in production. The sink never touches the
  # database: this suite is about the adapter, not about ingestion.
  defp start_monitor!(transport_opts) do
    {:ok, transport} =
      start_supervised({FakeTransport, Keyword.put(transport_opts, :owner, self())})

    test_pid = self()

    monitor =
      start_supervised!(
        {CodexMonitor,
         version: "0.150.1",
         transport_pid: transport,
         sink: fn snapshot ->
           send(test_pid, {:ingested, snapshot})
           {:ok, :persisted, snapshot}
         end,
         clock: fn -> @monitor_clock end,
         base_backoff_ms: 50,
         max_backoff_ms: 100}
      )

    # Drive the handshake to completion before the probe reads state.
    Enum.each(1..5, fn _ ->
      if Process.alive?(transport), do: _ = :sys.get_state(transport)
      if Process.alive?(monitor), do: _ = :sys.get_state(monitor)
    end)

    monitor
  end

  defp await_observation!(monitor) do
    assert_receive {:ingested, %CapacitySnapshot{}}, 2_000
    _ = :sys.get_state(monitor)
    {:ok, snapshot} = CodexMonitor.observe(monitor, %{})
    snapshot
  end

  defp auto_respond(normal_read) do
    fn
      %{"method" => "initialize", "id" => id} ->
        %{
          "id" => id,
          "result" => %{"platformFamily" => "unix", "platformOs" => "macos"}
        }

      %{"method" => "account/read", "id" => id} ->
        %{
          "id" => id,
          "result" => %{
            "account" => %{"type" => "chatgpt", "planType" => "plus"},
            "requiresOpenaiAuth" => true
          }
        }

      %{"method" => "account/rateLimits/read", "id" => id} ->
        %{"id" => id, "result" => normal_read}

      _other ->
        nil
    end
  end

  defp admission_request do
    %{
      requested_capability: "supervised_execution",
      scope: "account",
      goal_id: Ecto.UUID.generate(),
      task_id: Ecto.UUID.generate()
    }
  end

  defp admission_candidate do
    %{
      provider_id: "codex",
      adapter_id: "codex_app_server_stdio",
      support_tier: :proactive,
      compatibility_state: :compatible,
      scope: "account",
      capabilities: ["supervised_execution"]
    }
  end
end
