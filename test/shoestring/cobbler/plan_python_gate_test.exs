defmodule Shoestring.Cobbler.PlanPythonGateTest do
  use ExUnit.Case, async: false

  alias Shoestring.Cobbler.{GateProcess, PlanContract, PlanGate, PlanGateRunner}
  alias Shoestring.Cobbler.Planner.Evaluation

  test "Python gates require named tests and preserve the trusted executable" do
    gate = %{"gate" => "python_unittest", "test_paths" => ["test/test_greeting.py"]}
    assert {:ok, ^gate} = PlanGate.validate(gate, :gate)

    assert {:ok, ["python3", "-B", "-m", "unittest", "test/test_greeting.py"]} =
             PlanGate.argv(gate)

    assert {:error, _} = PlanGate.validate(%{"gate" => "python_unittest"}, :gate)

    assert {:error, _} =
             PlanGate.validate(%{"gate" => "python_unittest", "test_paths" => []}, :gate)

    assert {:error, _} =
             PlanGate.validate(
               %{gate | "test_paths" => List.duplicate("test/test_greeting.py", 17)},
               :gate
             )

    assert {:error, _} =
             PlanGate.validate(
               %{gate | "test_paths" => ["test/test_greeting.py", "test/test_greeting.py"]},
               :gate
             )
  end

  test "unsafe paths and parameters cannot reach the Python runner but valid references still can" do
    ctx = context("greeting")

    opts = [
      worktree_path: File.cwd!(),
      commit: String.duplicate("a", 40),
      runner: fn _, _, _ -> flunk("invalid gate reached the runner") end
    ]

    for paths <- [
          ["-c", "print('unsafe')"],
          ["--help"],
          ["/tmp/test_greeting.py"],
          ["test/../test_greeting.py"],
          ["test/test_greeting.py;echo unsafe"],
          ["test/test_greeting.py\n"],
          ["test/test_greeting.py --help"],
          ["test/greeting_test.exs"],
          ["test/test-greeting.py"],
          ["test/" <> String.duplicate("a", 200) <> "/test_greeting.py"],
          [nil],
          "test/test_greeting.py"
        ] do
      gate = %{"gate" => "python_unittest", "test_paths" => paths}

      assert {:error, {:invalid_gate_reference, "python_unittest"}} =
               PlanGateRunner.run(gate, ctx, opts)
    end

    gate = %{"gate" => "python_unittest", "test_paths" => ["test/test_greeting.py"]}

    for key <- ["command", "argv", "module", "executable"] do
      assert {:error, {:invalid_gate_reference, "python_unittest"}} =
               PlanGateRunner.run(Map.put(gate, key, "untrusted"), ctx, opts)
    end

    runner = fn argv, _, _ ->
      assert argv == ["python3", "-B", "-m", "unittest", "test/test_greeting.py"]
      {:ok, %{exit_status: 0, output: "required valid gate retained"}}
    end

    assert {:ok, evidence} = PlanGateRunner.run(gate, ctx, Keyword.put(opts, :runner, runner))
    assert evidence.output == "required valid gate retained"

    assert {:ok, :accepted} =
             PlanGateRunner.verify(gate, evidence, ctx, Keyword.put(opts, :runner, runner))
  end

  test "Python references validate at both task and goal boundaries and advertise the gate to planners" do
    for case_id <- Evaluation.cases() do
      {:ok, json} = Evaluation.reference(case_id)
      assert {:ok, contract} = PlanContract.from_canonical_json(json)
      assert {:ok, argv} = PlanContract.gate_argv(contract)
      assert Enum.all?(argv, &match?(["python3", "-B", "-m", "unittest" | _], &1))
      {:ok, context} = Evaluation.context(case_id)

      alternatives =
        get_in(context, [
          "output_schema",
          "properties",
          "tasks",
          "items",
          "properties",
          "gates",
          "items",
          "anyOf"
        ])

      assert python =
               Enum.find(
                 alternatives,
                 &(get_in(&1, ["properties", "gate", "const"]) == "python_unittest")
               )

      assert python["properties"]["test_paths"]["minItems"] == 1
    end
  end

  for case_id <- ~w(greeting receipt catalog) do
    @tag :tmp_dir
    test "#{case_id} reference steps pass real Python gates bound to clean Git commits", %{
      tmp_dir: dir
    } do
      case_id = unquote(case_id)
      root = Application.app_dir(:shoestring, "priv/planner_eval")
      repository = Path.join(dir, "repository")
      File.cp_r!(Path.join(root, "repository"), repository)
      git!(repository, ["init"])
      git!(repository, ["config", "user.name", "Fixture"])
      git!(repository, ["config", "user.email", "fixture@example.invalid"])
      commit!(repository, "Python fixture baseline")
      {:ok, json} = Evaluation.reference(case_id)
      plan = Jason.decode!(json)
      [goal_gate] = plan["goal"]["acceptance"]["gates"]
      opts = [worktree_path: repository, timeout_ms: 15_000]
      ctx = context(case_id)

      assert {:ok, baseline} = PlanGateRunner.run(goal_gate, ctx, opts)
      assert baseline.exit_status == 1
      assert baseline.output =~ "AssertionError:"
      refute baseline.output =~ "ImportError"

      assert {:error, {:gate_failed, %{exit_status: 1}}} =
               PlanGateRunner.verify(goal_gate, baseline, ctx, opts)

      Enum.each(plan["tasks"], fn task ->
        File.cp!(
          Path.join(root, "reference_steps/#{task["id"]}.py"),
          Path.join(repository, "pantry.py")
        )

        commit!(repository, "Apply #{task["id"]} reference step")
        task_ctx = %{ctx | plan_task_id: task["id"]}
        [gate] = task["gates"]
        assert {:ok, evidence} = PlanGateRunner.run(gate, task_ctx, opts)
        assert evidence.exit_status == 0, evidence.output
        assert evidence.output =~ "OK"
        assert {:ok, :accepted} = PlanGateRunner.verify(gate, evidence, task_ctx, opts)
        assert evidence.commit != baseline.commit

        assert {:error, {:gate_evidence_forged, %{field: :plan_digest}}} =
                 PlanGateRunner.verify(
                   gate,
                   evidence,
                   %{task_ctx | plan_digest: String.duplicate("b", 64)},
                   opts
                 )
      end)

      assert {:ok, final} = PlanGateRunner.run(goal_gate, ctx, opts)
      assert final.exit_status == 0, final.output
      assert {:ok, :accepted} = PlanGateRunner.verify(goal_gate, final, ctx, opts)
      assert git!(repository, ["status", "--porcelain"]) == ""
      assert Path.wildcard(Path.join(repository, "**/__pycache__")) == []
    end
  end

  defp context(task) do
    %{
      goal_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      plan_task_id: task,
      revision_number: 1,
      plan_digest: String.duplicate("a", 64),
      attempt: 1
    }
  end

  defp commit!(repository, message) do
    git!(repository, ["add", "."])
    git!(repository, ["commit", "-m", message])
  end

  defp git!(repository, args) do
    assert {:ok, result} = GateProcess.run(["git" | args], repository, 15_000, 65_536)
    assert result.exit_status == 0, result.output
    result.output
  end
end
