defmodule Shoestring.Cobbler.PlanGateContractTest do
  @moduledoc """
  Gate contracts and records through the executor (iteration 8, work
  packages A and B): versioned specifications, configured project gates,
  cheap-first order, optional and skipped gates, start/completion events and
  output artifacts. Real private worktrees and real sandboxed gates (local
  `python3` only) unless a case injects the runner; no provider.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.CLI.{Checks, Follow}
  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.{GateProcess, GateSpec}
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers, PlanFixtures}
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{ArtifactStore, TrajectoryEvent}
  alias Shoestring.Worktrees

  import Shoestring.Test.PlanExecutorHelpers,
    only: [admit!: 1, complete_run!: 2, exec_opts: 1, propose_and_approve!: 2]

  @moduletag :tmp_dir
  @unit %{"gate" => "python_unittest", "test_paths" => ["test/test_calc.py"]}

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:shoestring, :project_gates)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shoestring, :project_gates, previous),
        else: Application.delete_env(:shoestring, :project_gates)
    end)

    Application.put_env(:shoestring, :project_gates, %{
      "status" => %{
        argv: [
          "python3",
          "-c",
          "print('status ok access' + chr(95) + 'token' + chr(61) + 'hunter2-value')"
        ],
        kind: "status"
      },
      "style" => %{
        argv: ["python3", "-c", "import sys; print('style: 2 issues'); sys.exit(3)"],
        kind: "lint",
        required: false
      },
      "slow" => %{
        argv: ["python3", "-c", "import time; print('partial', flush=True); time.sleep(30)"],
        kind: "test",
        timeout_ms: 1_500
      }
    })

    source = Path.join(dir, "source")
    File.mkdir_p!(Path.join(source, "test"))
    File.write!(Path.join(source, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(source, "test/__init__.py"), "")

    File.write!(
      Path.join(source, "test/test_calc.py"),
      "import unittest\nfrom calc import add\n\n\nclass AddTest(unittest.TestCase):\n" <>
        "    def test_four(self):\n        self.assertEqual(add(2, 2), 4)\n"
    )

    git!(source, ["init", "-b", "main"])
    git!(source, ["config", "user.name", "Fixture"])
    git!(source, ["config", "user.email", "fixture@example.invalid"])
    git!(source, ["add", "."])
    git!(source, ["-c", "commit.gpgsign=false", "commit", "-m", "Base"])

    %{goal: CobblerHelpers.create_goal!(), source: source}
  end

  test "gates run cheap first in the sandbox, each recorded with its spec, result and output artifact",
       c do
    # Plan order: the test, then the status check; the status kind runs first.
    {first, opts} = start!(c, [@unit, %{"gate" => "project:status"}], "    return a + b\n")
    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)

    [started_status, started_unit] = payloads(c.goal.id, "cobbler.plan.gate.started")
    [status, unit] = payloads(c.goal.id, "cobbler.plan.gate.completed")

    assert {started_status["gate"], started_status["position"]} == {"project:status", 1}
    assert {started_unit["gate"], started_unit["position"]} == {"python_unittest", 2}
    assert started_status["invocation_id"] == status["invocation_id"]
    assert started_unit["scope"] == "task" and started_unit["run_id"] == first.run_id

    {:ok, unit_spec} = GateSpec.build(@unit, 60_000)
    assert unit["spec"] == GateSpec.identity(unit_spec)
    assert unit["result"] == "passed" and unit["exit_status"] == 0
    assert unit["sandbox"] =~ ~r/\Amacos_seatbelt:v1:sha256:/
    assert unit["commit"] == head!(first)

    # The stored output is the gate's output, redacted, and its digest matches.
    assert {:ok, %{bytes: bytes, artifact: artifact}} = ArtifactStore.read(status["artifact_id"])
    assert bytes =~ "status ok"
    refute bytes =~ "hunter2-value"
    assert artifact.redacted
    assert status["output_sha256"] == artifact.sha256
    assert status["output_bytes"] == byte_size(bytes)

    # Acceptance evidence lists the gates in the order they ran.
    accepted = event!(c.goal.id, "cobbler.plan.task.accepted").payload

    assert [
             %{"gate" => "project:status", "result" => "passed", "required" => true} = s,
             %{"gate" => "python_unittest", "spec" => spec} = u
           ] = accepted["evidence"]["gates"]

    assert s["artifact_id"] == status["artifact_id"]
    assert spec == unit["spec"]
    assert u["artifact_id"] == unit["artifact_id"]
    assert accepted["gate"] == "project:status"

    # The CLI shows each invocation and can print its stored output.
    lines = checks(c.goal.id)
    assert lines =~ "1. task alpha attempt 1: project:status (status, required) -> passed exit 0"
    assert lines =~ "2. task alpha attempt 1: python_unittest (test, required) -> passed exit 0"
    assert lines =~ "spec #{unit["spec"]}"
    assert checks(c.goal.id, 1) =~ "status ok"

    assert Follow.line(%{type: "cobbler.plan.gate.completed", payload: unit}) =~
             "  Check python_unittest: passed in "
  end

  test "a failed optional gate is recorded without blocking",
       c do
    {first, opts} =
      start!(c, [@unit, %{"gate" => "project:style"}], "    return a + b\n")

    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)
    [style, unit] = payloads(c.goal.id, "cobbler.plan.gate.completed")
    assert {style["result"], style["exit_status"], style["required"]} == {"failed", 3, false}
    assert unit["result"] == "passed"

    assert [%{"gate" => "project:style", "result" => "failed", "required" => false}, _] =
             event!(c.goal.id, "cobbler.plan.task.accepted").payload["evidence"]["gates"]

    assert Follow.line(%{type: "cobbler.plan.gate.completed", payload: style}) ==
             "  Check project:style (optional): failed with exit 3 in " <>
               seconds(style["duration_ms"]) <> " s."
  end

  test "a failed required gate stops the run and lists the gates not run", c do
    Application.put_env(:shoestring, :project_gates, %{
      "style" => %{argv: ["python3", "-c", "import sys; sys.exit(3)"], kind: "lint"}
    })

    goal = c.goal
    {first, opts} = start!(c, [@unit, %{"gate" => "project:style"}], "    return a + b\n")
    assert {:ok, %{disposition: :gate_failed, retry_state: "retry"}} = complete(c, first, opts)

    failed = event!(goal.id, "cobbler.plan.task.gate_failed").payload

    assert {failed["gate"], failed["result"], failed["skipped"]} ==
             {"project:style", "failed", ["python_unittest"]}

    assert [%{"gate" => "project:style"}] = payloads(goal.id, "cobbler.plan.gate.started")

    assert Follow.line(%{type: "cobbler.plan.task.gate_failed", payload: failed}) ==
             "Task alpha: checks failed (project:style). Not run: python_unittest."
  end

  test "a timed-out gate keeps its partial output as an artifact, out of the failure reason", c do
    {first, opts} = start!(c, [%{"gate" => "project:slow"}, @unit], "    return a + b\n")
    assert {:ok, %{disposition: :gate_failed}} = complete(c, first, opts)

    # The test kind is ordered by plan position: slow is first.
    [slow] = payloads(c.goal.id, "cobbler.plan.gate.completed")
    assert slow["result"] == "timeout"
    refute Map.has_key?(slow, "exit_status")
    assert {:ok, %{bytes: "partial\n"}} = ArtifactStore.read(slow["artifact_id"])

    failed = event!(c.goal.id, "cobbler.plan.task.gate_failed").payload
    assert failed["result"] == "timeout"
    assert failed["skipped"] == ["python_unittest"]
    assert failed["reason"] =~ "gate_timeout"
    refute failed["reason"] =~ "partial"
  end

  test "a cited project gate that is not configured is unavailable and waits for the user", c do
    Application.put_env(:shoestring, :project_gates, %{})
    {first, opts} = start!(c, [@unit, %{"gate" => "project:status"}], "    return a + b\n")

    assert {:ok, %{disposition: :gate_failed, retry_state: "needs_user"}} =
             complete(c, first, opts)

    failed = event!(c.goal.id, "cobbler.plan.task.gate_failed").payload
    assert {failed["gate"], failed["result"]} == {"project:status", "unavailable"}
    assert failed["skipped"] == ["python_unittest"]
    # Nothing ran.
    assert payloads(c.goal.id, "cobbler.plan.gate.started") == []

    assert Follow.line(%{type: "cobbler.plan.task.gate_failed", payload: failed}) ==
             "Task alpha: check project:status is not configured; needs your decision."
  end

  test "the registry refuses gate records that claim more than the run showed", c do
    {first, opts} = start!(c, [@unit], "    return a + b\n")
    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)
    [completed] = payloads(c.goal.id, "cobbler.plan.gate.completed")

    refused = fn payload ->
      assert {:error, {:invalid_payload, _, _, _}} =
               Trajectory.append(
                 c.goal.id,
                 %{
                   "type" => "cobbler.plan.gate.completed",
                   "schema_version" => 1,
                   "actor" => "cobbler",
                   "occurred_at" => DateTime.utc_now(),
                   "payload" => Map.put(payload, "invocation_id", Ecto.UUID.generate())
                 },
                 trusted: [run_id: first.run_id]
               )
    end

    refused.(%{completed | "exit_status" => 1})
    refused.(%{completed | "result" => "failed", "exit_status" => 0})
    refused.(%{completed | "spec" => "python_unittest@1:sha256:abc"})

    refused.(%{
      completed
      | "spec" => String.replace(completed["spec"], "python_unittest", "mix_test")
    })

    refused.(%{completed | "gate" => "rm_rf"})
    refused.(Map.delete(completed, "output_sha256"))
    refused.(Map.delete(completed, "attempt"))
    refused.(%{completed | "scope" => "execution"})
  end

  test "gate output that looks like a secret is redacted, not a reason the task cannot be accepted",
       c do
    # Injected runner: the evidence path, not the sandbox, is under test.
    {first, opts} = start!(c, [@unit], "    return a + b\n")

    runner = fn _argv, _worktree, _timeout ->
      {:ok,
       %{
         exit_status: 0,
         output: "Ran 1 test\npassword=hunter2-from-a-fixture\nsession token: abc123\nOK\n"
       }}
    end

    opts =
      Keyword.update!(opts, :gate_runner_opts, fn gate_opts ->
        {:ok, %{path: path}} = Worktrees.get(first.run_id)
        Keyword.merge(gate_opts, runner: runner, worktree_path: path, commit: head!(first))
      end)

    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)
    [gate] = event!(c.goal.id, "cobbler.plan.task.accepted").payload["evidence"]["gates"]
    assert gate["output"] =~ "Ran 1 test"
    refute gate["output"] =~ "hunter2-from-a-fixture"
    refute gate["output"] =~ "abc123"
    assert gate["output"] =~ "OK"
  end

  defp start!(c, gates, body) do
    base = head_of!(c.source)

    plan =
      PlanExecutorHelpers.chain_plan(%{
        "goal" =>
          PlanFixtures.goal(%{
            "repository" => %{"base_revision" => base},
            "acceptance" => %{"gates" => [@unit], "evidence" => ["The tests pass."]}
          }),
        "tasks" => [PlanFixtures.task("alpha", "Implement add", [], %{"gates" => gates})]
      })

    opts = exec_opts(gate_runner_opts: [timeout_ms: 60_000], repository_path: c.source)
    rev = propose_and_approve!(c.goal, plan)
    admission = admit!(c.goal)

    assert {:ok, _} =
             Cobbler.request_plan_execution(
               c.goal.id,
               %{
                 revision_number: rev.revision_number,
                 digest: rev.digest,
                 admission_event_id: admission.id
               },
               opts
             )

    assert {:ok, first} =
             Cobbler.advance_plan_execution(
               c.goal.id,
               Keyword.put(opts, :admission_event_id, admission.id)
             )

    {:ok, %{path: path}} = Worktrees.get(first.run_id)
    File.write!(Path.join(path, "calc.py"), "def add(a, b):\n" <> body)
    git!(path, ["-c", "commit.gpgsign=false", "commit", "-qam", "Implement add"])
    complete_run!(c.goal, first.run_id)
    {first, opts}
  end

  defp complete(c, dispatched, opts),
    do: Cobbler.complete_plan_task_run(c.goal.id, dispatched.run_id, opts)

  defp checks(goal_id, output \\ nil) do
    Mix.shell(Mix.Shell.Process)

    try do
      :ok = Checks.show(goal_id, output: output)
      collect([])
    after
      Mix.shell(Mix.Shell.IO)
    end
  end

  defp collect(acc) do
    receive do
      {:mix_shell, :info, [line]} -> collect([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1)

  defp payloads(goal_id, type) do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type == ^type,
        order_by: [asc: e.sequence],
        select: e.payload
    )
  end

  defp event!(goal_id, type) do
    Repo.one(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type == ^type,
        order_by: [desc: e.sequence],
        limit: 1
    ) || flunk("no #{type} event")
  end

  defp head!(dispatched) do
    {:ok, %{path: path}} = Worktrees.get(dispatched.run_id)
    head_of!(path)
  end

  defp head_of!(dir), do: dir |> git!(["rev-parse", "HEAD"]) |> String.trim()

  defp git!(repository, args) do
    assert {:ok, result} = GateProcess.run(["git" | args], repository, 15_000, 65_536)
    assert result.exit_status == 0, result.output
    result.output
  end
end
