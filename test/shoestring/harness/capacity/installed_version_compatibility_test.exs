defmodule Shoestring.Harness.Capacity.InstalledVersionCompatibilityTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.AdmissionEvaluation
  alias Shoestring.Harness.{Capacity, CapacitySnapshot, Security}
  alias Shoestring.Harness.Capacity.{CodexMonitor, Fixtures}
  alias Shoestring.Harness.Capacity.Codex.FakeTransport

  setup do
    fixture = Fixtures.load_fixture!("codex/normal-read-0.163.0-live.json")
    {:ok, now, _} = DateTime.from_iso8601(fixture["captured_at"])
    %{fixture: fixture, now: now}
  end

  test "the captured Codex 0.163.0 read supports fresh automatic admission", c do
    assert {:ok, snapshot} = normalize(c.fixture, c.now)
    assert snapshot.compatibility_state == :compatible
    assert snapshot.capacity_state == :observed
    assert snapshot.confidence == :high
    assert CapacitySnapshot.eligible?(snapshot, c.now)
    assert Enum.map(snapshot.windows, & &1.used_percent) == [54, 67]

    assert Enum.map(snapshot.windows, & &1.reset_at) ==
             Enum.map([1_792_670_198, 1_793_136_167], &DateTime.from_unix!/1)

    assert {:ok, decision} =
             AdmissionEvaluation.evaluate(%{}, candidate(snapshot), snapshot, nil, now: c.now)

    assert decision.result == :admit
    assert decision.reason_code == "automatic_admission_eligible"
  end

  test "version adoption does not grant authority to stale, partial or unknown-version reads",
       c do
    assert {:ok, stale} = normalize(c.fixture, DateTime.add(c.now, 301, :second))
    refute CapacitySnapshot.eligible?(stale, DateTime.add(c.now, 301, :second))

    assert {:ok, stale_decision} =
             AdmissionEvaluation.evaluate(%{}, candidate(stale), stale, nil,
               now: DateTime.add(c.now, 301, :second)
             )

    refute stale_decision.result == :admit

    partial =
      update_in(c.fixture, ["payload", "result", "rateLimits"], &Map.delete(&1, "secondary"))

    assert {:ok, snapshot} = normalize(partial, c.now)
    refute CapacitySnapshot.eligible?(snapshot, c.now)

    assert Enum.any?(
             snapshot.windows,
             &(&1.state == :unknown and is_nil(Map.get(&1, :used_percent)))
           )

    assert {:ok, drift} =
             Capacity.normalize(:codex, :app_server_stdio, c.fixture,
               version: "0.164.0",
               now: c.now
             )

    assert drift.compatibility_state == :degraded
    refute CapacitySnapshot.eligible?(drift, c.now)
  end

  test "hard refusal still defers and captured evidence excludes private fields", c do
    refused = put_in(c.fixture, ["payload", "result", "rateLimits", "spendControlReached"], true)

    for version <- ["0.150.1", "0.163.0"] do
      assert {:ok, snapshot} =
               Capacity.normalize(:codex, :app_server_stdio, refused,
                 version: version,
                 now: c.now
               )

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(%{}, candidate(snapshot), snapshot, nil, now: c.now)

      assert decision.result == :defer_until
      assert decision.reason_code =~ "hard_quota_refusal"
      assert snapshot.capacity_state == :refused
    end

    assert Security.scan_term(c.fixture) == []
    assert c.fixture["payload"]["result"]["rateLimits"]["primary"]["usedPercent"] == 54

    refute Enum.any?(
             ~w(account_id session_id thread_id turn_id email prompt transcript),
             &String.contains?(Jason.encode!(c.fixture), &1)
           )
  end

  test "explicitly unavailable spend-control state never inherits a prior clear reading", c do
    previous = c.fixture["payload"]["result"]
    update = %{"rateLimits" => %{"spendControlReached" => nil}}
    merged = CodexMonitor.merge_provider_state(previous, update)
    assert get_in(merged, ["result", "rateLimits", "spendControlReached"]) == nil
    assert get_in(merged, ["result", "rateLimits", "primary", "usedPercent"]) == 54
    fixture = %{c.fixture | "payload" => merged}
    assert {:ok, snapshot} = normalize(fixture, c.now)
    refute CapacitySnapshot.eligible?(snapshot, c.now)
  end

  test "new-protocol missing or malformed spend-control state cannot auto-admit", c do
    for value <- [nil, "false", :absent] do
      fixture =
        if value == :absent,
          do:
            update_in(
              c.fixture,
              ["payload", "result", "rateLimits"],
              &Map.delete(&1, "spendControlReached")
            ),
          else:
            put_in(c.fixture, ["payload", "result", "rateLimits", "spendControlReached"], value)

      assert {:ok, snapshot} = normalize(fixture, c.now)
      refute CapacitySnapshot.eligible?(snapshot, c.now)
      assert snapshot.reason =~ "spend_control_state_unknown"
    end
  end

  test "a previous spend-control block needs an explicit false before recovery", c do
    previous = put_in(c.fixture["payload"]["result"], ["rateLimits", "spendControlReached"], true)

    unavailable =
      CodexMonitor.merge_provider_state(previous, %{
        "rateLimits" => %{"spendControlReached" => nil}
      })

    assert get_in(unavailable, ["result", "rateLimits", "spendControlReached"]) == true
    assert {:ok, blocked} = normalize(%{c.fixture | "payload" => unavailable}, c.now)
    assert blocked.capacity_state == :refused

    cleared =
      CodexMonitor.merge_provider_state(unavailable, %{
        "rateLimits" => %{"spendControlReached" => false}
      })

    assert {:ok, clear} = normalize(%{c.fixture | "payload" => cleared}, c.now)
    assert CapacitySnapshot.eligible?(clear, c.now)
  end

  test "the production monitor handles this version and its spend-state updates without model turns",
       c do
    owner = self()

    respond = fn
      %{"method" => "initialize", "id" => id} ->
        %{"id" => id, "result" => %{}}

      %{"method" => "account/read", "id" => id} ->
        %{
          "id" => id,
          "result" => %{"account" => %{"type" => "chatgpt"}, "requiresOpenaiAuth" => true}
        }

      %{"method" => "account/rateLimits/read", "id" => id} ->
        %{"id" => id, "result" => c.fixture["payload"]["result"]}

      _ ->
        nil
    end

    transport =
      start_supervised!(
        {FakeTransport, owner: self(), emit_connected: false, auto_respond: respond}
      )

    monitor =
      start_supervised!(
        {CodexMonitor,
         name: false,
         version: "0.163.0",
         transport_pid: transport,
         clock: fn -> c.now end,
         sink: fn snapshot ->
           send(owner, {:versioned_capacity, snapshot})
           {:ok, :persisted, snapshot}
         end}
      )

    assert_receive {:versioned_capacity, %{capacity_state: :observed} = fresh}, 1000
    assert CapacitySnapshot.eligible?(fresh, c.now)
    assert CodexMonitor.status(monitor) == :connected

    FakeTransport.push_notification(transport, "account/rateLimits/updated", %{
      "rateLimits" => %{"spendControlReached" => nil}
    })

    assert_receive {:versioned_capacity, %{capacity_state: :degraded} = unknown}, 1000
    refute CapacitySnapshot.eligible?(unknown, c.now)
    assert Enum.map(unknown.windows, & &1.used_percent) == [54, 67]

    FakeTransport.push_notification(transport, "account/rateLimits/updated", %{
      "rateLimits" => %{"spendControlReached" => true}
    })

    assert_receive {:versioned_capacity, %{capacity_state: :refused}}, 1000

    FakeTransport.push_notification(transport, "account/rateLimits/updated", %{
      "rateLimits" => %{"spendControlReached" => false}
    })

    assert_receive {:versioned_capacity, %{capacity_state: :observed} = clear}, 1000
    assert CapacitySnapshot.eligible?(clear, c.now)

    assert Enum.all?(
             FakeTransport.get_sent_frames(transport),
             &(&1["method"] in [
                 "initialize",
                 "initialized",
                 "account/read",
                 "account/rateLimits/read"
               ])
           )
  end

  defp normalize(fixture, now),
    do: Capacity.normalize(:codex, :app_server_stdio, fixture, version: "0.163.0", now: now)

  defp candidate(snapshot) do
    %{
      provider_id: "codex",
      adapter_id: snapshot.source.adapter_id,
      scope: snapshot.scope,
      support_tier: snapshot.support_tier,
      compatibility_state: snapshot.compatibility_state,
      capabilities: ["supervised_execution"]
    }
  end
end
