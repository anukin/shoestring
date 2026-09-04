defmodule Shoestring.Harness.Capacity.ConcurrentUpdateEvalTest do
  @moduledoc """
  Required runtime eval: Concurrent update.

  Interleaves observations from BOTH capacity sources concurrently and proves
  correct PER-PROVIDER ordering is preserved with no cross-provider
  interleaving corruption: each monitor's final state reflects exactly its own
  latest input, sparse Codex merges keep unmentioned windows, and stale
  per-provider input cannot regress newer state.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Harness.Capacity.ClaudeMonitor
  alias Shoestring.Harness.Capacity.Fixtures

  @t1 ~U[2026-08-29 07:34:19Z]
  @t2 ~U[2026-08-29 07:34:20Z]
  @stale_t0 ~U[2026-08-29 07:34:10Z]

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

  defp claude_payload(five_hour, seven_day, at) do
    %{
      "captured_at" => DateTime.to_iso8601(at),
      "rate_limits" => %{
        "five_hour" => %{"used_percentage" => five_hour, "resets_at" => 1_787_994_000},
        "seven_day" => %{"used_percentage" => seven_day, "resets_at" => 1_788_033_600}
      }
    }
  end

  defp codex_sparse_params(primary_used) do
    # Deliberately sparse: secondary is omitted and must survive via merge.
    %{
      "rateLimits" => %{
        "primary" => %{
          "usedPercent" => primary_used,
          "windowDurationMins" => 300,
          "resetsAt" => 1_787_994_541
        }
      }
    }
  end

  test "interleaved observations from both sources preserve per-provider ordering" do
    test_pid = self()
    normal_read = Fixtures.load_fixture!("codex/normal-read.json")["payload"]["result"]

    claude_sink = fn snapshot, _opts ->
      send(test_pid, {:claude_ingested, snapshot})
      {:ok, :persisted, snapshot}
    end

    codex_sink = fn snapshot ->
      send(test_pid, {:codex_ingested, snapshot})
      {:ok, :persisted, snapshot}
    end

    claude =
      start_supervised!(
        {ClaudeMonitor, [name: nil, version: "2.1.251", clock: fn -> @t2 end, sink: claude_sink]}
      )

    {:ok, fake} =
      start_supervised(
        {FakeTransport,
         [owner: self(), emit_connected: false, auto_respond: codex_auto_respond(normal_read)]}
      )

    codex =
      start_supervised!(
        {CodexMonitor,
         [
           name: false,
           version: "0.150.1",
           transport_pid: fake,
           sink: codex_sink,
           clock: fn -> @t2 end
         ]}
      )

    # Codex handshake completes first (primary 13 / secondary 16).
    assert_receive {:codex_ingested, %_{capacity_state: :observed}}, 5_000
    _ = :sys.get_state(codex)
    assert CodexMonitor.status(codex) == :connected

    # Round 1: Claude A1 and Codex B1 race each other concurrently.
    round1 = [
      Task.async(fn ->
        ClaudeMonitor.receive_status_line(claude, claude_payload(20, 60, @t1), captured_at: @t1)
      end),
      Task.async(fn ->
        FakeTransport.push_notification(
          fake,
          "account/rateLimits/updated",
          codex_sparse_params(30)
        )
      end)
    ]

    assert [{:ok, :persisted, _}, :ok] = Task.await_many(round1, 5_000)
    _ = :sys.get_state(claude)
    _ = :sys.get_state(codex)
    assert_receive {:claude_ingested, _}, 5_000
    assert_receive {:codex_ingested, _}, 5_000

    # Round 2: Claude A2 and Codex B2 race each other concurrently.
    round2 = [
      Task.async(fn ->
        ClaudeMonitor.receive_status_line(claude, claude_payload(40, 70, @t2), captured_at: @t2)
      end),
      Task.async(fn ->
        FakeTransport.push_notification(
          fake,
          "account/rateLimits/updated",
          codex_sparse_params(50)
        )
      end)
    ]

    assert [{:ok, :persisted, _}, :ok] = Task.await_many(round2, 5_000)
    _ = :sys.get_state(claude)
    _ = :sys.get_state(codex)
    assert_receive {:claude_ingested, _}, 5_000
    assert_receive {:codex_ingested, _}, 5_000

    # PER-PROVIDER ordering: Claude holds exactly its latest input...
    assert {:ok, %_{source: %{provider_id: "claude"}, windows: claude_windows}} =
             ClaudeMonitor.current_snapshot(claude)

    assert Enum.map(claude_windows, & &1.used_percent) == [40, 70]

    # ...and Codex holds exactly its latest input, with the omitted secondary
    # window preserved by sparse merge (not erased, not borrowed from Claude).
    assert %_{source: %{provider_id: "codex"}, windows: codex_windows} =
             CodexMonitor.last_observation(codex)

    assert Enum.find(codex_windows, &(&1.kind == "primary")).used_percent == 50
    assert Enum.find(codex_windows, &(&1.kind == "secondary")).used_percent == 16

    # No cross-provider interleaving corruption: window kinds never cross over.
    assert Enum.map(claude_windows, & &1.kind) == ["five_hour", "seven_day"]
    assert Enum.map(codex_windows, & &1.kind) |> Enum.sort() == ["primary", "secondary"]

    # Per-provider ordering enforcement: a stale Claude callback arriving late
    # cannot regress the newer observation.
    assert {:ok, :out_of_order, preserved} =
             ClaudeMonitor.receive_status_line(claude, claude_payload(10, 50, @stale_t0),
               captured_at: @stale_t0
             )

    assert Enum.map(preserved.windows, & &1.used_percent) == [40, 70]

    assert {:ok, %_{windows: still}} = ClaudeMonitor.current_snapshot(claude)
    assert Enum.map(still, & &1.used_percent) == [40, 70]

    # Claude traffic never disturbed Codex state either.
    assert %_{windows: undisturbed} = CodexMonitor.last_observation(codex)
    assert Enum.find(undisturbed, &(&1.kind == "primary")).used_percent == 50
  end
end
