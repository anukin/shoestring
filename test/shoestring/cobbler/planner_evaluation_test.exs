defmodule Shoestring.Cobbler.PlannerEvaluationTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Cobbler.Planner.Evaluation

  test "three pinned repository goals compare without claiming semantic or execution success" do
    assert Evaluation.cases() == ["catalog", "greeting", "receipt"]

    for case_id <- Evaluation.cases() do
      assert {:ok, context} = Evaluation.context(case_id)
      assert {:ok, json} = Evaluation.reference(case_id)
      assert context["digest"] == PlanContract.digest(Map.delete(context, "digest"))
      assert context["repository_files"]["pantry.py"] =~ "def greeting(name):"
      assert Enum.all?(Map.keys(context["repository_files"]), &String.ends_with?(&1, ".py"))

      assert context["goal_contract"]["acceptance"]["gates"] |> hd() |> Map.get("gate") ==
               "python_unittest"

      assert context["output_schema"]["properties"]["goal"]["const"] == context["goal_contract"]
      assert {:ok, report} = Evaluation.compare(case_id, json)
      assert report["candidate"]["schema_status"] == "valid"
      assert report["candidate"]["digest"] == report["reference"]["digest"]
      assert report["candidate"]["paths_absent_from_snapshot"] == []
      assert report["reference_review_status"] == "user_approved_with_language_change"

      assert report["reference_review_note"] =~
               "converted bytes were not separately human-reviewed"

      assert report["quality_verdict"] == "UNVERIFIED"
      assert report["execution"] == %{"status" => "not_run", "evidence" => []}
      assert report["semantic_review"]["status"] == "unreviewed"
      assert length(report["semantic_review"]["criteria"]) == 7
      assert Enum.all?(report["semantic_review"]["criteria"], &(&1["score"] == nil))
      assert report["candidate_output_digest"] =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  test "comparison records task costs and flags absent paths without calling them hallucinations" do
    plan = reference_plan("receipt")
    [total, receipt] = plan["tasks"]

    changed =
      put_in(plan, ["tasks"], [
        put_in(total, ["hints", "files"], ["pantry.py", "new_total.py"]),
        receipt
      ])

    assert {:ok, report} = Evaluation.compare("receipt", Jason.encode!(changed))
    assert report["candidate"]["schema_status"] == "valid"
    assert report["candidate"]["paths_absent_from_snapshot"] == ["new_total.py"]
    assert report["candidate"]["metrics"]["task_count"] == 2
    assert report["candidate"]["metrics"]["dependency_edges"] == 1
    assert report["candidate"]["metrics"]["sequential_task_transitions"] == 1
    assert report["candidate"]["metrics"]["declared_attempts"] == 4
    assert report["candidate"]["metrics"]["declared_task_seconds"] == 1200
    refute report["candidate"]["digest"] == report["reference"]["digest"]
    assert report["quality_verdict"] == "UNVERIFIED"
  end

  test "valid-looking goal changes, supplied provenance and embedded commands are unsafe" do
    plan = reference_plan("greeting")

    for changed <- [
          put_in(plan, ["goal", "statement"], "Replace the goal"),
          Map.put(plan, "planner", %{"identity" => "fake", "version" => "1"}),
          Map.put(plan, "command", "never execute this")
        ] do
      assert {:ok, report} = Evaluation.compare("greeting", Jason.encode!(changed))
      assert report["candidate"]["schema_status"] == "unsafe_proposal"
      assert report["candidate"]["metrics"] == nil
      assert report["execution"]["status"] == "not_run"
    end
  end

  test "cyclic, ungated, malformed and oversized proposals retain explicit failure evidence" do
    receipt = reference_plan("receipt")
    [total, render] = receipt["tasks"]
    cycle = Map.put(receipt, "tasks", [Map.put(total, "depends_on", ["receipt"]), render])
    ungated = Map.put(receipt, "tasks", [Map.put(total, "gates", []), render])

    for json <- [
          Jason.encode!(cycle),
          Jason.encode!(ungated),
          "{",
          "[]",
          String.duplicate(" ", 65_537)
        ] do
      assert {:ok, report} = Evaluation.compare("receipt", json)
      assert report["candidate"]["schema_status"] == "schema_failed"
      assert report["candidate"]["error_codes"] != []
      assert report["candidate"]["metrics"] == nil
      assert report["quality_verdict"] == "UNVERIFIED"
    end
  end

  test "rejected content is not echoed while useful validation evidence remains" do
    plan = reference_plan("greeting")
    secret = "sk-" <> String.duplicate("Synthetic", 8)
    json = Jason.encode!(Map.put(plan, "command", secret))
    assert {:ok, report} = Evaluation.compare("greeting", json)
    rendered = Jason.encode!(report)
    refute rendered =~ secret
    refute Map.has_key?(report["candidate"], "command")
    assert report["candidate"]["error_codes"] == ["embedded_command"]
    assert report["reference"]["metrics"]["task_count"] == 1
    assert report["context_digest"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "unknown cases and unreadable files fail closed" do
    assert {:error, :unknown_case} = Evaluation.context("../greeting")
    assert {:error, :unknown_case} = Evaluation.reference("missing")
    assert {:error, :invalid_case} = Evaluation.compare("missing", "{}")

    assert {:error, :unreadable_or_oversized_file} =
             Evaluation.read_file("missing-eval-file.json")
  end

  @tag :tmp_dir
  test "file input is bounded before decoding and preserves in-bound content", %{tmp_dir: dir} do
    file = Path.join(dir, "proposal.json")
    File.write!(file, String.duplicate(" ", PlanContract.max_plan_bytes()))
    assert {:ok, json} = Evaluation.read_file(file)
    assert byte_size(json) == PlanContract.max_plan_bytes()
    File.write!(file, String.duplicate(" ", PlanContract.max_plan_bytes() + 1))
    assert {:error, :unreadable_or_oversized_file} = Evaluation.read_file(file)
  end

  defp reference_plan(case_id) do
    {:ok, json} = Evaluation.reference(case_id)
    Jason.decode!(json)
  end
end
