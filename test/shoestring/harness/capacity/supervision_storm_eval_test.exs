defmodule Shoestring.Harness.Capacity.SupervisionStormEvalTest do
  @moduledoc """
  Required regression eval: restart storm isolation (DEF-01).

  A monitor that crash-loops (killed on every start) exhausts the capacity
  supervisor's restart intensity (`max_restarts: 3 / max_seconds: 60`), which
  terminates it with the bare exit reason `:shutdown` (OTP reports
  `:reached_max_restart_intensity` only in its log report, never in the exit
  term).

  Before the fix the capacity supervisor was a `:permanent` child of the
  application root, so the root re-armed it; the rebooted supervisor died
  again within milliseconds, and four rapid deaths exhausted the root's own
  `3 restarts / 5 seconds` intensity — collapsing the Endpoint, Repo, and
  the healthy provider with it.

  The fix wires the capacity supervisor as `:transient`, so the `:shutdown`
  exit is never restarted (`:transient` is not re-armed on `:normal`,
  `:shutdown`, or `{:shutdown, term}`): the outage stops at capacity
  supervision while the root, its other children, and the healthy provider
  survive indefinitely, and the observatory keeps serving honest
  last-known/stale ledger state.

  Topology under test (a faithful miniature of `Shoestring.Application`):
  a `:one_for_one` test root supervises an endpoint stand-in, a healthy
  Codex monitor (direct child of the root, i.e. the surviving provider
  branch), and the REAL `Capacity.Supervisor` whose restart value is taken
  verbatim from `Capacity.Supervisor.child_spec/1` — the same spec the
  application boots. The victim inside the capacity supervisor is a REAL
  Claude monitor killed for real with `Process.exit(pid, :kill)` on every
  start; no mocks bypass supervisor semantics.

  This test genuinely FAILS on the old `:permanent` wiring: the root keeps
  re-arming the dead capacity supervisor, the storm repeats, and the root
  (plus the healthy monitor, the stand-in, and with them the whole app)
  collapses. On the fixed wiring the capacity child stays down and
  everything else survives.
  """
  use ShoestringWeb.ConnCase, async: false

  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Harness.Capacity.Fixtures
  alias Shoestring.Harness.Capacity.Supervisor, as: CapacitySupervisor
  alias Shoestring.Harness.Observatory

  @claude_time ~U[2026-08-29 07:34:25Z]
  @codex_time ~U[2026-08-29 04:38:25Z]

  # Overall storm budget: four capacity-supervisor deaths must land inside
  # the root's 5-second intensity window on the unfixed wiring.
  @storm_budget_ms 20_000

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

  # Deterministic teardown helper: the tree under `root` can touch the
  # Repo, and awaiting only the root's DOWN is NOT enough. The healthy
  # monitor traps exits, so the root's death arrives as an EXIT message
  # that waits behind its queued timer/work messages — each of which can
  # issue further Repo calls (slow under suite load) — while the monitor
  # stays alive. Every live pid in the tree is therefore monitored BEFORE
  # the kill; the kill goes to the root (propagating to the linked
  # children); then each DOWN is awaited until a single overall deadline,
  # raising loudly on timeout. This `on_exit` only returns once the whole
  # tree is dead, so the sandbox `stop_owner` running after it (registered
  # earlier in `Shoestring.DataCase.setup_sandbox/1`, LIFO) can never race
  # a live Repo client. The timeout is a bounded backstop, not a sleep:
  # every DOWN short-circuits the wait.
  defp stop_root_synchronously(root, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    pids =
      [root | live_tree_pids(root)]
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()

    refs = for pid <- pids, into: %{}, do: {Process.monitor(pid), pid}

    if is_pid(root) and Process.alive?(root) do
      Process.exit(root, :kill)
    end

    await_tree_down(refs, deadline)
  end

  # Live descendants of a supervisor, recursively. Only `:supervisor`
  # children are descended into: probing a worker with `which_children`
  # would crash it (no such `handle_call`), and with a live `:permanent`
  # parent that crash would instantly restart it under the same name —
  # reincarnating the very process teardown is trying to reap. Guards and
  # catches make it safe against a tree that is dying concurrently: dead
  # branches contribute nothing.
  defp live_tree_pids(sup) do
    if is_pid(sup) and Process.alive?(sup) do
      try do
        sup
        |> Supervisor.which_children()
        |> Enum.flat_map(fn
          {_id, pid, :supervisor, _modules} when is_pid(pid) ->
            [pid | live_tree_pids(pid)]

          {_id, pid, _type, _modules} when is_pid(pid) ->
            [pid]

          _other ->
            []
        end)
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp await_tree_down(refs, _deadline) when map_size(refs) == 0, do: :ok

  defp await_tree_down(refs, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      raise "root teardown timed out waiting for DOWN from #{inspect(Map.values(refs))}"
    end

    receive do
      {:DOWN, ref, :process, _pid, _reason} ->
        await_tree_down(Map.delete(refs, ref), deadline)
    after
      remaining ->
        raise "root teardown timed out waiting for DOWN from #{inspect(Map.values(refs))}"
    end
  end

  defp root_child_pid(root, id) do
    if is_pid(root) and Process.alive?(root) do
      try do
        root
        |> Supervisor.which_children()
        |> Enum.find_value(fn {child_id, pid, _, _} -> if child_id == id, do: pid end)
      catch
        :exit, _ -> nil
      end
    end
  end

  defp cap_child_pid(cap_sup, id) do
    if is_pid(cap_sup) and Process.alive?(cap_sup) do
      try do
        cap_sup
        |> Supervisor.which_children()
        |> Enum.find_value(fn {child_id, pid, _, _} -> if child_id == id, do: pid end)
      catch
        :exit, _ -> nil
      end
    end
  end

  defp wait_for(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case fun.() do
        nil ->
          Process.sleep(10)
          {:cont, nil}

        false ->
          Process.sleep(10)
          {:cont, nil}

        value ->
          {:halt, value}
      end
    end)
  end

  defp wait_connected(monitor) do
    wait_for(fn ->
      _ = :sys.get_state(monitor)
      if CodexMonitor.status(monitor) == :connected, do: true, else: false
    end)
  end

  test "production wiring is transient: intensity exhaustion never propagates" do
    spec = CapacitySupervisor.child_spec(name: nil)
    assert spec.restart == :transient
    assert spec.type == :supervisor

    # The application call site pins the same restart: rebuilding it the way
    # application.ex does must also yield :transient.
    app_site =
      Supervisor.child_spec(CapacitySupervisor, restart: :transient)

    assert app_site.restart == :transient
  end

  test "a crash-looping monitor cannot collapse the root: survivors stay up and the UI stays honest",
       %{conn: conn} do
    test_pid = self()
    normal_read = Fixtures.load_fixture!("codex/normal-read.json")["payload"]["result"]

    # The healthy provider ingests through the REAL durable ledger, so the
    # observatory assertion below reads last-known truth, not test fiction.
    healthy_sink = fn snapshot ->
      result = Observatory.ingest(snapshot)
      send(test_pid, {:storm_healthy_ingested, snapshot})

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

    # Production restart value, verbatim: the regression tracks the real
    # wiring, so reverting the fix flips this spec back to :permanent and
    # the storm assertions below fail.
    cap_base_spec =
      CapacitySupervisor.child_spec(
        name: :cap_storm_sup,
        claude: [
          name: :victim_claude_storm,
          version: "2.1.251",
          clock: fn -> @claude_time end,
          sink: fn snapshot, _opts -> {:ok, :persisted, snapshot} end
        ],
        codex: [enabled: false]
      )

    cap_spec = %{cap_base_spec | id: :cap_sup_under_test}

    healthy_opts = [
      name: :healthy_codex_storm,
      version: "0.150.1",
      transport_pid: fake,
      sink: healthy_sink,
      clock: fn -> @codex_time end,
      base_backoff_ms: 50,
      max_backoff_ms: 100
    ]

    children = [
      %{
        id: :endpoint_standin,
        start: {Agent, :start_link, [fn -> :ok end, [name: :endpoint_standin_storm]]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      },
      %{
        id: :healthy_codex_monitor,
        start: {CodexMonitor, :start_link, [healthy_opts]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      },
      cap_spec
    ]

    # Unlinked on purpose: on the unfixed wiring the test root is EXPECTED
    # to die, and the test must observe that death — not die with it.
    {:ok, root} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(root)

    on_exit(fn -> stop_root_synchronously(root) end)

    root_ref = Process.monitor(root)

    cap_pid = root_child_pid(root, :cap_sup_under_test)
    assert is_pid(cap_pid)

    healthy_pid = Process.whereis(:healthy_codex_storm)
    assert is_pid(healthy_pid)

    endpoint_pid = Process.whereis(:endpoint_standin_storm)
    assert is_pid(endpoint_pid)

    # The healthy provider connects and persists a real ledger observation
    # BEFORE the storm, giving the UI honest last-known state to serve after.
    assert wait_connected(healthy_pid) == true
    assert_receive {:storm_healthy_ingested, %_{capacity_state: :observed}}, 5_000
    _ = :sys.get_state(healthy_pid)
    assert %{} = CodexMonitor.last_observation(healthy_pid)

    victim0 = cap_child_pid(cap_pid, :claude_monitor)
    assert is_pid(victim0)

    # Drive the storm: kill the victim on every start, across capacity
    # supervisor restarts, until the root dies (unfixed wiring) or the
    # budget expires. On the fixed wiring the capacity supervisor dies once
    # and is never re-armed, so the loop below goes quiet after the first
    # intensity exhaustion.
    deadline = System.monotonic_time(:millisecond) + @storm_budget_ms
    drive_storm(root, deadline)

    # (1) The root/app supervisor and its other children SURVIVE.
    assert Process.alive?(root),
           "test root supervisor died: the restart storm propagated past capacity supervision"

    assert root_child_pid(root, :endpoint_standin) |> is_pid(),
           "endpoint stand-in died with the storm"

    assert Process.alive?(endpoint_pid), "endpoint stand-in process did not survive"

    # The exhausted capacity child stays DOWN: transient never re-arms a
    # `:shutdown` exit. (On the old :permanent wiring the root restarts
    # it, so this fails there.)
    assert root_child_pid(root, :cap_sup_under_test) in [nil, :undefined],
           "capacity supervisor was re-armed after intensity exhaustion (expected :transient stay-down)"

    # (2) The healthy sibling monitor survives: same pid, still serving.
    assert Process.whereis(:healthy_codex_storm) == healthy_pid,
           "healthy provider monitor did not survive the storm"

    assert Process.alive?(healthy_pid)
    _ = :sys.get_state(healthy_pid)
    assert CodexMonitor.status(healthy_pid) == :connected
    assert %{} = CodexMonitor.last_observation(healthy_pid)

    # The test root itself never collapsed mid-storm.
    refute_received {:DOWN, ^root_ref, :process, _, _}

    # (3) The observatory still renders honest ledger state: the durable
    # ledger outlives capacity supervision, so the UI shows last-known
    # truth (never fabricated liveness, never a dead page).
    assert %_{} =
             Observatory.get_latest_observation("codex", "app_server_stdio", "subscription")

    {:ok, view, html} = live(conn, "/observatory")
    assert html =~ "Capacity Observatory"
    assert html =~ "codex"
    assert has_element?(view, "#observations-list")
    refute has_element?(view, "#observations-empty")
  end

  # LOCK: teardown must leave no Repo-touching process alive. The healthy
  # monitor traps exits and swallows EXIT messages in its catch-all
  # `handle_info`, so killing the root and awaiting only the root's DOWN
  # leaves the monitor running: it keeps ingesting through `Observatory`
  # into `Repo` after the sandbox owner is released, producing
  # `DBConnection` ownership errors and `Database busy` contention in
  # later tests. Fails pre-fix (monitor still alive after teardown);
  # passes once the helper guarantees the whole tree is down.
  test "teardown leaves no Repo-touching monitor alive" do
    test_pid = self()
    normal_read = Fixtures.load_fixture!("codex/normal-read.json")["payload"]["result"]

    sink = fn snapshot ->
      send(test_pid, {:teardown_probe_ingested, snapshot})
      Observatory.ingest(snapshot)
    end

    {:ok, fake} =
      start_supervised(
        {FakeTransport,
         [owner: self(), emit_connected: false, auto_respond: codex_auto_respond(normal_read)]}
      )

    monitor_opts = [
      name: :teardown_probe_monitor,
      version: "0.150.1",
      transport_pid: fake,
      sink: sink,
      clock: fn -> @codex_time end,
      base_backoff_ms: 50,
      max_backoff_ms: 100
    ]

    children = [
      %{
        id: :probe_monitor,
        start: {CodexMonitor, :start_link, [monitor_opts]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      }
    ]

    # Unlinked on purpose, mirroring the storm topology: teardown (not a
    # link) must reap the tree.
    {:ok, root} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(root)

    monitor_pid = Process.whereis(:teardown_probe_monitor)
    assert is_pid(monitor_pid)

    # Prove it is alive AND Repo-touching before teardown (event-driven,
    # no sleeps: the sink itself notifies).
    assert_receive {:teardown_probe_ingested, %_{capacity_state: :observed}}, 5_000

    stop_root_synchronously(root)

    refute Process.alive?(monitor_pid),
           "monitor survived root teardown and can keep touching Repo after sandbox release"

    assert Process.whereis(:teardown_probe_monitor) == nil,
           "monitor name still registered after teardown"
  end

  # Kills the victim monitor inside whichever capacity supervisor incarnation
  # is currently alive under `root`, until `deadline`. Returns when the root
  # is dead, the deadline passes, or the capacity child stays down past a
  # grace window (fixed wiring: no re-arm, storm over).
  defp drive_storm(root, deadline) do
    cond do
      not Process.alive?(root) ->
        :root_dead

      System.monotonic_time(:millisecond) > deadline ->
        :budget_spent

      true ->
        case root_child_pid(root, :cap_sup_under_test) do
          pid when is_pid(pid) ->
            case cap_child_pid(pid, :claude_monitor) do
              victim when is_pid(victim) ->
                ref = Process.monitor(victim)
                Process.exit(victim, :kill)

                receive do
                  {:DOWN, ^ref, :process, ^victim, _} -> :killed
                after
                  2_000 -> :kill_timeout
                end

                drive_storm(root, deadline)

              _ ->
                # Victim restarting inside a live capacity supervisor; keep driving.
                Process.sleep(10)
                drive_storm(root, deadline)
            end

          _ ->
            # Capacity child currently down. On the fixed wiring it stays
            # down (storm contained); on the old wiring the root re-arms it
            # within milliseconds (storm continues). Give it a grace window
            # before declaring the storm over.
            Process.sleep(500)

            if Process.alive?(root) and
                 root_child_pid(root, :cap_sup_under_test) in [nil, :undefined] do
              :contained
            else
              drive_storm(root, deadline)
            end
        end
    end
  end
end
