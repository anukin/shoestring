defmodule Shoestring.Harness.Capacity.SupervisionTreeTest do
  @moduledoc """
  Supervision wiring for the independently supervised Claude and Codex
  capacity monitors (`Shoestring.Harness.Capacity.Supervisor`).

  Uses offline fakes only: explicit versions (no version discovery) and
  in-memory sinks/transports, so no provider CLI is ever invoked.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Harness.Capacity.ClaudeMonitor
  alias Shoestring.Harness.Capacity.Fixtures
  alias Shoestring.Harness.Capacity.Supervisor, as: CapacitySupervisor

  @claude_time ~U[2026-08-29 07:34:25Z]
  @codex_time ~U[2026-08-29 04:38:25Z]

  defp claude_opts(name) do
    [
      name: name,
      version: "2.1.251",
      clock: fn -> @claude_time end,
      sink: fn snapshot, _opts -> {:ok, :persisted, snapshot} end
    ]
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

  defp start_codex_stack(suffix, sink \\ nil) do
    normal_read = Fixtures.load_fixture!("codex/normal-read.json")["payload"]["result"]
    sink = sink || fn snapshot -> {:ok, :persisted, snapshot} end

    {:ok, fake} =
      start_supervised(
        {FakeTransport,
         [owner: self(), emit_connected: false, auto_respond: codex_auto_respond(normal_read)]}
      )

    {fake, normal_read,
     [
       name: :"codex_mon_#{suffix}",
       version: "0.150.1",
       transport_pid: fake,
       sink: sink,
       clock: fn -> @codex_time end,
       base_backoff_ms: 50,
       max_backoff_ms: 100
     ]}
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

        false ->
          Process.sleep(20)
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

  describe "independent supervision" do
    test "a crash in one monitor restarts only that child under :one_for_one" do
      {_fake, _normal_read, codex_opts} = start_codex_stack("iso")

      sup =
        start_supervised!(
          {CapacitySupervisor,
           [
             name: :cap_sup_iso,
             claude: claude_opts(:claude_iso),
             codex: codex_opts
           ]}
        )

      claude_pid = child_pid(sup, :claude_monitor)
      codex_pid = child_pid(sup, :codex_monitor)
      assert is_pid(claude_pid) and is_pid(codex_pid)

      # Codex completes its handshake and serves observations.
      assert wait_connected(codex_pid) == true
      assert %{} = CodexMonitor.last_observation(codex_pid)

      # Crash Claude for real. The supervisor must restart ONLY Claude.
      ref = Process.monitor(claude_pid)
      Process.exit(claude_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^claude_pid, :killed}

      restarted_claude =
        wait_for(fn ->
          pid = child_pid(sup, :claude_monitor)
          if is_pid(pid) and pid != claude_pid and Process.alive?(pid), do: pid, else: nil
        end)

      assert is_pid(restarted_claude)

      # The surviving provider is untouched: same pid, still serving.
      assert child_pid(sup, :codex_monitor) == codex_pid
      assert Process.alive?(codex_pid)
      assert CodexMonitor.status(codex_pid) == :connected
      assert %{} = CodexMonitor.last_observation(codex_pid)

      # The restarted monitor returns with honest unknown state, not fabricated data.
      _ = :sys.get_state(restarted_claude)
      assert {:ok, snapshot} = ClaudeMonitor.current_snapshot(restarted_claude)
      assert snapshot.capacity_state == :unknown
    end

    test "monitors are independently stoppable and restartable" do
      {_fake, _normal_read, codex_opts} = start_codex_stack("ctl")

      sup =
        start_supervised!(
          {CapacitySupervisor,
           [name: :cap_sup_ctl, claude: claude_opts(:claude_ctl), codex: codex_opts]}
        )

      codex_pid = child_pid(sup, :codex_monitor)
      assert wait_connected(codex_pid) == true

      assert :ok = Supervisor.terminate_child(sup, :claude_monitor)
      assert child_pid(sup, :claude_monitor) == :undefined

      # Stopping Claude does not disturb Codex.
      assert CodexMonitor.status(codex_pid) == :connected

      assert {:ok, restarted} = Supervisor.restart_child(sup, :claude_monitor)
      assert is_pid(restarted)
      _ = :sys.get_state(restarted)
      assert {:ok, %_{capacity_state: :unknown}} = ClaudeMonitor.current_snapshot(restarted)
    end
  end

  describe "missing or broken provider CLI" do
    test "boots healthy with honest unknown state and no crash loop" do
      failing_claude_runner = fn _cmd, _args, _opts -> raise "claude not installed" end
      failing_codex_runner = fn _cmd, _args -> {"not found", 127} end

      sup =
        start_supervised!(
          {CapacitySupervisor,
           [
             name: :cap_sup_nocli,
             claude: [
               name: :claude_nocli,
               runner: failing_claude_runner,
               clock: fn -> @claude_time end,
               sink: fn snapshot, _opts -> {:ok, :persisted, snapshot} end
             ],
             codex: [
               name: :codex_nocli,
               runner: failing_codex_runner,
               sink: fn snapshot -> {:ok, :persisted, snapshot} end,
               clock: fn -> @codex_time end,
               auto_connect: false
             ]
           ]}
        )

      claude_pid = child_pid(sup, :claude_monitor)
      codex_pid = child_pid(sup, :codex_monitor)
      assert is_pid(claude_pid) and is_pid(codex_pid)

      # Let async version discovery settle, then verify honest states.
      _ = :sys.get_state(claude_pid)
      _ = :sys.get_state(codex_pid)

      assert {:ok, snapshot} = ClaudeMonitor.current_snapshot(claude_pid)
      assert snapshot.capacity_state == :unknown

      assert CodexMonitor.status(codex_pid) == :incompatible
      assert CodexMonitor.get_status(codex_pid).connected? == false

      # No crash loop: both children keep stable pids across supervisor syncs.
      _ = :sys.get_state(sup)
      assert child_pid(sup, :claude_monitor) == claude_pid
      assert child_pid(sup, :codex_monitor) == codex_pid
    end
  end

  describe "restart bounds and test-environment configuration" do
    test "restart intensity is bounded so a looping monitor degrades visibly" do
      assert CapacitySupervisor.max_restarts() == 3
      assert CapacitySupervisor.max_seconds() == 60
      # Tighter than OTP's permissive 3-restarts-in-5-seconds default window.
      assert CapacitySupervisor.max_seconds() > 5

      claude_spec = CapacitySupervisor.claude_child_spec(claude: [name: :claude_probe])
      codex_spec = CapacitySupervisor.codex_child_spec(codex: [name: :codex_probe])

      assert claude_spec.id == :claude_monitor
      assert codex_spec.id == :codex_monitor
      refute claude_spec.id == codex_spec.id
      assert claude_spec.restart == :permanent
      assert codex_spec.restart == :permanent
    end

    test "disabled providers produce no child spec" do
      assert CapacitySupervisor.claude_child_spec(claude: [enabled: false]) == nil
      assert CapacitySupervisor.codex_child_spec(codex: [enabled: false]) == nil
      assert CapacitySupervisor.claude_child_spec(claude: false) == nil
      assert CapacitySupervisor.codex_child_spec(codex: false) == nil
    end

    test "test environment boots a healthy empty supervisor: nothing auto-starts" do
      config = Application.get_env(:shoestring, :capacity_monitors)
      assert get_in(config, [:claude, :enabled]) == false
      assert get_in(config, [:codex, :enabled]) == false

      # The application tree carries the (empty) capacity supervisor in test.
      sup_pid = Process.whereis(CapacitySupervisor)
      assert is_pid(sup_pid)
      assert Supervisor.which_children(sup_pid) == []
    end
  end
end
