defmodule Shoestring.Cobbler.PlanFanoutReviewTest do
  @moduledoc """
  Cross-review of fan-out children: real sibling worktrees and real
  sandboxed format gates, the fixture reviewer, no provider. Each child is
  reviewed on its own; a blocked child is replaced by the fan-out
  coordinator with its findings while an approved sibling stays accepted.
  """
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers

  alias Shoestring.Cobbler.{PlanExecutor, PlanFanout, PlanReview}
  alias Shoestring.Cobbler.Review.{Fixture, Record}
  alias Shoestring.Trajectory.TrajectoryEvent
  alias Shoestring.Worktrees

  @human "human:fanout-review"

  test "each child is reviewed alone; a blocked child is replaced with its findings, the sibling stays accepted" do
    c = fixture(reconciliation_opts: [group_probe: fn _ -> :absent end])

    opts =
      Keyword.put(c.opts, :review_config,
        enabled: true,
        adapter: :fixture,
        model: "fixture-reviewer"
      )

    assert {:ok, %{dispatched: [north, south]}} = PlanFanout.dispatch_ready(c.goal.id, opts)

    commit_in!(
      north,
      c,
      "lib/north.ex",
      "defmodule North do\n  # #{Fixture.marker()} empty module\nend\n"
    )

    commit_in!(south, c, "lib/south.ex", "defmodule South do\n  def ok, do: :ok\nend\n")
    complete_child!(c.goal, north.run_id)
    complete_child!(c.goal, south.run_id)

    for child <- [north, south] do
      assert {:ok, %{reason: :review_held}} =
               PlanExecutor.complete_task_run(c.goal.id, child.run_id, opts)

      confirm!(c, child)
    end

    assert {:ok, %{disposition: :accepted}} =
             PlanExecutor.complete_task_run(c.goal.id, south.run_id, opts)

    assert {:ok, %{disposition: :review_blocked, retry_state: "retry"}} =
             PlanExecutor.complete_task_run(c.goal.id, north.run_id, opts)

    # Each packet holds only its own child's change.
    assert Jason.decode!(record!(south).packet_json)["changed_files"] == [
             %{"path" => "lib/south.ex", "status" => "M"}
           ]

    assert Jason.decode!(record!(north).packet_json)["changed_files"] == [
             %{"path" => "lib/north.ex", "status" => "M"}
           ]

    assert [%{"gate" => "mix_format_check", "sandbox" => "macos_seatbelt:v1:" <> _}] =
             record!(north).gates["items"]

    assert {:ok, status} = PlanExecutor.status(c.goal.id, opts)
    assert status.accepted == ["south"]
    blocked = Enum.find(status.children, &(&1.run_id == north.run_id))
    assert blocked.resolution == :gate_failed
    assert blocked.retry_state == "retry"
    refute status.needs_user?

    # The coordinator replaces only the blocked child; its prompt carries the
    # findings and says it starts from the approved base.
    assert {:ok, %{dispatched: [replacement]}} = PlanFanout.dispatch_ready(c.goal.id, opts)
    assert replacement.plan_task_id == "north"
    assert replacement.attempt == 2
    {:ok, wt} = Worktrees.get(replacement.run_id, opts)
    assert wt.base_commit == c.base

    prompt = prompt!(c.goal.id, replacement.run_id)
    assert prompt =~ "Cross-review of attempt 1"

    assert prompt =~
             "starts from the approved base, not the reviewed commit #{record!(north).commit}"

    assert prompt =~ "empty module"
  end

  defp commit_in!(child, c, file, content) do
    {:ok, %{path: path}} = Worktrees.get(child.run_id, c.opts)
    File.write!(Path.join(path, file), content)

    git!(path, ["-c", "commit.gpgsign=false", "commit", "-qam", "Implement #{child.plan_task_id}"])
  end

  defp confirm!(c, child) do
    assert {:ok, _} =
             PlanReview.confirm(c.goal.id,
               review_id: record!(child).id,
               confirmation_id: Ecto.UUID.generate(),
               confirmed_by: @human
             )
  end

  defp record!(child), do: Repo.get_by!(Record, run_id: child.run_id)

  defp prompt!(goal_id, run_id) do
    event =
      Repo.one!(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type == "run.requested" and e.run_id == ^run_id,
          limit: 1
      )

    event.payload["prompt"]
  end
end
