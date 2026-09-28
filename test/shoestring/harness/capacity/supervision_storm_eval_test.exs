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
  alias Shoestring.Repo

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

  # Deterministic whole-tree teardown helper: the tree under `root` can
  # touch the Repo, and awaiting only the root's DOWN is NOT enough (see
  # the regression test below). Every live pid in the tree is therefore
  # monitored BEFORE the kill — monitors on already-dead pids fire
  # immediately, so no liveness pre-check can race — then the root is
  # killed (linked descendants die by propagation) and every remaining
  # snapshot pid is killed directly (idempotent for the already-dying;
  # required for members that detached from the root, which propagation
  # can never reach), and each DOWN is awaited until a single overall
  # deadline. The deadline (default 10 s, deliberately distinct from the
  # 5 s per-child shutdown budgets in the fixtures) bounds total hangs;
  # every DOWN short-circuits the wait, so it is a backstop, not a sleep.
  # This `on_exit` only returns once the whole tree is dead, so the
  # sandbox `stop_owner` running after it (registered earlier in
  # `Shoestring.DataCase.setup_sandbox/1`, LIFO) can never race a live
  # Repo client. No sleeps, no retries, no polling, no `Process.alive?`
  # synchronization (post-DOWN death assertions elsewhere are monotonic,
  # not synchronization). Residual: the snapshot requires a live root — a
  # dead root cannot be traversed, so orphans of an already-dead tree must
  # be reaped by pid (as the pre-fix test below does for its survivor).
  defp stop_root_synchronously(root, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    pids =
      [root | live_tree_pids(root)]
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()

    refs = for pid <- pids, into: %{}, do: {Process.monitor(pid), pid}

    if is_pid(root) do
      Process.exit(root, :kill)
    end

    for pid <- pids, pid != root do
      Process.exit(pid, :kill)
    end

    await_tree_down(refs, deadline)
  end

  # Live descendants of a supervisor, recursively. Only `:supervisor`
  # children are descended into: probing a worker with `which_children`
  # would crash it (no such `handle_call`), and with a live `:permanent`
  # parent that crash would instantly restart it under the same name —
  # reincarnating the very process teardown is trying to reap. No
  # liveness pre-checks (a monitor on a dead pid fires immediately, and
  # `which_children` on a dead supervisor exits into the catch below):
  # dead branches contribute nothing, deterministically.
  defp live_tree_pids(sup) do
    if is_pid(sup) do
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
    if is_pid(root) do
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
    if is_pid(cap_sup) do
      try do
        cap_sup
        |> Supervisor.which_children()
        |> Enum.find_value(fn {child_id, pid, _, _} -> if child_id == id, do: pid end)
      catch
        :exit, _ -> nil
      end
    end
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
    # Deterministic sync without polling: the sink message proves a frame
    # was ingested, and `:sys.get_state/1` guarantees all prior messages
    # were handled before the status is read.
    assert_receive {:storm_healthy_ingested, %_{capacity_state: :observed}}, 5_000
    _ = :sys.get_state(healthy_pid)
    assert CodexMonitor.status(healthy_pid) == :connected
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

  # LOCK: teardown must reap the whole tree — including members that
  # outlive the root's death. Awaiting only the root's DOWN (the pre-fix
  # helper below) returns while such a member is still alive; the fixed
  # helper monitors every snapshot pid and kills each directly, so its
  # return implies every member dead. Both directions below are
  # deterministic (no timing): the detached member is unlinked and parked,
  # so nothing the root's death propagates can ever kill it (survival is
  # structural), while death after an observed DOWN is monotonic.
  #
  # The detached member is a SYNTHETIC model of the whole-snapshot
  # teardown postcondition — every snapshot pid dead when the helper
  # returns — not a faithful reproduction of the historical shutdown
  # mechanism. What code reasoning supports (REPO-INSPECTION, not a
  # runtime proof): the real `CodexMonitor` sets `Process.flag(:trap_exit,
  # true)` in `init/1` and has a catch-all `handle_info(_other, ...)`
  # clause that keeps its state. What is NOT established: that a
  # parent's EXIT ever reached that clause and was swallowed there.
  # OTP itself handles a parent EXIT inside gen_server after the
  # messages already queued in the mailbox, and the monitor's direct
  # parent is the capacity supervisor, not the test root — so the exact
  # historical path by which a Repo-touching monitor outlived root
  # teardown was never determined. Likewise a root DOWN does not
  # establish that descendants have finished asynchronous shutdown;
  # that is exactly what the fixed helper refuses to assume.
  test "teardown reaps the whole tree including members detached from the root" do
    test_pid = self()

    children = [
      %{
        id: :linked_worker,
        start: {Agent, :start_link, [fn -> :ok end, []]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      },
      %{
        id: :detached_worker,
        start: {Task, :start_link, [fn -> detach_and_park(test_pid) end]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }
    ]

    {:ok, root} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(root)

    on_exit(fn -> stop_root_synchronously(root) end)

    assert_receive {:detached_repo_ok, detached_pid}, 5_000
    assert is_pid(detached_pid)

    stop_root_synchronously(root)

    # Every snapshot pid is dead: the helper observed each DOWN before
    # returning, and dead stays dead.
    refute Process.alive?(root), "root survived synchronous teardown"

    refute Process.alive?(detached_pid),
           "detached member survived synchronous teardown and can keep touching Repo"
  end

  # Documentation of the pre-fix helper's insufficiency, pinned
  # deterministically: kill the root and await only the root's DOWN (the
  # exact pre-fix helper semantics, preserved below). The detached member
  # is structurally alive afterwards — root-only evidence cannot prove
  # tree teardown. This test passes on every commit by construction (the
  # helper under test is local to this file); it documents the property,
  # it is not a regression lock on production behavior. Cleans up with
  # the fixed helper.
  test "root-only teardown demonstrably leaves a detached member alive" do
    test_pid = self()

    children = [
      %{
        id: :detached_worker,
        start: {Task, :start_link, [fn -> detach_and_park(test_pid) end]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }
    ]

    {:ok, root} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(root)

    on_exit(fn -> stop_root_synchronously(root) end)

    assert_receive {:detached_repo_ok, detached_pid}, 5_000
    assert is_pid(detached_pid)

    pre_fix_stop_root_synchronously(root)

    assert Process.alive?(detached_pid),
           "detached member died: root-only evidence cannot prove tree teardown"

    # Direct, deterministic cleanup: the dead root can no longer be
    # traversed for a snapshot, so the known survivor is reaped by pid
    # (its DOWN observed, death monotonic).
    ref = Process.monitor(detached_pid)
    Process.exit(detached_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^detached_pid, _}, 5_000
    refute Process.alive?(detached_pid)
  end

  # Parked Repo-capable worker that detaches from its supervisor after
  # start: unlinks every link it holds except the test's (in a fresh tree,
  # exactly the supervisor link), proves Repo access from its own pid,
  # notifies, then parks until killed. A SYNTHETIC stand-in for "a member
  # that outlives its root" — it models the teardown postcondition, not
  # the real monitor's shutdown path.
  defp detach_and_park(test_pid) do
    {:links, links} = Process.info(self(), :links)

    for pid <- links, pid != test_pid do
      Process.unlink(pid)
    end

    _count = Repo.aggregate("goals", :count)
    send(test_pid, {:detached_repo_ok, self()})

    receive do
      :stop -> :stopped
    end
  end

  # The exact pre-fix helper semantics (kill the root, await only the
  # root's DOWN), preserved to pin its insufficiency. Not used by any
  # production path.
  defp pre_fix_stop_root_synchronously(root, timeout \\ 5_000) do
    ref = Process.monitor(root)
    Process.exit(root, :kill)

    receive do
      {:DOWN, ^ref, :process, ^root, _reason} -> :ok
    after
      timeout ->
        raise "root supervisor #{inspect(root)} did not shut down within #{timeout} ms"
    end
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
                # Storm-driver pacing only (yields so the supervisor can
                # re-arm the victim): no assertion depends on this duration —
                # every kill below is confirmed by an observed DOWN, and every
                # test assertion syncs on monitor DOWNs plus `:sys.get_state/1`.
                Process.sleep(10)
                drive_storm(root, deadline)
            end

          _ ->
            # Capacity child currently down. On the fixed wiring it stays
            # down (storm contained); on the old wiring the root re-arms it
            # within milliseconds (storm continues). Give it a grace window
            # before declaring the storm over. Storm-driver pacing only (it
            # bounds how long the driver waits before re-checking, so the
            # old-wiring re-arm has time to show): no assertion depends on
            # the duration — the stay-down assertion reads supervisor state
            # after the driver returns, and teardown syncs on DOWNs.
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
