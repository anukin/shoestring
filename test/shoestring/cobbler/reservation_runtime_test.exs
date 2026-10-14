defmodule Shoestring.Cobbler.ReservationRuntimeTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{Elves, Trajectory}
  alias Shoestring.Cobbler.{ReservationPolicy, ReservationRecord, Reservations}
  alias Shoestring.Harness.Fake
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Test.{CobblerHelpers, ElvesHelpers, FixedClock}
  @now FixedClock.now()

  setup do
    supervisor =
      start_supervised!(
        {Shoestring.Elves.Supervisor, name: Shoestring.Test.ReservationRuntimeSupervisor}
      )

    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()

    payload =
      CobblerHelpers.admission_payload(
        provider_id: "fake",
        adapter_id: Fake.identity().adapter_id,
        scope: "fixture"
      )

    payload =
      Map.merge(payload, %{
        "evaluated_at" => DateTime.to_iso8601(@now),
        "observation" => %{
          "snapshot_id" => Ecto.UUID.generate(),
          "observed_at" => DateTime.to_iso8601(@now),
          "confidence" => "high"
        },
        "proposed_bounds" => %{"deadline" => DateTime.to_iso8601(DateTime.add(@now, 300))}
      })

    assert {:ok, event} =
             Trajectory.append(goal.id, %{
               "type" => "admission.decided",
               "schema_version" => 1,
               "actor" => "cobbler",
               "occurred_at" => @now,
               "payload" => payload
             })

    attrs = %{
      id: Ecto.UUID.generate(),
      goal_id: goal.id,
      execution_id: Ecto.UUID.generate(),
      plan_task_id: "alpha",
      attempt: 1,
      run_id: Ecto.UUID.generate(),
      admission_event_id: event.id
    }

    {:ok, policy} = ReservationPolicy.new()
    assert {:ok, reservation} = Reservations.hold(attrs, policy, now: @now)
    %{supervisor: supervisor, goal: goal, task: task, reservation: reservation}
  end

  defp launch(c, scenario) do
    request = ElvesHelpers.run_request(c.goal, c.task)

    assert {:ok, pid} =
             Elves.start_run(request, Fake.identity(),
               supervisor: c.supervisor,
               run_id: c.reservation.run_id,
               scenario: scenario,
               command: ["sleep", "30"],
               clock: FixedClock,
               notify: self(),
               runner_opts: [kill_grace_ms: 100, reap_timeout_ms: 1000]
             )

    {pid, Process.monitor(pid)}
  end

  test "real Fake Elf completion closes its reservation using the production OS probe", c do
    {pid, ref} = launch(c, Scenario.normal_completion(now: @now))
    run_id = c.reservation.run_id
    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    assert {:ok, %{disposition: :closed, settlement: settlement}} =
             Reservations.reconcile(c.reservation.id, now: @now)

    assert settlement.kind == "consumed_closed"
    assert settlement.evidence["process_groups"] == "absent"
    assert settlement.evidence["elf_present"] == false
    assert length(settlement.evidence["running_event_ids"]) >= 1
    assert Reservations.outstanding() == []
    assert Repo.get!(ReservationRecord, c.reservation.id) == c.reservation
    assert ElvesHelpers.terminal_event(c.goal.id, run_id).type == "run.completed"
  end

  test "explicit cancellation reaps the owned group before reservation settlement", c do
    {pid, ref} = launch(c, ElvesHelpers.custom_scenario(:quiet_reserved_run, []))
    _ = :sys.get_state(pid)
    run_id = c.reservation.run_id

    assert {:ok, %{disposition: :retained, reason: :elf_running}} =
             Reservations.reconcile(c.reservation.id, now: @now)

    assert {:ok, :cancelled} = Elves.cancel_run(run_id)
    assert_receive {:elf_terminal, ^run_id, %{class: :cancelled}}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert {:ok, %{disposition: :closed}} = Reservations.reconcile(c.reservation.id, now: @now)
    assert Reservations.outstanding() == []
    assert ElvesHelpers.terminal_event(c.goal.id, run_id).type == "run.cancelled"
  end
end
