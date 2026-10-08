defmodule Shoestring.Cobbler.PlanGateSafetyTest do
  use ExUnit.Case, async: true
  alias Shoestring.Cobbler.PlanGateRunner

  test "missing commit is a structured refusal" do
    ctx = %{
      goal_id: Ecto.UUID.generate(),
      plan_task_id: "alpha",
      revision_number: 1,
      plan_digest: String.duplicate("a", 64),
      run_id: Ecto.UUID.generate(),
      attempt: 1
    }

    gate = %{"gate" => "mix_precommit"}

    evidence =
      Map.merge(ctx, %{gate: "mix_precommit", gate_argv: ["mix", "precommit"], exit_status: 0})

    assert {:error, {:gate_commit_invalid, nil}} = PlanGateRunner.verify(gate, evidence, ctx)
  end

  test "worktree binding refuses evidence from another directory" do
    ctx = %{
      goal_id: Ecto.UUID.generate(),
      plan_task_id: "alpha",
      revision_number: 1,
      plan_digest: String.duplicate("a", 64),
      run_id: Ecto.UUID.generate(),
      attempt: 1
    }

    gate = %{"gate" => "mix_precommit"}

    opts = [
      worktree_path: File.cwd!(),
      commit: String.duplicate("a", 40),
      runner: fn _, _, _ -> {:ok, %{exit_status: 0, output: "gate ok"}} end
    ]

    assert {:ok, evidence} = PlanGateRunner.run(gate, ctx, opts)

    assert {:error, {:gate_evidence_forged, %{field: :worktree}}} =
             PlanGateRunner.verify(
               gate,
               %{evidence | worktree: Path.dirname(File.cwd!())},
               ctx,
               opts
             )
  end

  test "named gate parameters cannot inject options or an executable" do
    ctx = %{
      goal_id: Ecto.UUID.generate(),
      plan_task_id: "alpha",
      revision_number: 1,
      plan_digest: String.duplicate("a", 64),
      run_id: Ecto.UUID.generate(),
      attempt: 1
    }

    runner = fn _, _, _ -> flunk("invalid references cannot reach the runner") end
    opts = [worktree_path: File.cwd!(), commit: String.duplicate("a", 40), runner: runner]

    assert {:error, {:invalid_gate_reference, "mix_test"}} =
             PlanGateRunner.run(
               %{"gate" => "mix_test", "test_paths" => ["--include", "live"]},
               ctx,
               opts
             )

    assert {:error, {:invalid_gate_reference, "mix_precommit"}} =
             PlanGateRunner.run(%{"gate" => "mix_precommit", "command" => "anything"}, ctx, opts)

    assert {:ok, _} =
             PlanGateRunner.run(
               %{"gate" => "mix_test", "test_paths" => ["test/fixture_test.exs"]},
               ctx,
               Keyword.put(opts, :runner, fn argv, _, _ ->
                 assert argv == ["mix", "test", "test/fixture_test.exs"]
                 {:ok, %{exit_status: 0, output: "required valid reference retained"}}
               end)
             )
  end

  test "missing directory is a structured evidence refusal" do
    ctx = %{
      goal_id: Ecto.UUID.generate(),
      plan_task_id: "alpha",
      revision_number: 1,
      plan_digest: String.duplicate("a", 64),
      run_id: Ecto.UUID.generate(),
      attempt: 1
    }

    gate = %{"gate" => "mix_precommit"}

    evidence =
      Map.merge(ctx, %{
        gate: "mix_precommit",
        gate_argv: ["mix", "precommit"],
        exit_status: 0,
        commit: String.duplicate("a", 40)
      })

    opts = [
      worktree_path: File.cwd!(),
      commit: String.duplicate("a", 40),
      runner: fn _, _, _ -> :unused end
    ]

    assert {:error, {:gate_evidence_forged, %{field: :worktree}}} =
             PlanGateRunner.verify(gate, evidence, ctx, opts)
  end
end
