defmodule Mix.Tasks.Shoestring.DoTest do
  use Shoestring.DataCase, async: false

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  test "invalid arguments are refused before anything is recorded" do
    for {task, args} <- [
          {Mix.Tasks.Shoestring.Do, []},
          {Mix.Tasks.Shoestring.Do, ["  "]},
          {Mix.Tasks.Shoestring.Do, ["do it", "--yes"]},
          {Mix.Tasks.Shoestring.Follow, []},
          {Mix.Tasks.Shoestring.Follow, ["not-a-goal"]},
          {Mix.Tasks.Shoestring.Result, []},
          {Mix.Tasks.Shoestring.Result, ["goal", "extra"]}
        ] do
      assert_raise Mix.Error, fn -> task.run(args) end
    end

    assert Repo.aggregate(Shoestring.Trajectory.Goal.user_goals(), :count) == 0
  end

  test "refusals reach the user as directions, not terms" do
    plain = Path.join(System.tmp_dir!(), "shoestring-do-plain-#{Ecto.UUID.generate()}")
    File.mkdir_p!(plain)

    assert_raise Mix.Error, ~r/Not a Git repository/, fn ->
      Mix.Tasks.Shoestring.Do.run(["fix it", "--repo", plain])
    end

    assert_raise Mix.Error, ~r/has not completed yet/, fn ->
      Mix.Tasks.Shoestring.Result.run([Shoestring.Test.CobblerHelpers.create_goal!().id])
    end

    for reason <- [
          {:dirty_worktree, ["a.py"]},
          :no_gate_detected,
          :no_default_agent,
          :worker_model_required,
          :planner_not_configured,
          :service_unreachable,
          :service_uses_another_database
        ] do
      message = Mix.Tasks.Shoestring.Do.message(reason)
      refute message =~ "Refused:"
      refute message =~ "{"
    end
  end
end
