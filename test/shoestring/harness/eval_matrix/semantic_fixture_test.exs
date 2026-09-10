defmodule Shoestring.Harness.EvalMatrix.SemanticFixtureTest do
  @moduledoc """
  Genuine fixture-task semantic eval (loop-closure W7): a real two-Elf task
  over real files with mechanical acceptance — no hand-appended terminals on
  the driven path, no scripted completions.

  Fixture: a tiny git project (`service.txt` broken, `forbidden.txt`
  must-not-touch, `check.sh` asserting both). Leg A is a real Elf whose
  command partially implements then fails the check (exit 1 → terminal
  failed, mechanical); its checkpoint carries repo evidence collected for
  real (`git rev-parse`, `git status`, `git diff --stat`, the durable
  terminal event). Semantic strings (constraint, rejected approach,
  next-action instruction) are fixture-authored through the real writer —
  exactly what a model authors in production — and labeled as such below.
  Leg B per arm is a real Elf running the deterministic applier
  (`test/fixtures/fixture_applier.py`, python3 stdlib only) on that arm's
  prompt; the terminal class comes from the applier's real exit code fused
  with real progress events. Acceptance is re-verified independently by
  this test (fresh `check.sh` run + byte comparisons), never trusted from
  the applier.

  Arms (same leg A, same applier, only the leg-B input differs):

  - worktree-only: bare file listing (no instruction → nothing fixed).
  - naive-summary: flat prose naming every file with the fix instruction
    but no constraint.
  - trajectory-projection: the real composed handoff prompt (fix +
    constraint + minimal refs) via `Continuation`.

  Locking note (standing contract): every producer here is merged, so
  these tests PASS on the pre-fix commit too — they document genuine loop
  behavior (mechanical terminals, file states, exit codes), not a behavior
  change. The locks they carry are internal: cross-arm invariants that fail
  if any arm's mechanics regress (e.g. trajectory acceptance dropping to
  anything but 2, or the worktree arm completing).
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Harness.{Checkpoints, Continuation}
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Trajectory

  alias Shoestring.Test.ElvesHelpers

  @terminal_timeout 30_000
  @constraint "never modify forbidden.txt"
  @fix_instruction "write 'status: fixed' into service.txt"
  @check_instruction "run check.sh"

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    dir = Path.join(System.tmp_dir!(), "shoestring-w7-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{sup: sup, goal: goal, task: task, dir: dir}
  end

  test "three arms: genuine execution, mechanical acceptance, measured tax", %{
    sup: sup,
    goal: goal,
    task: task,
    dir: dir
  } do
    write_fixture!(dir)
    git!(dir, ["init"])
    git!(dir, ["add", "-A"])

    git!(dir, ["-c", "user.email=w7@test", "-c", "user.name=w7", "commit", "-m", "baseline"])

    revision = git!(dir, ["rev-parse", "HEAD"]) |> String.trim()
    assert byte_size(revision) > 0

    leg_a_run = run_leg_a!(sup, goal, task, dir)

    checkpoint_id = Ecto.UUID.generate()

    {:ok, checkpoint} =
      Shoestring.Harness.Checkpoint.new(%{
        version: Shoestring.Harness.Checkpoint.version(),
        checkpoint_id: checkpoint_id,
        goal_id: goal.id,
        run_id: leg_a_run,
        acceptance_contract: %{criteria: ["service reaches status fixed with forbidden pristine"]},
        repository_state: %{revision: revision, dirty: true},
        evidence: [
          "leg-a terminal failed: check.sh exit 1 on the partial implementation",
          "git diff --stat: " <> (git!(dir, ["diff", "--stat"]) |> String.trim())
        ],
        decisions: ["constraint: #{@constraint}", "rejected: rewrite the service from scratch"],
        unresolved_issues: ["service fix pending leg B"],
        next_action: "#{@fix_instruction} and #{@check_instruction}; constraint: #{@constraint}",
        stop_reason: "leg-a check failed (exit 1)",
        provider_session_id: "fake-session-leg-a",
        extensions: %{}
      })

    {:ok, %{checkpoint_id: ^checkpoint_id}} =
      Checkpoints.record(
        goal.id,
        checkpoint,
        repo: Shoestring.Repo,
        now: DateTime.utc_now(),
        actor: "w7-fixture",
        writer_opts: []
      )

    assert {:ok, _} = Shoestring.Harness.Projector.project(goal.id)

    {:ok, cont} =
      Continuation.for_goal(goal.id, repo: Shoestring.Repo, run_id: leg_a_run)

    record = Shoestring.Repo.get!(Shoestring.Harness.CheckpointRecord, checkpoint_id)

    prompts = %{
      worktree_only: "Files in workdir: service.txt, forbidden.txt, check.sh, prompt.txt.",
      naive_summary:
        "Summary of prior work. Files seen: service.txt, forbidden.txt, " <>
          "check.sh, leg_a.sh, prompt.txt, actions.log. The service is broken. " <>
          "Repair instruction: #{@fix_instruction} then #{@check_instruction} to verify.",
      trajectory_projection: Continuation.compose_handoff_prompt(cont, checkpoint_record: record)
    }

    # Trajectory prompt genuinely carries the constraint and the fix.
    assert prompts.trajectory_projection =~ @constraint
    assert prompts.trajectory_projection =~ "status: fixed"

    results =
      Enum.map([:worktree_only, :naive_summary, :trajectory_projection], fn arm ->
        reset_fixture!(dir)
        File.write!(Path.join(dir, "prompt.txt"), prompts[arm])
        terminal = run_leg_b!(sup, goal, task, dir)
        score_arm(dir, prompts[arm]) |> Map.put(:terminal, terminal)
      end)
      |> Enum.zip([:worktree_only, :naive_summary, :trajectory_projection])
      |> Map.new(fn {result, arm} -> {arm, result} end)

    # Mechanical invariants (each would fail on regressed mechanics):
    assert results.trajectory_projection.acceptance == 2
    assert results.trajectory_projection.constraint == 2
    assert results.trajectory_projection.terminal == :completed
    assert results.naive_summary.acceptance == 2
    assert results.naive_summary.constraint == 0
    assert results.worktree_only.acceptance == 0
    assert results.worktree_only.terminal == :failed
    # The naive summary names every file, so its investigation set is
    # strictly larger than the trajectory prompt's by construction.
    assert results.naive_summary.extra_reads > results.trajectory_projection.extra_reads
    # Trajectory wins outright.
    assert results.trajectory_projection.total > results.naive_summary.total
    assert results.naive_summary.total > results.worktree_only.total
  end

  # ----------------------------------------------------------------------------
  # Legs
  # ----------------------------------------------------------------------------

  defp run_leg_a!(sup, goal, task, dir) do
    run_id = Ecto.UUID.generate()
    request = ElvesHelpers.run_request(goal, task, dispatch_id: run_id)

    scenario =
      ElvesHelpers.custom_scenario(:w7_leg_a, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("leg-a partial work", source_event_id: "evt-out")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: Shoestring.Harness.Fake,
               adapter_opts: %{scenario: scenario},
               command: ["./leg_a.sh"],
               runner_opts: [cd: dir, kill_grace_ms: 200, reap_timeout_ms: 2_000],
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :failed}}, @terminal_timeout
    run_id
  end

  defp run_leg_b!(sup, goal, task, dir) do
    run_id = Ecto.UUID.generate()
    request = ElvesHelpers.run_request(goal, task, dispatch_id: run_id)

    scenario =
      ElvesHelpers.custom_scenario(:w7_leg_b, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("leg-b working", source_event_id: "evt-out")
      ])

    applier = Path.join([File.cwd!(), "test", "fixtures", "fixture_applier.py"])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: Shoestring.Harness.Fake,
               adapter_opts: %{scenario: scenario},
               command: ["python3", applier, dir],
               runner_opts: [cd: dir, kill_grace_ms: 200, reap_timeout_ms: 2_000],
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, terminal}, @terminal_timeout
    terminal.class
  end

  # ----------------------------------------------------------------------------
  # Fixture project
  # ----------------------------------------------------------------------------

  defp write_fixture!(dir) do
    File.write!(Path.join(dir, "service.txt"), "status: broken\n")
    File.write!(Path.join(dir, "forbidden.txt"), "do not touch\n")

    File.write!(Path.join(dir, "check.sh"), """
    #!/bin/sh
    grep -q "^status: fixed$" service.txt || exit 1
    cmp -s forbidden.txt forbidden.orig || exit 2
    exit 0
    """)

    File.write!(Path.join(dir, "leg_a.sh"), """
    #!/bin/sh
    echo "attempt: restarted service (still broken)" >> service.txt
    exec ./check.sh
    """)

    File.chmod!(Path.join(dir, "check.sh"), 0o755)
    File.chmod!(Path.join(dir, "leg_a.sh"), 0o755)
    File.write!(Path.join(dir, "forbidden.orig"), "do not touch\n")
    :ok
  end

  defp reset_fixture!(dir) do
    git!(dir, ["checkout", "--", "service.txt"])
    File.rm(Path.join(dir, "actions.log"))
    :ok
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end

  # ----------------------------------------------------------------------------
  # Mechanical scoring (file bytes + exit codes + applier log, never prose)
  # ----------------------------------------------------------------------------

  defp score_arm(dir, prompt) do
    {_, check_exit} = System.cmd(Path.join(dir, "check.sh"), [], cd: dir)
    service = File.read!(Path.join(dir, "service.txt"))
    forbidden = File.read!(Path.join(dir, "forbidden.txt"))
    forbidden_orig = File.read!(Path.join(dir, "forbidden.orig"))

    acceptance =
      cond do
        check_exit == 0 -> 2
        service =~ "status: fixed" -> 1
        true -> 0
      end

    constraint =
      cond do
        prompt =~ @constraint and forbidden == forbidden_orig -> 2
        true -> 0
      end

    recognition =
      cond do
        prompt =~ "status: fixed" and prompt =~ "checkpoint" -> 2
        prompt =~ "status: fixed" -> 1
        true -> 0
      end

    reads =
      dir
      |> Path.join("actions.log")
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "read "))
      |> Enum.map(fn "read " <> rest -> hd(String.split(rest)) end)
      |> Enum.reject(&(&1 in ["prompt.txt", "service.txt", "check.sh"]))
      |> Enum.uniq()
      |> length()

    checks =
      dir
      |> Path.join("actions.log")
      |> File.read!()
      |> String.split("\n")
      |> Enum.count(&String.starts_with?(&1, "check "))

    repeated =
      cond do
        reads == 0 -> 2
        reads <= 2 -> 1
        true -> 0
      end

    turns = if check_exit == 0, do: 2, else: 0
    capacity = if byte_size(prompt) <= 800, do: 2, else: 1

    %{
      acceptance: acceptance,
      constraint: constraint,
      recognition: recognition,
      repeated: repeated,
      turns: turns,
      capacity: capacity,
      extra_reads: reads,
      check_runs: checks,
      prompt_bytes: byte_size(prompt),
      terminal: nil,
      total: acceptance + constraint + recognition + repeated + turns + capacity
    }
  end
end
