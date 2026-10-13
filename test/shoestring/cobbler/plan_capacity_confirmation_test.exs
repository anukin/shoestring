defmodule Shoestring.Cobbler.PlanCapacityConfirmationTest do
  use Shoestring.DataCase, async: false
  import Ecto.Query
  import Shoestring.Test.PlanExecutorHelpers
  alias Shoestring.{AgentProfiles, Trajectory}
  alias Shoestring.Cobbler.{ExecutionAdmission, ExecutionControl, PlanCapacityConfirmation}
  alias Shoestring.Harness.{Capacity, Observatory}
  alias Shoestring.Trajectory.TrajectoryEvent
  @now Shoestring.Test.FixedClock.now()

  setup do
    previous_clock = Application.get_env(:shoestring, :dispatch_clock)
    Application.put_env(:shoestring, :dispatch_clock, Shoestring.Test.FixedClock)

    on_exit(fn ->
      if previous_clock,
        do: Application.put_env(:shoestring, :dispatch_clock, previous_clock),
        else: Application.delete_env(:shoestring, :dispatch_clock)
    end)

    assert {:ok, _} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{
               "claude_models" => "fixture-claude"
             })

    attrs = Shoestring.ConfigurationFixtures.agent_attrs()

    roles =
      Enum.map(
        attrs["roles"],
        &Map.merge(&1, %{"provider" => "claude", "model" => "fixture-claude"})
      )

    assert {:ok, agent} = AgentProfiles.create(Map.put(attrs, "roles", roles))
    assert {:ok, profile} = AgentProfiles.snapshot_by_id(agent.id)
    goal = Shoestring.Test.CobblerHelpers.create_goal!()
    revision = propose_and_approve!(goal)

    assert {:ok, result} =
             ExecutionControl.start(goal.id, %{
               revision_number: 1,
               digest: revision.digest,
               repository_path: File.cwd!(),
               requested_by: "human:operator",
               agent_profile: Map.put(profile, "role", "Worker")
             })

    task = Enum.find(chain_plan()["tasks"], &(&1["id"] == "alpha"))
    %{goal: goal, execution: result.execution, task: task}
  end

  defp confirmation(c, changes \\ %{}) do
    Map.merge(
      %{
        execution_id: c.execution.execution_id,
        task_id: "alpha",
        attempt: 1,
        scope: "subscription",
        command_id: Ecto.UUID.generate(),
        requested_by: "human:operator"
      },
      changes
    )
  end

  defp observe!(payload \\ %{}, changes \\ %{}) do
    {:ok, snapshot} =
      Capacity.normalize(:claude, :interactive_status_line, payload,
        version: "2.1.251",
        now: @now,
        captured_at: @now,
        scope: "subscription"
      )

    snapshot = struct!(snapshot, changes)
    assert {:ok, _, _} = Observatory.ingest(snapshot, now: @now)
  end

  test "one explicit task confirmation admits real unknown telemetry once, without inventing capacity",
       c do
    observe!()

    assert {:error, {:execution_admission_blocked, _}} =
             ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 1)

    assert {:ok, confirmation} = ExecutionControl.confirm_capacity(c.goal.id, confirmation(c))
    assert {:ok, id} = ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 1)
    decision = Repo.get!(TrajectoryEvent, id)
    assert decision.payload["result"] == "admit"
    assert decision.payload["reason_code"] =~ "confirmed_"
    assert decision.payload["observation"]["confidence"] == "none"
    assert decision.payload["override"]["confirmed_by"] == "human:operator"
    assert decision.payload["extensions"][PlanCapacityConfirmation.extension()] == confirmation.id

    assert {:error, {:execution_admission_blocked, _}} =
             ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 1)

    assert {:error, {:execution_admission_blocked, _}} =
             ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 2)

    assert {:error, {:execution_admission_blocked, _}} =
             ExecutionAdmission.admit(c.goal.id, c.execution, %{c.task | "id" => "beta"}, 1)

    assert run_count(c.goal.id) == 0
    assert {:ok, %{consistent?: true}} = Shoestring.Cobbler.Plans.rebuild(c.goal.id)
  end

  test "confirmation is inert, exact and safely replayed", c do
    attrs = confirmation(c)
    assert {:ok, event} = ExecutionControl.confirm_capacity(c.goal.id, attrs)
    assert {:ok, same} = ExecutionControl.confirm_capacity(c.goal.id, attrs)
    assert same.id == event.id

    assert {:error, :capacity_confirmation_mismatch} =
             ExecutionControl.confirm_capacity(c.goal.id, %{attrs | requested_by: "human:other"})

    assert Repo.aggregate(
             from(e in TrajectoryEvent,
               where: e.goal_id == ^c.goal.id and e.type == "cobbler.plan.capacity.confirmed"
             ),
             :count
           ) == 1

    assert run_count(c.goal.id) == 0
    assert {:ok, %{total_attempts: 0}} = ExecutionControl.status(c.goal.id)
  end

  test "confirmation cannot cross execution, task readiness, attempt, scope or human attribution",
       c do
    for changes <- [
          %{execution_id: Ecto.UUID.generate()},
          %{task_id: "beta"},
          %{attempt: 2},
          %{scope: "other"},
          %{requested_by: "system:planner"}
        ] do
      assert {:error, :capacity_confirmation_mismatch} =
               ExecutionControl.confirm_capacity(c.goal.id, confirmation(c, changes))
    end

    assert Repo.aggregate(
             from(e in TrajectoryEvent,
               where: e.goal_id == ^c.goal.id and e.type == "cobbler.plan.capacity.confirmed"
             ),
             :count
           ) == 0
  end

  test "known reserve breaches remain blocked and consume the single decision", c do
    for {five, weekly, reason} <- [
          {80, 15, "reserve_breach_five_hour"},
          {15, 90, "reserve_breach_weekly"}
        ] do
      observe!(%{
        "rate_limits" => %{
          "five_hour" => %{
            "used_percentage" => five,
            "resets_at" => DateTime.to_unix(DateTime.add(@now, 18_000))
          },
          "seven_day" => %{
            "used_percentage" => weekly,
            "resets_at" => DateTime.to_unix(DateTime.add(@now, 604_800))
          }
        }
      })

      assert {:ok, confirmation} = ExecutionControl.confirm_capacity(c.goal.id, confirmation(c))

      assert {:error, {:execution_admission_blocked, ^reason}} =
               ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 1)

      assert is_nil(
               PlanCapacityConfirmation.available(
                 c.goal.id,
                 c.execution,
                 c.task,
                 1,
                 "subscription"
               )
             )

      assert Repo.exists?(
               from(e in TrajectoryEvent,
                 where:
                   e.goal_id == ^c.goal.id and e.type == "admission.decided" and
                     fragment(
                       "json_extract(?, '$.extensions.\"shoestring.plan:capacity_confirmation_id\"')",
                       e.payload
                     ) == ^confirmation.id
               )
             )
    end
  end

  test "hard refusal and incompatible telemetry cannot be confirmed away", c do
    for changes <- [%{capacity_state: :refused}, %{compatibility_state: :incompatible}] do
      observe!(%{}, changes)
      assert {:ok, _} = ExecutionControl.confirm_capacity(c.goal.id, confirmation(c))

      assert {:error, {:execution_admission_blocked, _}} =
               ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 1)
    end

    assert run_count(c.goal.id) == 0
  end

  test "canonical event schema refuses forged nonhuman confirmation", c do
    assert {:ok, event} = ExecutionControl.confirm_capacity(c.goal.id, confirmation(c))

    assert {:error, _} =
             Trajectory.append(c.goal.id, %{
               type: event.type,
               schema_version: 1,
               actor: "planner",
               payload: Map.put(event.payload, "confirmed_by", "model:planner")
             })
  end

  test "concurrent evaluators cannot mint two decisions from one confirmation", c do
    observe!()
    assert {:ok, confirmation} = ExecutionControl.confirm_capacity(c.goal.id, confirmation(c))
    supervisor = start_supervised!(Task.Supervisor)

    tasks =
      for _ <- 1..2 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          receive do
            :evaluate -> ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 1)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :evaluate))
    outcomes = Enum.map(tasks, &Task.await(&1, 15_000))
    assert Enum.any?(outcomes, &match?({:ok, _}, &1))

    decisions =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^c.goal.id and e.type == "admission.decided"
      )

    matching =
      Enum.filter(
        decisions,
        &(get_in(&1.payload, ["extensions", PlanCapacityConfirmation.extension()]) ==
            confirmation.id)
      )

    assert [decision] = matching
    assert decision.payload["result"] == "admit"

    assert Enum.all?(outcomes, fn
             {:ok, id} -> id == decision.id
             {:error, {:execution_admission_blocked, _}} -> true
             _ -> false
           end)
  end
end
