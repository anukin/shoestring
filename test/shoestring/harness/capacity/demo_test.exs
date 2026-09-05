defmodule Shoestring.Harness.Capacity.DemoTest do
  @moduledoc """
  Milestone-03 five-step capacity observatory demo as a single unified automated flow.

  This is the milestone-03 equivalent of `Shoestring.Harness.Fake.DemoTest`
  (milestone 02): ONE coherent end-to-end test that walks the mandated `## Demo`
  steps in order through a single supervised system, so the demo reads as a
  narrative rather than as scattered unit assertions. Each step's state is the
  *consequence* of the previous step: one supervision tree, one durable ledger,
  one pair of injected clocks, one LiveView.

  1. Boot with neither provider available: honest unknown/unavailable, no crash loop.
  2. Start both supported observers with deterministic offline fixtures: normalized updates.
  3. Replay a partial and an incompatible fixture: PARTIAL plus degraded with reason.
  4. Advance the simulated clock: stale AND ineligible at the configured boundary.
  5. Restart the supervised monitor for real: persisted values keep their REAL age.

  Fully offline and deterministic: explicit versions (no discovery), in-memory
  `FakeTransport`, tracked fixtures, injected clocks. No network, no provider CLI,
  no model inference, no wall-clock sleeps for time travel.
  """
  use ShoestringWeb.ConnCase, async: false

  alias Shoestring.Harness.Capacity
  alias Shoestring.Harness.Capacity.ClaudeMonitor
  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Harness.Capacity.Fixtures
  alias Shoestring.Harness.Capacity.Supervisor, as: CapacitySupervisor
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Harness.Observatory

  # Genuinely old fixture-epoch times: at test time every persisted observation is
  # already hours/days old by wall clock, which is exactly what step 5 must preserve.
  @codex_t0 ~U[2026-08-29 04:38:25Z]
  @claude_t0 ~U[2026-08-29 07:34:25Z]

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

        false ->
          Process.sleep(20)
          {:cont, nil}

        value ->
          {:halt, value}
      end
    end)
  end

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

  test "unified 5-step capacity observatory demo: unknown boot, normalize, replay, staleness, restart",
       %{conn: conn} do
    # Every fixture replayed below must already be secret-free.
    assert {:ok, count} = Fixtures.scan_all_fixtures()
    assert count > 0

    # -------------------------------------------------------------------------
    # Step 1: neither provider available — honest unknown/unavailable, healthy boot.
    # -------------------------------------------------------------------------
    # The real capacity supervision path boots with broken provider CLIs. This must
    # be healthy boot with honest unknown state, never a crash loop or fabricated
    # liveness.
    failing_claude_runner = fn _cmd, _args, _opts -> raise "claude not installed" end
    failing_codex_runner = fn _cmd, _args -> {"not found", 127} end

    down_sup =
      start_supervised!(%{
        id: :cap_demo_down_wrapper,
        start:
          {CapacitySupervisor, :start_link,
           [
             [
               name: :cap_demo_down,
               claude: [
                 name: :claude_demo_down,
                 runner: failing_claude_runner,
                 clock: fn -> @claude_t0 end,
                 sink: fn snapshot, _opts -> {:ok, :persisted, snapshot} end
               ],
               codex: [
                 name: :codex_demo_down,
                 runner: failing_codex_runner,
                 sink: fn snapshot -> {:ok, :persisted, snapshot} end,
                 clock: fn -> @codex_t0 end,
                 auto_connect: false
               ]
             ]
           ]}
      })

    down_claude = child_pid(down_sup, :claude_monitor)
    down_codex = child_pid(down_sup, :codex_monitor)
    assert is_pid(down_claude) and is_pid(down_codex)

    # Let async version discovery settle, then verify honest states.
    _ = :sys.get_state(down_claude)
    _ = :sys.get_state(down_codex)

    # Claude has no observation at all: unknown, never available.
    assert {:ok, down_snapshot} = ClaudeMonitor.current_snapshot(down_claude)
    assert down_snapshot.capacity_state == :unknown
    assert down_snapshot.confidence == :none
    refute CapacitySnapshot.eligible?(down_snapshot, @claude_t0)

    # Codex cannot even start: incompatible and not connected.
    assert CodexMonitor.status(down_codex) == :incompatible
    assert CodexMonitor.get_status(down_codex).connected? == false

    # No crash loop: both children keep stable pids across supervisor syncs.
    _ = :sys.get_state(down_sup)
    assert child_pid(down_sup, :claude_monitor) == down_claude
    assert child_pid(down_sup, :codex_monitor) == down_codex

    # The UI renders honest per-provider placeholder cards: one card each for
    # the configured-but-never-observed `claude` and `codex` providers, with no
    # fabricated liveness. The test env disables both monitors in app config,
    # so this step enables them (modelling "installed but unreachable") and
    # restores the stock config right after: later steps carry real ledger rows
    # and must render those instead of placeholders.
    previous_monitors = Application.get_env(:shoestring, :capacity_monitors)

    on_exit(fn ->
      if previous_monitors == nil do
        Application.delete_env(:shoestring, :capacity_monitors)
      else
        Application.put_env(:shoestring, :capacity_monitors, previous_monitors)
      end
    end)

    Application.put_env(:shoestring, :capacity_monitors,
      claude: [enabled: true],
      codex: [enabled: true]
    )

    {:ok, down_view, down_html} = live(conn, "/observatory")
    assert down_html =~ "Capacity Observatory"
    # Placeholders ARE the content here: the genuine empty state is reserved
    # for zero-providers-configured.
    refute has_element?(down_view, "#observations-empty")

    for provider <- ["claude", "codex"] do
      card = "#obs-#{provider}-placeholder"

      assert has_element?(down_view, card),
             "expected a placeholder card for configured-but-unobserved #{provider}"

      assert down_view
             |> element("#{card} [data-placeholder-badge]")
             |> has_element?()

      assert has_element?(down_view, card, "Not yet observed")
      assert has_element?(down_view, card, "placeholder, not a real observation")
      assert has_element?(down_view, card, "Unknown state")
      assert has_element?(down_view, card, "No windows recorded.")
      assert has_element?(down_view, card, "CLI version: not reported")

      assert down_view
             |> element("#{card} [data-status=\"unknown\"]")
             |> has_element?()

      # No invented timestamp: placeholders render the Unknown fallback, never
      # a <time> element.
      refute down_view
             |> element("#{card} time")
             |> has_element?()

      # F3: per-card ineligibility. Scoped to each card, so an empty page can
      # never satisfy it vacuously — a placeholder rendered as eligible fails.
      refute has_element?(down_view, card, "Eligible for automatic admission")

      refute down_view
             |> element("#{card} [data-status=\"healthy\"]")
             |> has_element?()
    end

    # Restore the stock test config before the next step: later steps carry
    # real ledger rows and must render those instead of placeholders.
    if previous_monitors == nil do
      Application.delete_env(:shoestring, :capacity_monitors)
    else
      Application.put_env(:shoestring, :capacity_monitors, previous_monitors)
    end

    # Providers stay down for the rest of the demo (that supervisor keeps running
    # untouched); the demo moves on by starting the real observers under a second
    # supervisor, keeping the same durable ledger so later steps build on this
    # step's state.

    # -------------------------------------------------------------------------
    # Step 2: start each supported observer — normalized updates reach the UI.
    # -------------------------------------------------------------------------
    test_pid = self()

    codex_sink = fn snapshot ->
      result = Observatory.ingest(snapshot)
      send(test_pid, {:demo_codex_ingested, snapshot})

      case result do
        {:ok, status, persisted} -> {:ok, status, persisted}
        {:error, reason} -> {:error, reason}
      end
    end

    claude_sink = fn snapshot, opts ->
      result = Observatory.ingest(snapshot, opts)
      send(test_pid, {:demo_claude_ingested, snapshot})

      case result do
        {:ok, status, persisted} -> {:ok, status, persisted}
        {:error, reason} -> {:error, reason}
      end
    end

    # Injected clocks: step 4 advances these to time-travel without any sleeping.
    codex_clock =
      start_supervised!(%{
        id: :demo_codex_clock,
        start: {Agent, :start_link, [fn -> @codex_t0 end]}
      })

    claude_clock =
      start_supervised!(%{
        id: :demo_claude_clock,
        start: {Agent, :start_link, [fn -> @claude_t0 end]}
      })

    normal_read = Fixtures.load_fixture!("codex/normal-read.json")["payload"]["result"]

    {:ok, fake} =
      start_supervised(
        {FakeTransport,
         [owner: self(), emit_connected: false, auto_respond: codex_auto_respond(normal_read)]}
      )

    sup =
      start_supervised!(%{
        id: :cap_demo_sup_wrapper,
        start:
          {CapacitySupervisor, :start_link,
           [
             [
               name: :cap_demo_sup,
               claude: [
                 name: :claude_demo,
                 version: "2.1.251",
                 clock: fn -> Agent.get(claude_clock, & &1) end,
                 sink: claude_sink
               ],
               codex: [
                 name: :codex_demo,
                 version: "0.150.1",
                 transport_pid: fake,
                 sink: codex_sink,
                 clock: fn -> Agent.get(codex_clock, & &1) end,
                 base_backoff_ms: 50,
                 max_backoff_ms: 100
               ]
             ]
           ]}
      })

    claude_pid = child_pid(sup, :claude_monitor)
    codex_pid = child_pid(sup, :codex_monitor)
    assert is_pid(claude_pid) and is_pid(codex_pid)

    # Codex normalizes through the deterministic handshake: 13% / 16%, observed,
    # proactive, compatible, high confidence, stamped at the injected clock.
    assert_receive {:demo_codex_ingested, codex_snap}, 5_000
    assert codex_snap.capacity_state == :observed
    assert codex_snap.support_tier == :proactive
    assert codex_snap.compatibility_state == :compatible
    assert codex_snap.confidence == :high
    assert codex_snap.source.provider_id == "codex"
    assert codex_snap.source.invocation_mode == "app_server_stdio"
    assert codex_snap.source.event == :explicit_read
    assert DateTime.compare(codex_snap.observed_at, @codex_t0) == :eq

    [primary, secondary] = codex_snap.windows
    assert primary.kind == "primary"
    assert primary.used_percent == 13
    assert secondary.kind == "secondary"
    assert secondary.used_percent == 16

    # Fresh when observed (simulated time): eligible input to a future policy.
    assert CapacitySnapshot.freshness(codex_snap, @codex_t0) == :fresh
    assert CapacitySnapshot.eligible?(codex_snap, @codex_t0)

    _ = :sys.get_state(codex_pid)
    assert CodexMonitor.status(codex_pid) == :connected

    # Claude normalizes the tracked live fixture: 25% / 94%, degraded
    # conservative-partial, medium confidence. `captured_at` pins the observation
    # to the injected clock so the update is fresh in simulated time.
    claude_fixture = Fixtures.load_fixture!("claude/status-line-single-live.json")

    assert {:ok, :persisted, claude_snap} =
             ClaudeMonitor.receive_status_line(claude_pid, claude_fixture,
               captured_at: @claude_t0
             )

    assert_receive {:demo_claude_ingested, _}, 5_000
    assert claude_snap.capacity_state == :degraded
    assert claude_snap.support_tier == :conservative_partial
    assert claude_snap.compatibility_state == :compatible
    assert claude_snap.confidence == :medium
    assert claude_snap.reason == "conservative_partial_observation"
    assert claude_snap.source.provider_id == "claude"
    assert claude_snap.source.invocation_mode == "interactive_status_line"
    assert claude_snap.source.event == :status_line_input
    assert DateTime.compare(claude_snap.observed_at, @claude_t0) == :eq

    [five_hour, seven_day] = claude_snap.windows
    assert five_hour.kind == "five_hour"
    assert five_hour.used_percent == 25
    assert seven_day.kind == "seven_day"
    assert seven_day.used_percent == 94

    # Fresh in simulated time, but Claude's conservative tier is never eligible
    # for proactive automatic admission.
    assert CapacitySnapshot.freshness(claude_snap, @claude_t0) == :fresh
    refute CapacitySnapshot.eligible?(claude_snap, @claude_t0)

    # Both normalized updates reach the UI as cards.
    {:ok, view, html} = live(conn, "/observatory")
    assert html =~ "Capacity Observatory"
    assert html =~ "codex"
    assert html =~ "claude"
    assert html =~ "13.0%"
    assert html =~ "25.0%"
    assert has_element?(view, "#observations-list")
    refute has_element?(view, "#observations-empty")

    # -------------------------------------------------------------------------
    # Step 3: replay a partial and an incompatible fixture.
    # -------------------------------------------------------------------------
    # Partial Claude replay through the live monitor: the absent seven-day window
    # is unknown, never zero-or-unlimited.
    partial_fixture = Fixtures.load_fixture!("claude/partial-official-shape.json")

    assert {:ok, :persisted, partial_snap} =
             ClaudeMonitor.receive_status_line(claude_pid, partial_fixture,
               captured_at: @claude_t0
             )

    assert_receive {:demo_claude_ingested, _}, 5_000
    assert partial_snap.capacity_state == :degraded
    assert partial_snap.reason == "partial_window_observation"

    [partial_five, partial_seven] = partial_snap.windows
    assert partial_five.kind == "five_hour"
    assert partial_five.state == :observed
    assert partial_five.used_percent == 23.5
    assert partial_seven.kind == "seven_day"
    assert partial_seven.state == :unknown
    refute Map.has_key?(partial_seven, :used_percent)

    # Partial Codex replay straight from the tracked fixture into the ledger.
    codex_partial_fixture = Fixtures.load_fixture!("codex/partial-missing-secondary.json")

    assert {:ok, codex_partial} =
             Capacity.normalize(:codex, :app_server_stdio, codex_partial_fixture,
               version: "0.150.1",
               now: @codex_t0,
               captured_at: @codex_t0
             )

    assert codex_partial.capacity_state == :degraded
    assert codex_partial.confidence == :medium
    [codex_p, codex_s] = codex_partial.windows
    assert codex_p.kind == "primary"
    assert codex_p.used_percent == 12
    assert codex_s.kind == "secondary"
    assert codex_s.state == :unknown
    refute Map.has_key?(codex_s, :used_percent)

    assert {:ok, :persisted, _} = Observatory.ingest(codex_partial)

    # Incompatible replay: the same officially-shaped Claude fixture under a
    # drifted, untested CLI version degrades with a visible reason.
    drift_fixture = Fixtures.load_fixture!("claude/normal-official-shape.json")

    assert {:ok, drifted} =
             Capacity.normalize(:claude, :interactive_status_line, drift_fixture,
               version: "2.2.0",
               now: @claude_t0,
               captured_at: @claude_t0
             )

    assert drifted.compatibility_state == :degraded
    assert drifted.reason =~ "untested_cli_version"

    assert {:ok, :persisted, _} = Observatory.ingest(drifted)

    # Acceptance gate: missing/stale/invalid inputs never imply available capacity.
    refute CapacitySnapshot.eligible?(partial_snap, @claude_t0)
    refute CapacitySnapshot.eligible?(codex_partial, @codex_t0)
    refute CapacitySnapshot.eligible?(drifted, @claude_t0)

    # The UI shows the partial card distinctly (never as zero usage) and the
    # drift reason visibly.
    {:ok, replay_view, replay_html} = live(conn, "/observatory")
    assert has_element?(replay_view, "#observations-list")
    assert replay_html =~ "Partial observation"
    assert replay_html =~ "Unknown / Absent"
    assert replay_html =~ "untested_cli_version"
    assert replay_view |> element("[data-status=\"partial\"]") |> has_element?()
    refute replay_html =~ "0.0%"

    # -------------------------------------------------------------------------
    # Step 4: advance the simulated clock — stale AND ineligible at the boundary.
    # -------------------------------------------------------------------------
    # The configured boundary comes from the snapshot itself, not a hardcoded constant.
    codex_max_age = codex_snap.freshness.max_age_seconds
    assert is_integer(codex_max_age) and codex_max_age > 0
    codex_boundary = DateTime.add(codex_snap.observed_at, codex_max_age, :second)
    codex_late = DateTime.add(codex_boundary, 1, :second)

    # Exactly at the boundary the Codex observation is still fresh and eligible.
    # This is a pure-function boundary check on the step-2 snapshot evaluated
    # at explicit datetimes: unlike the Claude half below, `CodexMonitor`
    # exposes no clock-evaluated read (`last_observation/1` returns the stored
    # snapshot verbatim), so there is no live monitor state advanced here.
    assert CapacitySnapshot.freshness(codex_snap, codex_boundary) == :fresh
    assert CapacitySnapshot.eligible?(codex_snap, codex_boundary)

    # ...one second past it, the SAME struct is stale and ineligible.
    assert CapacitySnapshot.freshness(codex_snap, codex_late) == :stale
    refute CapacitySnapshot.eligible?(codex_snap, codex_late)

    # The live Claude monitor evaluates staleness against its own injected clock:
    # the step-3 partial observation goes stale with a visible reason.
    claude_max_age = partial_snap.freshness.max_age_seconds
    claude_boundary = DateTime.add(partial_snap.observed_at, claude_max_age, :second)
    claude_late = DateTime.add(claude_boundary, 1, :second)

    Agent.update(claude_clock, fn _ -> claude_boundary end)
    assert {:ok, boundary_snap} = ClaudeMonitor.current_snapshot(claude_pid)
    assert CapacitySnapshot.freshness(boundary_snap, claude_boundary) == :fresh

    Agent.update(claude_clock, fn _ -> claude_late end)
    assert {:ok, stale_snap} = ClaudeMonitor.current_snapshot(claude_pid)
    assert stale_snap.capacity_state == :degraded
    assert stale_snap.confidence == :low
    assert stale_snap.reason =~ "stale_observation"
    assert CapacitySnapshot.freshness(stale_snap, claude_late) == :stale
    refute CapacitySnapshot.eligible?(stale_snap, claude_late)

    # Wall-clock UI discrimination probe. The LiveView evaluates freshness
    # against `DateTime.utc_now/0` (see `Observatory.observation_summary/2`
    # default `now` and `CapacityObservatoryLive.load_observations/1`), not
    # the injected Agent clocks above, so fixture-epoch rows are already
    # stale by wall clock before this step begins. To make the UI half of
    # this step genuinely discriminating, persist two observations from the
    # SAME tracked fixture under distinct scopes, differing ONLY in
    # wall-clock age: one genuinely fresh (`observed_at` ~= now), one
    # genuinely stale (`observed_at` < now - max_age). Scoped selectors below
    # then prove the UI distinguishes them. Scopes are probe-specific so the
    # step-5 `subscription`-scope ledger assertions below are untouched.
    wall_now = DateTime.utc_now()
    fresh_scope = "wallclock_fresh_probe"
    stale_scope = "wallclock_stale_probe"
    probe_fixture = Fixtures.load_fixture!("codex/partial-missing-secondary.json")

    assert {:ok, wall_fresh} =
             Capacity.normalize(:codex, :app_server_stdio, probe_fixture,
               version: "0.150.1",
               now: wall_now,
               captured_at: wall_now,
               scope: fresh_scope
             )

    assert {:ok, :persisted, _} = Observatory.ingest(wall_fresh)

    # Negative half: with only the fresh probe persisted, its card renders
    # WITHOUT any stale marker.
    {:ok, fresh_probe_view, _} = live(conn, "/observatory")

    _ =
      fresh_probe_view
      |> element("#observations-refresh")
      |> render_click()

    fresh_card_html =
      fresh_probe_view
      |> element("#obs-codex-app_server_stdio-#{fresh_scope}")
      |> render()

    refute fresh_card_html =~ "Stale observation"

    refute fresh_probe_view
           |> element("#obs-codex-app_server_stdio-#{fresh_scope} [data-stale-badge]")
           |> has_element?()

    # Positive half (the transition): persisting the wall-clock-stale probe
    # flips exactly one new card to stale.
    stale_captured_at =
      DateTime.add(wall_now, -(wall_fresh.freshness.max_age_seconds + 60), :second)

    assert {:ok, wall_stale} =
             Capacity.normalize(:codex, :app_server_stdio, probe_fixture,
               version: "0.150.1",
               now: wall_now,
               captured_at: stale_captured_at,
               scope: stale_scope
             )

    assert CapacitySnapshot.freshness(wall_stale, DateTime.utc_now()) == :stale
    assert {:ok, :persisted, _} = Observatory.ingest(wall_stale)

    # Refresh so the newly persisted stale probe is rendered. The previous
    # unscoped global staleness assertions lived here and were removed: they
    # could not fail, because fixture-epoch rows are already stale by wall
    # clock before step 4 begins. The scoped pair below is the discriminating
    # UI coverage for this step.
    {:ok, stale_view, _} = live(conn, "/observatory")

    _ =
      stale_view |> element("#observations-refresh") |> render_click()

    # Discriminating scoped pair: the fresh probe card still has NO stale
    # marker while the stale probe card DOES. Neutralising the stale-probe
    # ingest above makes the positive assertion fail; a UI that always (or
    # never) renders the badge fails the negative (or positive) half.
    fresh_card_after =
      stale_view
      |> element("#obs-codex-app_server_stdio-#{fresh_scope}")
      |> render()

    refute fresh_card_after =~ "Stale observation"

    refute stale_view
           |> element("#obs-codex-app_server_stdio-#{fresh_scope} [data-stale-badge]")
           |> has_element?()

    stale_card_html =
      stale_view
      |> element("#obs-codex-app_server_stdio-#{stale_scope}")
      |> render()

    assert stale_card_html =~ "Stale observation"

    assert stale_view
           |> element("#obs-codex-app_server_stdio-#{stale_scope} [data-stale-badge]")
           |> has_element?()

    # -------------------------------------------------------------------------
    # Step 5: restart — persisted values keep their REAL age, not boot timestamps.
    # -------------------------------------------------------------------------
    # Record the ledger truth BEFORE the restart: ids plus original timestamps.
    assert %_{snapshot_id: codex_id} =
             codex_before =
             Observatory.get_latest_observation("codex", "app_server_stdio", "subscription")

    assert %_{snapshot_id: claude_id} =
             claude_before =
             Observatory.get_latest_observation(
               "claude",
               "interactive_status_line",
               "subscription"
             )

    codex_observed_at = codex_before.observed_at
    claude_observed_at = claude_before.observed_at
    assert %DateTime{} = codex_observed_at
    assert %DateTime{} = claude_observed_at

    # Restart the supervised Claude monitor FOR REAL: kill the process, let the
    # capacity supervisor restart exactly that child. Only the Claude child is
    # restarted on purpose: a Codex child restart would re-handshake through the
    # fake transport and ingest a NEW observation at the advanced clock, which
    # would displace the step-3 latest row this step must verify untouched.
    ref = Process.monitor(claude_pid)
    Process.exit(claude_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^claude_pid, :killed}

    restarted_claude =
      wait_for(fn ->
        pid = child_pid(sup, :claude_monitor)
        if is_pid(pid) and pid != claude_pid and Process.alive?(pid), do: pid, else: nil
      end)

    assert is_pid(restarted_claude)

    # The rebooted monitor fabricates nothing: honest empty (unknown) memory.
    _ = :sys.get_state(restarted_claude)
    assert {:ok, rebooted_snapshot} = ClaudeMonitor.current_snapshot(restarted_claude)
    assert rebooted_snapshot.capacity_state == :unknown

    # The restart re-stamped nothing and re-ingested nothing.
    refute_received {:demo_claude_ingested, _}
    refute_received {:demo_codex_ingested, _}

    # The ledger still returns the ORIGINAL observations with their REAL age. A
    # bug that re-stamped `observed_at` at boot would surface here as a different
    # timestamp (and a fresh snapshot would carry a different id); both assertions
    # below fail in that case.
    assert %_{snapshot_id: ^codex_id} =
             codex_after =
             Observatory.get_latest_observation("codex", "app_server_stdio", "subscription")

    assert DateTime.compare(codex_after.observed_at, codex_observed_at) == :eq

    assert %_{snapshot_id: ^claude_id} =
             claude_after =
             Observatory.get_latest_observation(
               "claude",
               "interactive_status_line",
               "subscription"
             )

    assert DateTime.compare(claude_after.observed_at, claude_observed_at) == :eq

    # Genuinely old (hours, not seconds) and honestly stale — never refreshed.
    codex_summary = Observatory.observation_summary(codex_after, now: DateTime.utc_now())
    claude_summary = Observatory.observation_summary(claude_after, now: DateTime.utc_now())

    assert codex_summary.age_seconds > 3_600
    assert DateTime.compare(codex_summary.observed_at, codex_observed_at) == :eq
    assert codex_summary.freshness_state == :stale

    assert claude_summary.age_seconds > 3_600
    assert DateTime.compare(claude_summary.observed_at, claude_observed_at) == :eq
    assert claude_summary.freshness_state == :stale

    # The UI still shows the persisted cards with their real observed-at times.
    {:ok, final_view, final_html} = live(conn, "/observatory")
    assert has_element?(final_view, "#observations-list")
    refute has_element?(final_view, "#observations-empty")
    assert final_html =~ DateTime.to_iso8601(codex_observed_at)
    assert final_html =~ DateTime.to_iso8601(claude_observed_at)

    # The restarted Claude card itself carries the stale marker. Scoped to
    # the card, so the other stale rows in the ledger (subscription-scope
    # Codex, wall-clock probes) cannot satisfy it.
    assert final_view
           |> element("#obs-claude-interactive_status_line-subscription [data-stale-badge]")
           |> has_element?()
  end
end
