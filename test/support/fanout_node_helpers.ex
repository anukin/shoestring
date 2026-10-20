defmodule Shoestring.Test.FanoutNodeHelpers do
  @moduledoc """
  Live supervised-Fake helpers for isolated-node fan-out suites. Callers run
  in a child `mix test` with pooled SQLite and real application restarts.
  """
  import ExUnit.Assertions

  alias Shoestring.Cobbler.{PlanChildMessage, PlanChildWorker}
  alias Shoestring.Harness.{DispatchRecord, DispatchWorker, Fake}
  alias Shoestring.Test.{FanoutBarrierFake, PlanExecutorHelpers, PlanHandoffClock}
  alias Shoestring.{Elves, Repo}

  def configure_node! do
    config = Application.fetch_env!(:shoestring, Repo)

    Application.put_env(
      :shoestring,
      Repo,
      Keyword.merge(config, pool: DBConnection.ConnectionPool, pool_size: 5)
    )

    Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)
    Application.put_env(:shoestring, :dispatch_clock, PlanHandoffClock)
    restart!()
  end

  def barrier_opts!(scenarios \\ %{}) do
    Application.put_env(:shoestring, :elf_dispatch_opts,
      adapter: FanoutBarrierFake,
      clock: PlanHandoffClock,
      command: ["sleep", "30"],
      adapter_opts: %{
        scenario: Fake.Scenario.normal_completion(now: PlanExecutorHelpers.now()),
        scenarios: scenarios,
        barrier_parent: self()
      },
      runner_opts: [kill_grace_ms: 100, reap_timeout_ms: 1000]
    )
  end

  @doc "A scenario that streams progress and never reports a result."
  def working_scenario do
    %Fake.Scenario{
      name: :long_running,
      capacity:
        Fake.Scenario.healthy_snapshot(
          "00000000-0000-4000-8000-f00000000a01",
          PlanExecutorHelpers.now()
        ),
      provider_session_id: "fake-session-long",
      events: [
        Fake.Scenario.lifecycle_event(offset_ms: 0),
        Fake.Scenario.output_event("working", offset_ms: 100)
      ]
    }
  end

  def dispatch_id!(run_id), do: Repo.get_by!(DispatchRecord, run_id: run_id).dispatch_id

  def start_worker!(run_id) do
    dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
    assert :ok = DispatchWorker.perform(Repo.get!(Oban.Job, dispatch.job_id))
    id = dispatch.dispatch_id
    assert_receive {:fanout_stream_ready, pid, ^id}, 15_000
    assert Elves.whereis(run_id) == pid
    pid
  end

  @doc "Lets a working scenario stream; the Elf stays alive with its group."
  def release!(pid) do
    send(pid, :release_stream)
    _ = :sys.get_state(pid)
    pid
  end

  def finish!(pid) do
    ref = Process.monitor(pid)
    send(pid, :release_stream)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
  end

  def recorded_pgid!(run_id) do
    event =
      Repo.get_by!(Shoestring.Trajectory.TrajectoryEvent, type: "run.running", run_id: run_id)

    {pgid, ""} = Integer.parse(String.replace_prefix(event.payload["process_id"], "pgid:", ""))
    pgid
  end

  def observe!(opts, run_id, type) do
    event = Repo.get_by!(Shoestring.Trajectory.TrajectoryEvent, type: type, run_id: run_id)
    row = Repo.get!(PlanChildMessage, event.id)
    Application.put_env(:shoestring, :plan_child_inbox_opts, opts)
    assert :ok = PlanChildWorker.perform(Repo.get!(Oban.Job, row.job_id))
    assert Repo.get!(PlanChildMessage, event.id).status == "observed"
  end

  def restart! do
    pid = Process.whereis(Shoestring.Supervisor)
    ref = Process.monitor(pid)
    assert :ok = Application.stop(:shoestring)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
    assert {:ok, _} = Application.ensure_all_started(:shoestring)
  end
end
