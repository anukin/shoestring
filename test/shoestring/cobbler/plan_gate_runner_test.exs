defmodule Shoestring.Cobbler.PlanGateRunnerTest do
  @moduledoc """
  Hermetic tests for the bounded supervised plan gate runner.

  Gate execution itself is injected (an internal/test-config function),
  so no OS process ever spawns here; argv resolution, evidence binding,
  and forgery refusal are all exercised for real. New functionality in
  this work package (absent at the base commit).
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.PlanGateRunner
  alias Shoestring.Test.PlanFixtures

  @digest String.duplicate("a", 64)
  @commit PlanFixtures.base_revision()

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        goal_id: Ecto.UUID.generate(),
        plan_task_id: "alpha",
        revision_number: 1,
        plan_digest: @digest,
        run_id: Ecto.UUID.generate(),
        attempt: 1
      },
      overrides
    )
  end

  defp success_runner do
    fn _argv, _worktree, _timeout ->
      {:ok, %{exit_status: 0, output: "gate ok", duration_ms: 9}}
    end
  end

  defp gate_opts(extra \\ []) do
    Keyword.merge(
      [runner: success_runner(), worktree_path: File.cwd!(), commit: @commit],
      extra
    )
  end

  test "a trusted gate resolves argv from code and returns bound evidence" do
    gate_ref = %{
      "gate" => "mix_test",
      "test_paths" => ["test/shoestring/cobbler/plan_contract_test.exs"]
    }

    ctx = context()

    assert {:ok, evidence} = PlanGateRunner.run(gate_ref, ctx, gate_opts())

    assert evidence.gate == "mix_test"
    assert evidence.gate_argv == ["mix", "test", "test/shoestring/cobbler/plan_contract_test.exs"]
    assert evidence.goal_id == ctx.goal_id
    assert evidence.plan_task_id == "alpha"
    assert evidence.revision_number == 1
    assert evidence.plan_digest == @digest
    assert evidence.commit == @commit
    assert evidence.worktree == File.cwd!() |> Path.expand()
    assert evidence.exit_status == 0

    assert {:ok, :accepted} = PlanGateRunner.verify(gate_ref, evidence, ctx)
  end

  test "a plan can never supply executable names: unknown gates are refused" do
    ctx = context()

    assert {:error, {:unknown_gate, "rm -rf"}} =
             PlanGateRunner.run(%{"gate" => "rm -rf"}, ctx, gate_opts())
  end

  test "a nonzero exit never counts as acceptance" do
    gate_ref = %{"gate" => "mix_precommit"}
    ctx = context()

    failing =
      gate_opts(
        runner: fn _argv, _worktree, _timeout ->
          {:ok, %{exit_status: 1, output: "failure", duration_ms: 3}}
        end
      )

    assert {:ok, evidence} = PlanGateRunner.run(gate_ref, ctx, failing)

    assert {:error, {:gate_failed, %{exit_status: 1}}} =
             PlanGateRunner.verify(gate_ref, evidence, ctx)
  end

  test "stale evidence from another digest is refused as forged" do
    gate_ref = %{"gate" => "mix_precommit"}
    ctx = context()

    assert {:ok, evidence} = PlanGateRunner.run(gate_ref, ctx, gate_opts())

    stale_ctx = %{ctx | plan_digest: String.duplicate("b", 64)}

    assert {:error, {:gate_evidence_forged, %{field: :plan_digest}}} =
             PlanGateRunner.verify(gate_ref, evidence, stale_ctx)
  end

  test "evidence bound to another run is refused as forged" do
    gate_ref = %{"gate" => "mix_precommit"}
    ctx = context()

    assert {:ok, evidence} = PlanGateRunner.run(gate_ref, ctx, gate_opts())

    other_ctx = %{ctx | run_id: Ecto.UUID.generate(), attempt: 2}

    assert {:error, {:gate_evidence_forged, %{field: :run_id}}} =
             PlanGateRunner.verify(gate_ref, evidence, other_ctx)
  end

  test "missing evidence is refused, never accepted" do
    gate_ref = %{"gate" => "mix_precommit"}

    assert {:error, {:gate_evidence_missing, :evidence}} =
             PlanGateRunner.verify(gate_ref, nil, context())
  end

  test "oversized output fails the run instead of truncating" do
    gate_ref = %{"gate" => "mix_precommit"}

    oversized =
      gate_opts(
        runner: fn _argv, _worktree, _timeout ->
          {:ok, %{exit_status: 0, output: String.duplicate("x", 65_537), duration_ms: 1}}
        end
      )

    assert {:error, {:gate_output_oversized, %{bytes: 65_537}}} =
             PlanGateRunner.run(gate_ref, context(), oversized)
  end

  test "a missing worktree fails closed" do
    gate_ref = %{"gate" => "mix_precommit"}

    assert {:error, {:gate_worktree_missing, _path}} =
             PlanGateRunner.run(
               gate_ref,
               context(),
               gate_opts(worktree_path: "/nonexistent-plan-worktree-0195")
             )
  end
end
