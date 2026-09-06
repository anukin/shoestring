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
  # Repo (the healthy monitor's sink calls `Observatory.ingest/1`, which
  # goes through `Observatory.ensure_provisioned/1` -> `Repo.get/2`), so
  # it must be fully DOWN before the Ecto sandbox owner — released by the
  # earlier-registered `on_exit` in `Shoestring.DataCase.setup_sandbox/1`
  # — goes away. A fire-and-forget `Process.exit(root, :kill)` returns
  # immediately and lets the sandbox owner win that race, producing
  # `DBConnection` ownership errors ("owner exited while client still
  # holds a connection"). Monitoring `root` and awaiting its `:DOWN`
  # makes the ordering deterministic: this `on_exit` only returns once
  # the tree is dead, so the sandbox `stop_owner` running after it can
  # never race a live Repo client. The timeout is a bounded backstop, not
  # a sleep: on the happy path the `receive` returns as soon as `:DOWN`
  # arrives, and `:kill` is untrappable so the wait always terminates.
  defp stop_root_synchronously(root, timeout \\ 5_000) do
    ref = Process.monitor(root)
    Process.exit(root, :kill)

    receive do
      {:DOWN, ^ref, :process, ^root, _reason} -> :ok
    after
      timeout ->
        raise "root supervisor #{inspect(root)} did not shut down within #{timeout} ms"
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
