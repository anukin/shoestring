defmodule Shoestring.Harness.Dispatch.ElfEffectTest do
  @moduledoc """
  Loop-closure W2: the production dispatch-worker effect starts the Elf.

  Hermetic: Oban `:manual`, `Shoestring.Harness.Fake` adapter, trivial local
  commands (`sleep`), isolated Elf supervisor per test. Never a provider CLI,
  never the network.
  """

  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  alias Shoestring.Elves
  alias Shoestring.Harness.{DispatchRecord, Dispatches, RunRecord}
  alias Shoestring.Harness.Dispatch.ElfEffect
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()

    previous_effect = Application.get_env(:shoestring, :dispatch_effect)
    previous_elf_opts = Application.get_env(:shoestring, :elf_dispatch_opts)
    previous_clock = Application.get_env(:shoestring, :dispatch_clock)

    Application.put_env(:shoestring, :dispatch_effect, ElfEffect)

    Application.put_env(:shoestring, :dispatch_clock, Shoestring.Test.FixedClock)

    put_elf_opts(
      supervisor: sup,
      scenario: Scenario.normal_completion(),
      command: ["sleep", "30"],
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000]
    )

    on_exit(fn ->
      restore_env(:dispatch_effect, previous_effect)
      restore_env(:elf_dispatch_opts, previous_elf_opts)
      restore_env(:dispatch_clock, previous_clock)
    end)

    {:ok, goal: goal, task: task}
  end

  test "configured effect starts exactly one Elf and the run reaches terminal", %{
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    # The job carries only durable identifiers — no prompt, no scenario, no argv.
    assert Map.keys(job.args) |> Enum.sort() == [
             "dispatch_id",
             "goal_id",
             "request_version",
             "run_id"
           ]

    assert :ok = perform_delivery(job)

    run_id = dispatch.run_id

    assert {:ok, _terminal} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.terminal_event(goal.id, run_id) end)

    assert ElvesHelpers.terminal_event(goal.id, run_id).type == "run.completed"

    assert %DispatchRecord{status: "effect_completed"} =
             Repo.get(DispatchRecord, dispatch.dispatch_id)

    assert 1 == ElvesHelpers.count_events(goal.id, run_id, ["run.running"])

    ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id))
  end

  test "unconfigured effect still fails closed without starting anything", %{
    goal: goal,
    task: task
  } do
    Application.delete_env(:shoestring, :dispatch_effect)

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    assert {:cancel, :effect_failed} = perform_delivery(job)

    assert %DispatchRecord{status: "effect_failed", outcome_code: "effect_failed"} =
             Repo.get(DispatchRecord, dispatch.dispatch_id)

    assert %TrajectoryEvent{} =
             Repo.get_by(TrajectoryEvent,
               goal_id: goal.id,
               run_id: dispatch.run_id,
               type: "dispatch.effect_failed",
               idempotency_key: "dispatch-effect-failed:#{dispatch.dispatch_id}"
             )

    assert 0 == ElvesHelpers.count_events(goal.id, dispatch.run_id, ["run.running"])
    assert nil == ElvesHelpers.terminal_event(goal.id, dispatch.run_id)
  end

  test "already-running Elf completes the delivery without a second Elf", %{
    goal: goal,
    task: task
  } do
    put_elf_opts(
      supervisor: elf_supervisor(),
      scenario: ElvesHelpers.custom_scenario(:already_running_hold, []),
      command: ["sleep", "30"],
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000]
    )

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    run_id = dispatch.run_id
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    # Claim first (exactly as the worker does), then let the UI-style direct
    # start slip in before the effect runs: the production race this locks.
    assert {:ok, {:execute, claimed, run}} =
             Dispatches.prepare_for_effect(dispatch.dispatch_id,
               clock: Shoestring.Test.FixedClock
             )

    elf_opts = Application.get_env(:shoestring, :elf_dispatch_opts, [])
    assert {:ok, pid} = Elves.start_elf(request, claimed, elf_opts)
    assert is_pid(pid)

    # The effect attaches to the live Elf instead of starting a second one,
    # and normalizes the 3-tuple to a worker-completing 2-tuple.
    assert {:ok, :already_running} = ElfEffect.perform(run, claimed)
    assert Elves.whereis(run_id) == pid

    # The Elf appends run.running asynchronously after start; wait for it,
    # then lock that exactly one Elf ever announced itself.
    assert {:ok, true} =
             ElvesHelpers.wait_until(fn ->
               ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 1
             end)

    # The worker's completion half of the mapping.
    assert :ok =
             Dispatches.complete_effect(dispatch.dispatch_id, clock: Shoestring.Test.FixedClock)

    assert %DispatchRecord{status: "effect_completed"} =
             Repo.get(DispatchRecord, dispatch.dispatch_id)

    # The Oban job for the same delivery converges through the same path.
    assert :ok = perform_delivery(job)

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
    assert ElvesHelpers.terminal_event(goal.id, run_id).type == "run.cancelled"
  end

  test "start error records effect_failed without starting an Elf", %{
    goal: goal,
    task: task
  } do
    refusing = start_supervised!({DynamicSupervisor, strategy: :one_for_one, max_children: 0})

    put_elf_opts(
      supervisor: refusing,
      scenario: Scenario.normal_completion(),
      command: ["sleep", "30"],
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000]
    )

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    assert {:cancel, :effect_failed} = perform_delivery(job)

    # The failure is the start refusal itself, surfaced with its reason.
    assert {:error, :max_children} =
             ElfEffect.perform(
               Repo.get!(RunRecord, dispatch.run_id),
               Repo.get!(DispatchRecord, dispatch.dispatch_id)
             )

    assert %DispatchRecord{status: "effect_failed", outcome_code: "effect_failed"} =
             Repo.get(DispatchRecord, dispatch.dispatch_id)

    assert %TrajectoryEvent{} =
             Repo.get_by(TrajectoryEvent,
               goal_id: goal.id,
               run_id: dispatch.run_id,
               type: "dispatch.effect_failed",
               idempotency_key: "dispatch-effect-failed:#{dispatch.dispatch_id}"
             )

    assert 0 == ElvesHelpers.count_events(goal.id, dispatch.run_id, ["run.running"])
    assert nil == ElvesHelpers.terminal_event(goal.id, dispatch.run_id)
  end

  test "invalid persisted request records effect_unknown and invents no execution", %{
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    # Corrupt the persisted intent so no valid RunRequest can be rebuilt: an
    # empty policy can never validate, so the effect must refuse to execute.
    Repo.get!(RunRecord, dispatch.run_id)
    |> Ecto.Changeset.change(policy: %{})
    |> Repo.update!()

    assert {:cancel, :effect_outcome_unknown} = perform_delivery(job)

    assert %DispatchRecord{status: "effect_unknown", outcome_code: "effect_unknown"} =
             Repo.get(DispatchRecord, dispatch.dispatch_id)

    assert %TrajectoryEvent{} =
             Repo.get_by(TrajectoryEvent,
               goal_id: goal.id,
               run_id: dispatch.run_id,
               type: "dispatch.effect_unknown",
               idempotency_key: "dispatch-effect-unknown:#{dispatch.dispatch_id}"
             )

    assert 0 == ElvesHelpers.count_events(goal.id, dispatch.run_id, ["run.running"])
    assert nil == ElvesHelpers.terminal_event(goal.id, dispatch.run_id)
  end

  test "recovery requeue after a crashed delivery executes through the effect", %{
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    # The first delivery dies before the claim: the dispatch stays
    # `requested` with a dead job linked.
    job
    |> Ecto.Changeset.change(state: "discarded", discarded_at: Shoestring.Test.FixedClock.now())
    |> Repo.update!()

    assert {:ok, %{repaired_count: 1, failures: []}} =
             Dispatches.reconcile(clock: Shoestring.Test.FixedClock)

    assert %DispatchRecord{job_id: repaired_job_id} =
             Repo.get!(DispatchRecord, dispatch.dispatch_id)

    assert repaired_job_id != job.id

    assert :ok = perform_delivery(Repo.get!(Oban.Job, repaired_job_id))

    run_id = dispatch.run_id

    assert {:ok, _terminal} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.terminal_event(goal.id, run_id) end)

    assert ElvesHelpers.terminal_event(goal.id, run_id).type == "run.completed"

    assert %DispatchRecord{status: "effect_completed"} =
             Repo.get(DispatchRecord, dispatch.dispatch_id)

    assert 1 == ElvesHelpers.count_events(goal.id, run_id, ["run.running"])

    ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id))
  end

  defp elf_supervisor do
    Application.get_env(:shoestring, :elf_dispatch_opts, []) |> Keyword.fetch!(:supervisor)
  end

  defp put_elf_opts(opts) do
    Application.put_env(:shoestring, :elf_dispatch_opts, opts)
  end

  defp perform_delivery(job) do
    job
    |> Map.put(:attempted_at, Shoestring.Test.FixedClock.now())
    |> Map.put(:scheduled_at, Shoestring.Test.FixedClock.now())
    |> perform_job()
  end

  defp restore_env(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore_env(key, value), do: Application.put_env(:shoestring, key, value)
end
