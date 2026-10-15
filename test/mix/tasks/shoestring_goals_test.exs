defmodule Mix.Tasks.Shoestring.GoalsTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.Observatory
  alias Shoestring.Trajectory.Goal

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  defp run_json!(args) do
    Mix.Tasks.Shoestring.Goals.run(args)
    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  test "create records an active goal that the plans CLI accepts" do
    created =
      run_json!([
        "create",
        "--title",
        "Ship the parser",
        "--description",
        "Parse the log format."
      ])

    assert %{
             "id" => id,
             "title" => "Ship the parser",
             "description" => "Parse the log format.",
             "status" => "active"
           } = created

    assert %Goal{title: "Ship the parser", status: "active", owner_id: owner_id} =
             Repo.get!(Goal, id)

    assert {:ok, _} = Ecto.UUID.cast(owner_id)

    # The goal ID is what `mix shoestring.plans` takes as GOAL.
    Mix.Tasks.Shoestring.Plans.run(["list", id])
    assert_receive {:mix_shell, :info, [json]}
    assert %{"goal_id" => ^id, "revisions" => []} = Jason.decode!(json)
  end

  test "list prints user goals newest first, without the observatory goal" do
    {:ok, _} = Observatory.ensure_provisioned()
    %{"id" => first} = run_json!(["create", "--title", "First"])
    %{"id" => second} = run_json!(["create", "--title", "Second"])

    ids = run_json!(["list"]) |> Enum.map(& &1["id"])

    assert ids == [second, first]
    refute Observatory.observatory_goal_id() in ids
  end

  test "invalid or incomplete arguments create nothing" do
    for args <- [
          [],
          ["create"],
          ["create", "--title"],
          ["create", "--title", "x", "--status", "completed"],
          ["list", "--title", "x"],
          ["delete", "--title", "x"]
        ] do
      assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
        Mix.Tasks.Shoestring.Goals.run(args)
      end
    end

    assert_raise Mix.Error, ~r/title/, fn ->
      Mix.Tasks.Shoestring.Goals.run(["create", "--title", ""])
    end

    assert Repo.aggregate(Goal.user_goals(), :count) == 0
  end
end
