defmodule Shoestring.Harness.Capacity.SupervisionExhaustionSignalTest do
  @moduledoc """
  Discriminating evals for the DEF-01b exhaustion signal.

  `Shoestring.Harness.Capacity.SupervisionWatcher` must emit a `Logger.error`
  AND a `:telemetry` event when the capacity supervisor dies from genuine
  restart-intensity exhaustion, and must stay silent on graceful shutdown.

  The discrimination is structural, not assumed:

    * Exhaustion exits with the bare reason `:shutdown` (OTP's
      `:reached_max_restart_intensity` appears only in its log report, never
      in the exit term). An intentional direct stop (`Supervisor.stop/1`)
      exits `:normal` and is ignored by reason class.
    * A graceful parent-tree shutdown terminates children in reverse start
      order (OTP supervisor docs), so the watcher — started AFTER the
      capacity supervisor, mirroring `Shoestring.Application` — dies first
      and never observes the graceful `:shutdown` exit.

  The negative tests below would fail against a naive always-alert watcher:
  stopping the capacity supervisor directly still delivers a `:DOWN` the live
  watcher observes, so alerting on any `:DOWN` (or on `:normal`) emits the
  error log and telemetry event the tests forbid.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Shoestring.Harness.Capacity.SupervisionWatcher
  alias Shoestring.Harness.Capacity.Supervisor, as: CapacitySupervisor

  @claude_time ~U[2026-08-29 07:34:25Z]
  @disabled_phrase "capacity monitoring is disabled until an explicit operator restart or redeploy"

  defp victim_claude_opts(monitor_name) do
    [
      name: monitor_name,
      version: "2.1.251",
      clock: fn -> @claude_time end,
      sink: fn snapshot, _opts -> {:ok, :persisted, snapshot} end
    ]
  end

  defp benign_claude_opts(monitor_name) do
    [
      name: monitor_name,
      version: "2.1.251",
      clock: fn -> @claude_time end,
      sink: fn snapshot, _opts -> {:ok, :persisted, snapshot} end
    ]
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

  defp attach_exhaustion_handler(tag) do
    test_pid = self()
    telemetry_id = "capacity-exhausted-#{tag}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      telemetry_id,
      SupervisionWatcher.telemetry_event(),
      fn event, measurements, metadata, pid ->
        send(pid, {:capacity_exhausted, event, measurements, metadata})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)
    telemetry_id
  end

  defp start_unlinked_root(children) do
    {:ok, root} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(root)

    on_exit(fn ->
      if Process.alive?(root), do: Process.exit(root, :kill)
    end)

    root
  end

  # Kills the victim monitor inside whichever capacity supervisor incarnation
  # is currently alive under `root`, until the capacity child stays down past
  # a grace window (exhaustion: transient never re-arms it) or `deadline`.
  defp drive_to_exhaustion(root, cap_id, deadline) do
    cond do
      not Process.alive?(root) ->
        :root_dead

      System.monotonic_time(:millisecond) > deadline ->
        :budget_spent

      true ->
        case root_child_pid(root, cap_id) do
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

                drive_to_exhaustion(root, cap_id, deadline)

              _ ->
                Process.sleep(10)
                drive_to_exhaustion(root, cap_id, deadline)
            end

          _ ->
            Process.sleep(500)

            if Process.alive?(root) and root_child_pid(root, cap_id) in [nil, :undefined] do
              :exhausted
            else
              drive_to_exhaustion(root, cap_id, deadline)
            end
        end
    end
  end

  describe "production child order" do
    test "the watcher is terminated before the capacity supervisor (load-bearing order)" do
      children = Supervisor.which_children(Shoestring.Supervisor)
      ids = Enum.map(children, fn {id, _pid, _type, _mods} -> id end)

      assert CapacitySupervisor in ids,
             "capacity supervisor missing from application tree: #{inspect(ids)}"

      assert SupervisionWatcher in ids,
             "exhaustion watcher missing from application tree: #{inspect(ids)}"

      # `which_children/1` returns children in termination order, so the
      # watcher MUST precede the capacity supervisor: on graceful shutdown it
      # dies first and never observes the graceful `:shutdown` exit.
      assert Enum.find_index(ids, &(&1 == SupervisionWatcher)) <
               Enum.find_index(ids, &(&1 == CapacitySupervisor)),
             "watcher must terminate before the capacity supervisor; got order #{inspect(ids)}"
    end
  end

  describe "fires on real exhaustion" do
    test "a genuine restart-intensity exhaustion emits the log line and the telemetry event" do
      attach_exhaustion_handler("positive")

      cap_base_spec =
        CapacitySupervisor.child_spec(
          name: :cap_signal_sup,
          claude: victim_claude_opts(:victim_claude_signal),
          codex: [enabled: false]
        )

      children = [
        %{cap_base_spec | id: :cap_sup_under_test},
        {SupervisionWatcher, [capacity: :cap_signal_sup, name: :watcher_signal]}
      ]

      log =
        capture_log(fn ->
          root = start_unlinked_root(children)

          cap_pid = root_child_pid(root, :cap_sup_under_test)
          assert is_pid(cap_pid)

          deadline = System.monotonic_time(:millisecond) + 20_000
          assert drive_to_exhaustion(root, :cap_sup_under_test, deadline) == :exhausted

          assert Process.alive?(root)
          assert root_child_pid(root, :cap_sup_under_test) in [nil, :undefined]

          assert_receive {:capacity_exhausted, [:shoestring, :capacity, :supervisor, :exhausted],
                          %{count: 1}, %{reason: :shutdown}},
                         5_000
        end)

      assert log =~ @disabled_phrase,
             "expected exhaustion Logger.error; got log:\n#{log}"
    end
  end

  describe "silent on graceful shutdown" do
    test "direct Supervisor.stop of the capacity supervisor emits nothing" do
      attach_exhaustion_handler("neg-direct")

      cap_base_spec =
        CapacitySupervisor.child_spec(
          name: :cap_graceful_direct_sup,
          claude: benign_claude_opts(:claude_graceful_direct),
          codex: [enabled: false]
        )

      children = [
        %{cap_base_spec | id: :cap_sup_graceful},
        {SupervisionWatcher, [capacity: :cap_graceful_direct_sup, name: :watcher_graceful_direct]}
      ]

      root = start_unlinked_root(children)
      cap_pid = root_child_pid(root, :cap_sup_graceful)
      assert is_pid(cap_pid)
      _ = :sys.get_state(cap_pid)

      # A naive always-alert watcher observes this `:DOWN` while alive and
      # would emit the signal; the real watcher ignores `:normal` by reason
      # class, so the refute below fails for the naive implementation.
      log =
        capture_log(fn ->
          assert :ok = Supervisor.stop(cap_pid)
          refute_receive {:capacity_exhausted, _, _, _}, 1_000
        end)

      refute log =~ @disabled_phrase,
             "watcher false-alarmed on graceful direct stop; log:\n#{log}"

      assert Process.alive?(root)
      assert root_child_pid(root, :cap_sup_graceful) in [nil, :undefined]
    end

    test "stopping the parent tree emits nothing (watcher dies first)" do
      attach_exhaustion_handler("neg-parent")

      cap_base_spec =
        CapacitySupervisor.child_spec(
          name: :cap_graceful_tree_sup,
          claude: benign_claude_opts(:claude_graceful_tree),
          codex: [enabled: false]
        )

      # Production order mirrored: watcher AFTER the capacity supervisor, so
      # reverse-order termination takes the watcher out first. A watcher that
      # alerted on the graceful `:shutdown` exit would fire here if it were
      # still alive to observe it.
      children = [
        %{cap_base_spec | id: :cap_sup_tree},
        {SupervisionWatcher, [capacity: :cap_graceful_tree_sup, name: :watcher_graceful_tree]}
      ]

      root = start_unlinked_root(children)
      assert is_pid(root_child_pid(root, :cap_sup_tree))

      log =
        capture_log(fn ->
          assert :ok = Supervisor.stop(root)
        end)

      refute_receive {:capacity_exhausted, _, _, _}, 500

      refute log =~ @disabled_phrase,
             "watcher false-alarmed on graceful parent shutdown; log:\n#{log}"

      refute Process.alive?(root)
    end
  end
end
