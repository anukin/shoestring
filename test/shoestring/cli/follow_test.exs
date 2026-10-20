defmodule Shoestring.CLI.FollowTest do
  @moduledoc """
  `follow` against scripted status and event sources and a real approved plan;
  prompts are answered through `Mix.Shell.Process`. Nothing runs or sleeps.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.CLI.Follow
  import Ecto.Query
  import Shoestring.Test.CobblerHelpers, only: [create_goal!: 0]
  import Shoestring.Test.PlanExecutorHelpers, only: [propose_and_approve!: 1]

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    goal = create_goal!()
    revision = propose_and_approve!(goal)
    %{goal: goal, revision: revision}
  end

  # Each call pops the next scripted value; the last one repeats.
  defp script(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)

    fn _goal_id, _cursor_or_nil ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)
    end
  end

  defp status_script(values) do
    pop = script(values)
    fn goal_id -> pop.(goal_id, nil) end
  end

  defp event(sequence, type, payload), do: %{sequence: sequence, type: type, payload: payload}

  defp running(c, extra \\ %{}) do
    {:ok,
     Map.merge(
       %{
         completed?: false,
         cancelled?: false,
         needs_user?: false,
         execution: %{execution_id: "exec-1", revision_number: c.revision.revision_number},
         accepted: [],
         attempts: %{},
         active_run_id: nil,
         last_admission: nil
       },
       extra
     )}
  end

  defp follow(c, opts) do
    Follow.run(
      c.goal.id,
      Keyword.merge(
        [
          by: "human:operator",
          sleep: fn -> :ok end,
          max_polls: 20,
          confirm: fn _, _ -> flunk("no confirmation expected") end
        ],
        opts
      )
    )
  end

  defp infos do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, :info, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  test "prints progress once, in order, and stops when the goal completes", c do
    events =
      script([
        [
          event(1, "cobbler.plan.execution.requested", %{}),
          event(2, "cobbler.plan.task.dispatched", %{"plan_task_id" => "alpha", "attempt" => 1}),
          event(3, "checkpoint.created", %{})
        ],
        [
          event(4, "run.completed", %{"run_id" => "r"}),
          event(5, "cobbler.plan.task.accepted", %{
            "plan_task_id" => "alpha",
            "commit" => String.duplicate("a", 40)
          }),
          event(6, "cobbler.plan.execution.completed", %{"commit" => String.duplicate("b", 40)})
        ],
        []
      ])

    status = status_script([running(c), {:ok, %{completed?: true}}])
    assert {:ok, :completed} = follow(c, events: events, status: status)

    assert infos() == [
             "Execution requested.",
             "Task alpha: started (attempt 1).",
             "  The worker finished; checking its work.",
             "Task alpha: accepted at aaaaaaaaaaaa.",
             "All checks passed at bbbbbbbbbbbb.",
             "Done."
           ]
  end

  test "a held attempt is confirmed once, only after the human says yes", c do
    test = self()

    held =
      running(c, %{
        last_admission: %{
          "result" => "require_confirmation",
          "decision_id" => "d1",
          "explanation" => "Capacity is unknown."
        }
      })

    confirm = fn goal_id, attrs ->
      send(test, {:confirmed, goal_id, attrs})
      {:ok, %{}}
    end

    send(self(), {:mix_shell_input, :prompt, "y"})

    assert {:ok, :completed} =
             follow(c,
               events: script([[]]),
               status: status_script([held, held, held, {:ok, %{completed?: true}}]),
               confirm: confirm
             )

    goal_id = c.goal.id
    assert_received {:confirmed, ^goal_id, attrs}
    assert attrs.task_id == "alpha"
    assert attrs.attempt == 1
    assert attrs.execution_id == "exec-1"
    assert attrs.scope == "subscription"
    assert attrs.requested_by == "human:operator"
    assert {:ok, _} = Ecto.UUID.cast(attrs.command_id)
    refute_received {:confirmed, _, _}
    assert "Task alpha is held: Capacity is unknown." in infos()
  end

  test "declining leaves the attempt held and records nothing", c do
    held =
      running(c, %{
        last_admission: %{
          "result" => "require_confirmation",
          "decision_id" => "d1",
          "explanation" => "x"
        }
      })

    send(self(), {:mix_shell_input, :prompt, "n"})
    assert {:ok, :held} = follow(c, events: script([[]]), status: status_script([held]))
  end

  test "work that needs a human decision, or was cancelled, ends following with directions", c do
    assert {:ok, :needs_user} =
             follow(c,
               events: script([[]]),
               status:
                 status_script([
                   running(c, %{needs_user?: true, global_failure: %{"reason" => "budget"}})
                 ])
             )

    lines = infos()
    assert "The work needs you:" in lines
    assert Enum.any?(lines, &String.contains?(&1, "mix shoestring.execution status #{c.goal.id}"))

    assert {:ok, :cancelled} =
             follow(c,
               events: script([[]]),
               status: status_script([{:ok, %{completed?: false, cancelled?: true}}])
             )
  end

  test "a gate that could not be sandboxed is not reported as failed checks" do
    failed = %{"plan_task_id" => "add", "gate" => "python_unittest"}

    assert Follow.line(%{
             type: "cobbler.plan.task.gate_failed",
             payload:
               Map.put(failed, "reason", "{:gate_unavailable, %{reason: :no_sandbox_mechanism}}")
           }) ==
             "Task add: checks could not run in a sandbox (python_unittest: no_sandbox_mechanism); needs your decision."

    assert Follow.line(%{
             type: "cobbler.plan.task.gate_failed",
             payload: Map.put(failed, "reason", "{:gate_failed, %{exit_status: 1}}")
           }) == "Task add: checks failed (python_unittest)."
  end

  test "an admitted or running task is never prompted for", c do
    admitted = running(c, %{last_admission: %{"result" => "admit", "decision_id" => "d2"}})

    running_held =
      running(c, %{
        active_run_id: "r",
        last_admission: %{"result" => "require_confirmation", "decision_id" => "d3"}
      })

    assert {:ok, :stopped} =
             follow(c,
               events: script([[]]),
               status: status_script([admitted, running_held]),
               max_polls: 3
             )
  end

  test "from_execution starts at the latest execution request", c do
    last =
      Shoestring.Repo.one(
        from e in Shoestring.Trajectory.TrajectoryEvent,
          where: e.goal_id == ^c.goal.id,
          select: max(e.sequence)
      ) || 0

    # Inserted directly: only its type and sequence matter here.
    Shoestring.Repo.insert!(%Shoestring.Trajectory.TrajectoryEvent{
      goal_id: c.goal.id,
      sequence: last + 5,
      type: "cobbler.plan.execution.requested",
      actor: "test",
      occurred_at: DateTime.utc_now(),
      schema_version: 1,
      payload: %{}
    })

    test = self()

    events = fn _goal, cursor ->
      send(test, {:cursor, cursor})
      []
    end

    assert {:ok, :completed} =
             follow(c,
               events: events,
               status: status_script([{:ok, %{completed?: true}}]),
               from_execution: true
             )

    assert_received {:cursor, cursor}

    expected = last + 4

    assert cursor == expected

    assert {:ok, :completed} =
             follow(c, events: events, status: status_script([{:ok, %{completed?: true}}]))

    assert_received {:cursor, 0}
  end
end
