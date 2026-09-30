defmodule ShoestringWeb.CobblerQuotaPresentationTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.GoalLifecycle
  alias Shoestring.Trajectory.TrajectoryEvent
  alias ShoestringWeb.CobblerPresentation

  test "producer checkpoints and quota terminal evidence preserve a deferred goal" do
    assert CobblerPresentation.derive_goal_state(quota_timeline()) == :sleeping
  end

  test "fresh admission and an authorized continuation finish the sleeping goal" do
    timeline =
      quota_timeline() ++
        events(
          [
            {"admission.decided", %{"result" => "admit"}},
            {"run.requested", %{}},
            {"run.starting", %{}},
            {"run.running", %{}},
            {"checkpoint.created", %{}},
            {"run.completed", %{}}
          ],
          20
        )

    assert CobblerPresentation.derive_goal_state(timeline) == :completed
  end

  test "a queued goal can report dispatch under its existing authorized claim" do
    assert GoalLifecycle.transition(:queued, :dispatch_started) == {:ok, :working}
  end

  test "fresh admitted renewals keep useful work and checkpointing in their current state" do
    assert GoalLifecycle.transition(:working, {:admission_decision, :admit}) == {:ok, :working}

    assert GoalLifecycle.transition(:checkpointing, {:admission_decision, :admit}) ==
             {:ok, :checkpointing}
  end

  test "ordinary failures remain terminal and unknown run events remain unknown" do
    assert CobblerPresentation.derive_goal_state(
             working_timeline() ++ events([{"run.failed", %{"error_category" => "unknown"}}], 10)
           ) == :failed

    assert CobblerPresentation.derive_goal_state(
             working_timeline() ++ events([{"run.future_state", %{}}], 10)
           ) == :unknown
  end

  defp quota_timeline do
    working_timeline() ++
      events(
        [
          {"admission.decided", %{"result" => "defer_until"}},
          {"checkpoint.created", %{}},
          {"run.pausing", %{}},
          {"run.suspended", %{}},
          {"checkpoint.created", %{}},
          {"run.failed", %{"error_category" => "quota_refused"}}
        ],
        10
      )
  end

  defp working_timeline do
    events([
      {"admission.decided", %{"result" => "admit"}},
      {"cobbler.claim.acquired", %{}},
      {"run.requested", %{}},
      {"run.starting", %{}},
      {"run.running", %{}}
    ])
  end

  defp events(specs, offset \\ 0) do
    specs
    |> Enum.with_index(offset)
    |> Enum.map(fn {{type, payload}, sequence} ->
      %TrajectoryEvent{type: type, payload: payload, sequence: sequence}
    end)
  end
end
