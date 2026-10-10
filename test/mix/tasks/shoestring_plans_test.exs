defmodule Mix.Tasks.Shoestring.PlansTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{PlanDecisionRecord, Planner, Plans}
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Trajectory.TrajectoryEvent
  import Shoestring.Test.CobblerHelpers, only: [create_goal!: 0]
  import Shoestring.Test.PlanFixtures

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    %{goal: create_goal!()}
  end

  defp cli(args) do
    Mix.Tasks.Shoestring.Plans.run(args)
    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  defp file!(content) do
    path = Path.join(Shoestring.State.root(), "plan-#{System.unique_integer([:positive])}.json")
    File.write!(path, if(is_binary(content), do: content, else: Jason.encode!(content)))
    path
  end

  defp propose!(goal) do
    cli([
      "propose",
      goal.id,
      "--file",
      file!(plan()),
      "--request-id",
      "proposal-1",
      "--by",
      "human:operator"
    ])
  end

  defp decision_args(command, goal, number, digest, id, extra \\ []) do
    [
      command,
      goal.id,
      "--revision",
      to_string(number),
      "--digest",
      digest,
      "--request-id",
      id,
      "--by",
      "human:operator"
    ] ++ extra
  end

  test "propose, list, ordered review and export remain inert", %{goal: goal} do
    result = propose!(goal)
    assert result["revision"]["status"] == "proposed"
    assert result["decision"] == nil
    assert result["outcome"] == "recorded"
    revision = Plans.get_revision(goal.id, 1)

    assert cli(["list", goal.id])["revisions"] == [result["revision"]]
    shown = cli(["show", goal.id])
    assert shown["plan"] == revision.content
    assert Enum.map(shown["ordered_tasks"], & &1["id"]) == ["survey", "widen", "narrow", "verify"]
    assert Enum.at(shown["ordered_tasks"], 3)["depends_on"] == ["widen", "narrow"]
    assert shown["planner"]["state"] == "not_requested"
    assert cli(["export", goal.id, "--revision", "1"]) == revision.content
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(RunRecord, :count) == 0
    assert Repo.aggregate(PlanDecisionRecord, :count) == 0
  end

  test "initial planner CLI stores an inert contract then generates a reviewable unapproved candidate",
       %{goal: target} do
    previous = Application.fetch_env(:shoestring, :planner)

    Application.put_env(
      :shoestring,
      :planner,
      Shoestring.Test.PlannerFixtures.config([{:ok, Jason.encode!(plan()), 12}])
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:shoestring, :planner, value)
        :error -> Application.delete_env(:shoestring, :planner)
      end
    end)

    arguments = [
      "request",
      target.id,
      "--file",
      file!(goal()),
      "--request-key",
      "cli-initial",
      "--by",
      "human:operator"
    ]

    pending = cli(arguments)
    assert pending["planner"]["state"] == "pending"
    assert pending["planner"]["attempts"] == 0
    assert cli(arguments)["outcome"] == "replayed"
    refute_receive {:planner_input, _}
    assert cli(["generate", target.id, "--request-key", "cli-initial"])["outcome"] == "blocked"
    refute_receive {:planner_input, _}
    now = DateTime.utc_now()

    assert {:ok, :persisted, _} =
             Shoestring.Harness.Observatory.ingest(Shoestring.Test.PlannerFixtures.snapshot(now),
               now: now
             )

    candidate = cli(["generate", target.id, "--request-key", "cli-initial"])
    assert candidate["planner"]["state"] == "ready"
    assert candidate["planner"]["candidate"]["tasks"] == plan()["tasks"]
    assert candidate["planner"]["charged_output_tokens"] == 4096
    assert_receive {:planner_input, _}
    assert cli(["generate", target.id, "--request-key", "cli-initial"])["outcome"] == "replayed"
    refute_receive {:planner_input, _}
    assert Plans.list_revisions(target.id) == []
    assert Plans.authority(target.id) == nil
    assert Repo.aggregate(RunRecord, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "initial goal files and non-human requesters fail without persisting or echoing input", %{
    goal: target
  } do
    for contents <- [
          "{secret-fixture",
          "[]",
          "",
          String.duplicate("x", Shoestring.Cobbler.PlanContract.max_plan_bytes() + 1),
          Map.put(goal(), "shell", "secret-fixture")
        ] do
      error =
        assert_raise Mix.Error, fn ->
          cli([
            "request",
            target.id,
            "--file",
            file!(contents),
            "--request-key",
            "bad",
            "--by",
            "human:operator"
          ])
        end

      refute Exception.message(error) =~ "secret-fixture"
    end

    assert Planner.get(target.id) == nil
    previous = Application.fetch_env(:shoestring, :planner)
    Application.put_env(:shoestring, :planner, Shoestring.Test.PlannerFixtures.config([]))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:shoestring, :planner, value)
        :error -> Application.delete_env(:shoestring, :planner)
      end
    end)

    assert_raise Mix.Error, ~r/non_human_planner_request/, fn ->
      cli([
        "request",
        target.id,
        "--file",
        file!(goal()),
        "--request-key",
        "bad",
        "--by",
        "model:fixture"
      ])
    end

    assert Planner.get(target.id) == nil
    assert Repo.aggregate(TrajectoryEvent, :count) == 0
  end

  test "edits preserve approved content, require another approval and replay safely", %{
    goal: goal
  } do
    propose!(goal)
    first = Plans.get_revision(goal.id, 1)
    approved = cli(decision_args("approve", goal, 1, first.digest, "approve-1"))
    assert approved["revision"]["status"] == "approved"

    changed_tasks =
      tasks()
      |> Enum.map(fn task ->
        if task["id"] == "narrow" do
          Map.merge(task, %{
            "outcome" => "A reviewed outcome with evidence.",
            "depends_on" => ["widen"],
            "acceptance_criteria" => ["The updated criterion is satisfied."],
            "checkpoint" => %{
              "condition" => "Updated gate passed.",
              "evidence" => ["Gate result"]
            }
          })
        else
          task
        end
      end)

    edited_plan =
      plan(%{
        "tasks" => changed_tasks,
        "goal" => goal(%{"non_goals" => ["No parallel execution."]})
      })

    args = [
      "edit",
      goal.id,
      "--revision",
      "1",
      "--digest",
      first.digest,
      "--file",
      file!(edited_plan),
      "--request-id",
      "edit-1",
      "--by",
      "human:operator"
    ]

    edited = cli(args)
    assert edited["revision"]["revision_number"] == 2
    assert edited["revision"]["parent_revision_number"] == 1
    assert edited["revision"]["status"] == "proposed"
    assert Plans.authority(goal.id).revision_number == 1
    assert Plans.get_revision(goal.id, 1).content == first.content
    assert Plans.get_revision(goal.id, 1).digest == first.digest
    assert cli(args)["outcome"] == "replayed"
    assert length(Plans.list_revisions(goal.id)) == 2

    assert cli(["show", goal.id])["plan"]["goal"]["non_goals"] == ["No parallel execution."]
    assert cli(["show", goal.id, "--revision", "1"])["plan"] == first.content

    second = Plans.get_revision(goal.id, 2)
    cli(decision_args("approve", goal, 2, second.digest, "approve-2"))
    assert Plans.get_revision(goal.id, 1).status == "superseded"
    assert Plans.authority(goal.id).revision_number == 2
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(RunRecord, :count) == 0
  end

  test "approve and reject require exact digest and preserve recorded decisions", %{goal: goal} do
    propose!(goal)
    first = Plans.get_revision(goal.id, 1)

    args =
      decision_args("reject", goal, 1, first.digest, "reject-1", [
        "--reason",
        "Needs a narrower outcome."
      ])

    assert cli(args)["revision"]["status"] == "rejected"
    assert cli(args)["outcome"] == "replayed"
    shown = cli(["show", goal.id])
    assert shown["decision"]["reason"] == "Needs a narrower outcome."
    assert shown["decision"]["decided_by"] == "human:operator"
    assert shown["decision"]["bound_digest"] == first.digest
    assert Plans.authority(goal.id) == nil

    assert_raise Mix.Error, ~r/plan_decision_conflict/, fn ->
      cli(decision_args("approve", goal, 1, first.digest, "reject-1"))
    end

    assert Repo.aggregate(PlanDecisionRecord, :count) == 1
  end

  test "retirement review exposes the reason and required tasks before approval", %{goal: goal} do
    propose!(goal)
    first = Plans.get_revision(goal.id, 1)
    cli(decision_args("approve", goal, 1, first.digest, "approve-1"))

    retirement = %{
      "task_id" => "verify",
      "reason" => "This final task is outside the revised scope."
    }

    result =
      cli([
        "edit",
        goal.id,
        "--revision",
        "1",
        "--digest",
        first.digest,
        "--file",
        file!(plan(%{"retirements" => [retirement]})),
        "--request-id",
        "retire-verify",
        "--by",
        "human:operator"
      ])

    assert result["revision"]["status"] == "proposed"
    shown = cli(["show", goal.id])
    assert shown["retirements"] == [retirement]
    assert shown["required_task_ids"] == ["survey", "widen", "narrow"]
    assert Enum.map(shown["ordered_tasks"], & &1["id"]) == ["survey", "widen", "narrow", "verify"]
    assert Plans.authority(goal.id).revision_number == 1
    assert Repo.aggregate(RunRecord, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "CLI requests, generates and adopts an amendment without approving or dispatching", %{
    goal: goal
  } do
    alias Shoestring.Test.PlannerFixtures
    previous = Application.get_env(:shoestring, :planner)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shoestring, :planner, previous),
        else: Application.delete_env(:shoestring, :planner)
    end)

    Application.put_env(
      :shoestring,
      :planner,
      PlannerFixtures.config([{:ok, Jason.encode!(plan()), 10}])
    )

    propose!(goal)
    first = Plans.get_revision(goal.id, 1)
    cli(decision_args("approve", goal, 1, first.digest, "approve-1"))
    now = DateTime.utc_now()

    assert {:ok, :persisted, _} =
             Shoestring.Harness.Observatory.ingest(PlannerFixtures.snapshot(now), now: now)

    args = [
      "replan",
      goal.id,
      "--revision",
      "1",
      "--digest",
      first.digest,
      "--request-key",
      "cli-amendment",
      "--by",
      "human:operator",
      "--reason",
      "Review unfinished decomposition."
    ]

    pending = cli(args)
    assert pending["planner"]["state"] == "pending"
    assert pending["planner"]["amendment"]["plan_digest"] == first.digest
    assert pending["planner"]["attempts"] == 0
    candidate = cli(["generate-amendment", goal.id, "--request-key", "cli-amendment"])
    assert candidate["planner"]["state"] == "ready"
    assert candidate["planner"]["charged_output_tokens"] == 4096
    digest = candidate["planner"]["candidate_digest"]

    adopted =
      cli([
        "adopt",
        goal.id,
        "--request-key",
        "cli-amendment",
        "--digest",
        digest,
        "--by",
        "human:operator"
      ])

    assert adopted["revision"]["revision_number"] == 2
    assert adopted["revision"]["parent_revision_number"] == 1
    assert adopted["revision"]["status"] == "proposed"
    assert cli(args)["outcome"] == "replayed"
    assert Plans.authority(goal.id).revision_number == 1
    assert Repo.aggregate(RunRecord, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert {:ok, %{consistent?: true}} = Planner.rebuild(goal.id)
    assert_received {:planner_input, input}
    assert input["projection"]["amendment"]["plan_digest"] == first.digest
    refute_received {:planner_input, _}
  end

  test "stale digests refuse both decision paths and the edit path", %{goal: goal} do
    propose!(goal)
    digest = String.duplicate("f", 64)

    for command <- ["approve", "reject"] do
      extra = if command == "reject", do: ["--reason", "Rejected stale view."], else: []

      assert_raise Mix.Error, ~r/plan_digest_mismatch/, fn ->
        cli(decision_args(command, goal, 1, digest, "decision-#{command}", extra))
      end
    end

    assert_raise Mix.Error, ~r/Parent plan digest mismatch/, fn ->
      cli([
        "edit",
        goal.id,
        "--revision",
        "1",
        "--digest",
        digest,
        "--file",
        file!(plan()),
        "--request-id",
        "edit-stale",
        "--by",
        "human:operator"
      ])
    end

    assert Repo.aggregate(PlanDecisionRecord, :count) == 0
    assert length(Plans.list_revisions(goal.id)) == 1
  end

  test "invalid graph, missing criterion and unsafe gates are refused before persistence", %{
    goal: goal
  } do
    for {invalid, message} <- [
          {plan(%{"tasks" => [task("a", "A", ["b"]), task("b", "B", ["a"])]}), ~r/cycle/},
          {plan(%{"tasks" => [task("a", "A", [], %{"acceptance_criteria" => []})]}),
           ~r/acceptance_criteria/},
          {plan(%{
             "tasks" => [
               task("a", "A", [], %{"gates" => [%{"gate" => "shell", "command" => "echo unsafe"}]})
             ]
           }), ~r/validation|forbidden/}
        ] do
      assert_raise Mix.Error, message, fn ->
        cli([
          "propose",
          goal.id,
          "--file",
          file!(invalid),
          "--request-id",
          "invalid",
          "--by",
          "human:operator"
        ])
      end
    end

    assert Plans.list_revisions(goal.id) == []
    assert Repo.aggregate(TrajectoryEvent, :count) == 0
  end

  test "file errors, non-object JSON and oversized input fail without echoing input", %{
    goal: goal
  } do
    for path <- [
          file!(""),
          file!("[]"),
          file!("{secret-fixture"),
          file!(String.duplicate("a", Shoestring.Cobbler.PlanContract.max_plan_bytes() + 1)),
          "missing-plan.json"
        ] do
      error =
        assert_raise Mix.Error, fn ->
          cli([
            "propose",
            goal.id,
            "--file",
            path,
            "--request-id",
            "invalid-file",
            "--by",
            "human:operator"
          ])
        end

      refute Exception.message(error) =~ "secret-fixture"
    end

    assert Plans.list_revisions(goal.id) == []
  end

  test "unknown, duplicate, irrelevant and incomplete arguments fail", %{goal: goal} do
    for args <- [
          ["execute", goal.id],
          ["show", "bad-uuid"],
          ["list", goal.id, "--file", "x"],
          ["show", goal.id, "--revision", "0"],
          ["show", goal.id, "--revision", "1", "--revision", "2"],
          ["approve", goal.id, "--revision", "1"],
          ["reject", goal.id],
          ["propose", goal.id, "--file", "x", "--request-id", "", "--by", "human:operator"],
          ["show", goal.id, "--unknown", "x"]
        ] do
      assert_raise Mix.Error, ~r/Invalid arguments/, fn -> cli(args) end
    end

    assert_raise Mix.Error, ~r/Goal not found/, fn -> cli(["list", Ecto.UUID.generate()]) end
    assert_raise Mix.Error, ~r/revision not found/, fn -> cli(["show", goal.id]) end
  end

  test "manual and decision identities must be human; rejection reason is bounded", %{goal: goal} do
    assert_raise Mix.Error, ~r/non_human_identity/, fn ->
      cli([
        "propose",
        goal.id,
        "--file",
        file!(plan()),
        "--request-id",
        "non-human",
        "--by",
        "model:fixture"
      ])
    end

    propose!(goal)
    first = Plans.get_revision(goal.id, 1)

    for command <- ["approve", "reject"] do
      extra = if command == "reject", do: ["--reason", "Requires human review."], else: []
      args = decision_args(command, goal, 1, first.digest, command, extra)

      args =
        List.replace_at(args, Enum.find_index(args, &(&1 == "human:operator")), "model:fixture")

      assert_raise Mix.Error, ~r/non_human_identity/, fn -> cli(args) end
    end

    assert_raise Mix.Error, fn ->
      cli(
        decision_args("reject", goal, 1, first.digest, "too-long", [
          "--reason",
          String.duplicate("x", 501)
        ])
      )
    end

    assert Repo.aggregate(PlanDecisionRecord, :count) == 0
  end

  test "planner display retains bounded quota, tier and errors without starting inference", %{
    goal: goal
  } do
    opts = [config: [adapter: :ollama, model: "local-fixture", max_output_tokens: 128]]

    assert {:ok, _} =
             Planner.request(
               goal.id,
               %{request_key: "initial", requested_by: "human:operator", goal_contract: goal()},
               opts
             )

    before = Planner.get(goal.id)
    view = cli(["planner", goal.id])
    assert view["model"] == "local-fixture"
    assert view["support_tier"] == "reactive_only"
    assert view["attempts"] == 0
    assert view["max_attempts"] == 2
    assert view["charged_output_tokens"] == 0
    assert view["max_charged_output_tokens"] == 256
    assert view["remaining_output_allowance"] == 256
    assert view["next_attempt_output_allowance"] == 128
    assert view["candidate"] == nil
    assert view["errors"] == []
    refute Map.has_key?(view, "projection")
    refute Map.has_key?(view, "endpoint_digest")
    assert Planner.get(goal.id) == before
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "fixture candidate review and adoption preserve charges and require explicit approval", %{
    goal: goal
  } do
    supervisor = start_supervised!(Task.Supervisor)

    opts = [
      config: [
        adapter: :fixture,
        model: "fixture-v1",
        observer: self(),
        max_output_tokens: 128,
        responses: [{:ok, Jason.encode!(plan()), 12}]
      ],
      task_supervisor: supervisor,
      snapshot: nil,
      confirm_unknown_capacity: true
    ]

    assert {:ok, _} =
             Planner.request(
               goal.id,
               %{request_key: "initial", requested_by: "human:operator", goal_contract: goal()},
               opts
             )

    assert {:ok, %{request: row, outcome: :finished}} = Planner.generate(goal.id, "initial", opts)
    assert_receive {:planner_input, _}
    before = row
    view = cli(["planner", goal.id])
    assert view["state"] == "ready"
    assert view["attempts"] == 1
    assert view["charged_output_tokens"] == 128
    assert view["remaining_output_allowance"] == 128
    assert view["attempt_history"] |> hd() |> Map.fetch!("output_tokens") == 12
    assert view["candidate_digest"] == row.result_digest
    assert view["candidate"]["tasks"] == plan()["tasks"]

    assert_raise Mix.Error, ~r/stale_planner_digest/, fn ->
      cli([
        "adopt",
        goal.id,
        "--request-key",
        "initial",
        "--digest",
        String.duplicate("f", 64),
        "--by",
        "human:operator"
      ])
    end

    args = [
      "adopt",
      goal.id,
      "--request-key",
      "initial",
      "--digest",
      row.result_digest,
      "--by",
      "human:operator"
    ]

    adopted = cli(args)
    assert adopted["revision"]["status"] == "proposed"
    assert adopted["revision"]["digest"] == row.result_digest
    assert cli(args)["outcome"] == "replayed"
    assert Plans.authority(goal.id) == nil
    assert Planner.get(goal.id) == before
    refute_receive {:planner_input, _}
    assert Repo.aggregate(RunRecord, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "failed fixture validation remains visible without consuming the repair allowance", %{
    goal: goal
  } do
    supervisor = start_supervised!(Task.Supervisor)

    opts = [
      config: [
        adapter: :fixture,
        model: "fixture-v1",
        max_output_tokens: 128,
        responses: [{:ok, "{invalid", 4}]
      ],
      task_supervisor: supervisor,
      snapshot: nil,
      confirm_unknown_capacity: true
    ]

    assert {:ok, _} =
             Planner.request(
               goal.id,
               %{request_key: "initial", requested_by: "human:operator", goal_contract: goal()},
               opts
             )

    assert {:ok, %{request: row}} = Planner.generate(goal.id, "initial", opts)
    view = cli(["planner", goal.id])
    assert view["state"] == "schema_failed"
    assert view["errors"] |> hd() |> Map.fetch!("code") == "invalid_json"
    assert view["charged_output_tokens"] == 128
    assert view["remaining_output_allowance"] == 128
    assert view["candidate"] == nil
    assert Planner.get(goal.id) == row

    assert_raise Mix.Error, ~r/planner_result_not_ready/, fn ->
      cli([
        "adopt",
        goal.id,
        "--request-key",
        "initial",
        "--digest",
        String.duplicate("f", 64),
        "--by",
        "human:operator"
      ])
    end

    assert Plans.list_revisions(goal.id) == []
  end

  test "stored digest divergence refuses review, export and both decisions", %{goal: goal} do
    propose!(goal)
    first = Plans.get_revision(goal.id, 1)

    from(r in Shoestring.Cobbler.PlanRevisionRecord, where: r.id == ^first.id)
    |> Repo.update_all(set: [digest: String.duplicate("f", 64)])

    for args <- [
          ["show", goal.id],
          ["export", goal.id, "--revision", "1"],
          decision_args("approve", goal, 1, first.digest, "approve"),
          decision_args("reject", goal, 1, first.digest, "reject", [
            "--reason",
            "Invalid content."
          ])
        ] do
      assert_raise Mix.Error, ~r/inconsistent/, fn -> cli(args) end
    end

    assert Repo.aggregate(PlanDecisionRecord, :count) == 0
  end
end
