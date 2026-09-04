defmodule Shoestring.Harness.Capacity.RestartEvalTest do
  @moduledoc """
  Required runtime eval: Restart.

  Persists an observation, reboots the monitor, and proves the last
  observation returns with its REAL age — not a refreshed-at-boot timestamp.
  The age is asserted genuinely old (hours), so any bug that re-stamps
  `observed_at` at boot (fresh age ~0) fails this test.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Harness.Capacity.Fixtures
  alias Shoestring.Harness.Observatory

  # Deliberately old: at eval time the persisted observation is hours stale,
  # which is exactly what must survive the reboot honestly.
  @old_time ~U[2026-08-29 04:38:25Z]

  defp codex_auto_respond(normal_read) do
    fn
      %{"method" => "initialize", "id" => id} ->
        %{"id" => id, "result" => %{"platformFamily" => "unix"}}

      %{"method" => "account/read", "id" => id} ->
        %{
          "id" => id,
          "result" => %{"account" => %{"type" => "chatgpt", "planType" => "plus"}}
        }

      %{"method" => "account/rateLimits/read", "id" => id} ->
        %{"id" => id, "result" => normal_read}

      _ ->
        nil
    end
  end

  defp start_monitor(transport, sink, id) do
    start_supervised!(%{
      id: id,
      start:
        {CodexMonitor, :start_link,
         [
           [
             name: false,
             version: "0.150.1",
             transport_pid: transport,
             sink: sink,
             clock: fn -> @old_time end,
             base_backoff_ms: 50,
             max_backoff_ms: 100
           ]
         ]}
    })
  end

  test "persisted observation survives monitor reboot with its real age" do
    test_pid = self()
    normal_read = Fixtures.load_fixture!("codex/normal-read.json")["payload"]["result"]

    # The monitor ingests through the REAL durable ledger.
    sink = fn snapshot ->
      result = Observatory.ingest(snapshot)
      send(test_pid, {:ledger_ingested, snapshot})

      case result do
        {:ok, status, persisted} -> {:ok, status, persisted}
        {:error, reason} -> {:error, reason}
      end
    end

    {:ok, fake} =
      start_supervised(
        {FakeTransport,
         [owner: self(), emit_connected: false, auto_respond: codex_auto_respond(normal_read)]}
      )

    monitor = start_monitor(fake, sink, :codex_restart_before)
    assert_receive {:ledger_ingested, %_{snapshot_id: snapshot_id}}, 5_000

    _ = :sys.get_state(monitor)
    assert CodexMonitor.status(monitor) == :connected

    # The ledger holds the observation stamped at the genuinely old time.
    # (DateTime precision changes across the DB round-trip, so instants are
    # compared with DateTime.compare/2, not structural equality.)
    assert %_{snapshot_id: ^snapshot_id} =
             first =
             Observatory.get_latest_observation("codex", "app_server_stdio", "subscription")

    assert DateTime.compare(first.observed_at, @old_time) == :eq

    # Reboot the monitor: kill the process for real, then boot a replacement
    # with no memory of the previous incarnation.
    ref = Process.monitor(monitor)
    Process.exit(monitor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^monitor, :killed}

    rebooted = start_monitor(fake, sink, :codex_restart_after)
    _ = :sys.get_state(rebooted)
    _ = :sys.get_state(fake)

    # The rebooted monitor fabricates nothing: honest empty memory.
    assert CodexMonitor.last_observation(rebooted) == nil

    # The ledger still returns the ORIGINAL observation with its REAL age.
    # A bug that re-stamped observed_at at boot would surface here as a fresh
    # snapshot (different id, age ~0) and fail the assertions below.
    reloaded = Observatory.get_latest_observation("codex", "app_server_stdio", "subscription")
    assert %_{snapshot_id: ^snapshot_id} = reloaded
    assert DateTime.compare(reloaded.observed_at, @old_time) == :eq

    summary = Observatory.observation_summary(reloaded, now: DateTime.utc_now())

    # Genuinely old: hours, not seconds. (@old_time is days before "now".)
    assert summary.age_seconds > 3_600
    assert DateTime.compare(summary.observed_at, @old_time) == :eq
    assert summary.freshness_state == :stale
  end
end
