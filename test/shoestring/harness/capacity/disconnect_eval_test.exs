defmodule Shoestring.Harness.Capacity.DisconnectEvalTest do
  @moduledoc """
  Required runtime eval: Disconnect.

  Kills one provider monitor process for real (`Process.exit/2`) and proves
  the OTHER provider and the observatory UI remain healthy: the surviving
  monitor keeps serving its last observation, the supervisor restarts the
  dead monitor with honest unknown state, and the LiveView still renders the
  surviving provider's ledger state.
  """
  use ShoestringWeb.ConnCase, async: false

  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Harness.Capacity.ClaudeMonitor
  alias Shoestring.Harness.Capacity.Fixtures
  alias Shoestring.Harness.Capacity.Supervisor, as: CapacitySupervisor
  alias Shoestring.Harness.Observatory

  @codex_time ~U[2026-08-29 04:38:25Z]

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

  defp child_pid(sup, id) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn {child_id, pid, _, _} -> if child_id == id, do: pid end)
  end

  defp wait_for(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case fun.() do
        nil ->
          Process.sleep(20)
          {:cont, nil}

        value ->
          {:halt, value}
      end
    end)
  end

  test "killing the Claude monitor leaves Codex and the observatory UI healthy", %{conn: conn} do
    test_pid = self()
    normal_read = Fixtures.load_fixture!("codex/normal-read.json")["payload"]["result"]

    # Tee every ingested snapshot into the durable ledger AND the test mailbox.
    codex_sink = fn snapshot ->
      result = Observatory.ingest(snapshot)
      send(test_pid, {:codex_ingested, snapshot})

      case result do
        {:ok, status, persisted} -> {:ok, status, persisted}
        {:error, reason} -> {:error, reason}
      end
    end

    claude_sink = fn snapshot, opts ->
      result = Observatory.ingest(snapshot, opts)
      send(test_pid, {:claude_ingested, snapshot})

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

    sup =
      start_supervised!(
        {CapacitySupervisor,
         [
           name: :cap_sup_disconnect,
           claude: [name: :claude_disconnect, version: "2.1.251", sink: claude_sink],
           codex: [
             name: :codex_disconnect,
             version: "0.150.1",
             transport_pid: fake,
             sink: codex_sink,
             clock: fn -> @codex_time end,
             base_backoff_ms: 50,
             max_backoff_ms: 100
           ]
         ]}
      )

    claude_pid = child_pid(sup, :claude_monitor)
    codex_pid = child_pid(sup, :codex_monitor)
    assert is_pid(claude_pid) and is_pid(codex_pid)

    # Both providers produce observations: Codex via handshake, Claude via callback.
    assert_receive {:codex_ingested, %_{capacity_state: :observed}}, 5_000

    claude_payload = %{
      "captured_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "rate_limits" => %{
        "five_hour" => %{"used_percentage" => 25, "resets_at" => 1_787_994_000},
        "seven_day" => %{"used_percentage" => 94, "resets_at" => 1_788_033_600}
      }
    }

    assert {:ok, :persisted, _} = ClaudeMonitor.receive_status_line(claude_pid, claude_payload)
    assert_receive {:claude_ingested, _}, 5_000

    _ = :sys.get_state(codex_pid)
    assert CodexMonitor.status(codex_pid) == :connected
    assert %_{source: %{provider_id: "codex"}} = CodexMonitor.last_observation(codex_pid)

    # Kill the Claude monitor process FOR REAL — not a graceful disconnect call.
    ref = Process.monitor(claude_pid)
    Process.exit(claude_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^claude_pid, :killed}

    # The OTHER provider is untouched: same pid, still connected, same observation.
    assert child_pid(sup, :codex_monitor) == codex_pid
    assert Process.alive?(codex_pid)
    assert CodexMonitor.status(codex_pid) == :connected

    assert %_{source: %{provider_id: "codex"}, windows: windows} =
             CodexMonitor.last_observation(codex_pid)

    assert Enum.map(windows, & &1.used_percent) == [13, 16]

    # The supervisor restarts the dead monitor with honest unknown state.
    restarted =
      wait_for(fn ->
        pid = child_pid(sup, :claude_monitor)
        if is_pid(pid) and pid != claude_pid and Process.alive?(pid), do: pid, else: nil
      end)

    assert is_pid(restarted)
    _ = :sys.get_state(restarted)
    assert {:ok, %_{capacity_state: :unknown}} = ClaudeMonitor.current_snapshot(restarted)

    # The UI stays healthy: it renders the surviving provider's ledger state.
    {:ok, view, html} = live(conn, "/observatory")
    assert html =~ "Capacity Observatory"
    assert html =~ "codex"
    assert has_element?(view, "#observations-list")
    refute has_element?(view, "#observations-empty")
  end

  test "killing the Codex monitor leaves Claude serving and the UI honest", %{conn: conn} do
    test_pid = self()
    normal_read = Fixtures.load_fixture!("codex/normal-read.json")["payload"]["result"]

    codex_sink = fn snapshot ->
      send(test_pid, {:codex_ingested, snapshot})
      {:ok, :persisted, snapshot}
    end

    {:ok, fake} =
      start_supervised(
        {FakeTransport,
         [owner: self(), emit_connected: false, auto_respond: codex_auto_respond(normal_read)]}
      )

    sup =
      start_supervised!(
        {CapacitySupervisor,
         [
           name: :cap_sup_disconnect2,
           claude: [
             name: :claude_disconnect2,
             version: "2.1.251",
             sink: fn snapshot, _opts -> {:ok, :persisted, snapshot} end
           ],
           codex: [
             name: :codex_disconnect2,
             version: "0.150.1",
             transport_pid: fake,
             sink: codex_sink,
             clock: fn -> @codex_time end,
             base_backoff_ms: 50,
             max_backoff_ms: 100
           ]
         ]}
      )

    claude_pid = child_pid(sup, :claude_monitor)
    codex_pid = child_pid(sup, :codex_monitor)
    assert is_pid(claude_pid) and is_pid(codex_pid)

    assert_receive {:codex_ingested, _}, 5_000

    claude_payload = %{
      "captured_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "rate_limits" => %{
        "five_hour" => %{"used_percentage" => 11, "resets_at" => 1_787_994_000},
        "seven_day" => %{"used_percentage" => 22, "resets_at" => 1_788_033_600}
      }
    }

    assert {:ok, :persisted, _} = ClaudeMonitor.receive_status_line(claude_pid, claude_payload)

    # Kill the Codex monitor process FOR REAL.
    ref = Process.monitor(codex_pid)
    Process.exit(codex_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^codex_pid, :killed}

    # Claude keeps serving its own observation, undisturbed.
    assert child_pid(sup, :claude_monitor) == claude_pid
    assert {:ok, %_{windows: windows}} = ClaudeMonitor.current_snapshot(claude_pid)
    assert Enum.map(windows, & &1.used_percent) == [11, 22]

    # The supervisor restarts Codex; it reconnects through the surviving transport.
    restarted =
      wait_for(fn ->
        pid = child_pid(sup, :codex_monitor)
        if is_pid(pid) and pid != codex_pid and Process.alive?(pid), do: pid, else: nil
      end)

    assert is_pid(restarted)

    reconnected =
      wait_for(fn ->
        _ = :sys.get_state(restarted)
        if CodexMonitor.status(restarted) == :connected, do: true, else: nil
      end)

    assert reconnected == true

    # The UI still renders (empty ledger here is honest: this eval used a fake sink).
    {:ok, view, _html} = live(conn, "/observatory")
    assert has_element?(view, "#observations-empty")
  end
end
