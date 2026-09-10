defmodule Shoestring.Harness.EvalMatrix.SemanticFixtureTest do
  @moduledoc """
  Genuine fixture-task semantic eval (loop-closure W7, revised): real
  execution end to end with mechanical acceptance — no hand-appended
  terminals on the driven path, no scripted completions, no shared-state
  resets between arms.

  Per arm, an independent goal runs the same fixture task:

  - leg A is a real Elf whose failing check yields a real failed terminal;
    its checkpoint carries real repo evidence (`git rev-parse`, dirty diff
    stat, the durable terminal event) plus fixture-authored semantic
    strings (constraint, rejected approach, next-action instruction) —
    exactly what a model authors in production;
  - leg B routes through the REAL handoff request path
    (`Elves.resume_run/2` → intent → composed request → Fake session
    start), except the worktree arm, which has no checkpoint and therefore
    cannot handoff by design (asserted);
  - the applier (`test/fixtures/fixture_applier.py`, python3 stdlib only)
    executes the RECORDED handoff prompt in a second real Elf; terminal
    classes come from real exit codes fused with real progress events;
  - acceptance is re-verified independently (fresh `check.sh` run + byte
    comparisons), never trusted from the applier.

  Arms differ ONLY in checkpoint content (same task, same applier):

  - worktree-only: no checkpoint → handoff refused → direct Elf on a bare
    listing (no instruction → nothing fixed).
  - naive-summary: flat checkpoint (fix instruction present, every file
    named, no constraint).
  - trajectory-projection: full checkpoint (fix + constraint + minimal
    refs + admission decision history).

  Locking status: all producers are merged, so these tests PASS on the
  pre-fix tree too — documentation of genuine loop behavior, not behavior
  locks. Cross-arm invariants (trajectory acceptance/constraint, worktree
  failure, read-count ordering) fail on regressed mechanics. Recognition
  still scores prompt-text presence (the one non-mechanical dimension);
  semantic strings remain fixture-authored (labeled); cross-provider LIVE
  stays UNVERIFIED (no budget authorized).
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Harness.{Checkpoints, Continuation}
  alias Shoestring.Harness.Fake
  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Test.ElvesHelpers

  @terminal_timeout 30_000
  @constraint "never modify forbidden.txt"
  @fix_instruction "write 'status: fixed' into service.txt"
  @check_instruction "run check.sh"

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{sup: sup}
  end

  test "trajectory arm: full recovery through the real handoff path", %{sup: sup} do
    %{goal: goal, task: task, dir: dir, leg_a_run: leg_a_run} = leg_a_fixture!(sup, :trajectory)

    {prompt, _triple} = drive_handoff!(sup, goal, leg_a_run, dir)

    assert prompt =~ @constraint
    assert prompt =~ "status: fixed"

    terminal = drive_applier!(sup, goal, task, dir, prompt)
    assert terminal == :completed

    scores = score_arm(dir, prompt)
    assert scores.acceptance == 2
    assert scores.constraint == 2
    assert scores.total == 11
    assert scores.extra_reads == 1
  end

  test "naive arm: fix without constraint, noisier reads", %{sup: sup} do
    %{goal: goal, task: task, dir: dir, leg_a_run: leg_a_run} = leg_a_fixture!(sup, :naive)
    {prompt, _triple} = drive_handoff!(sup, goal, leg_a_run, dir)

    refute prompt =~ @constraint
    assert prompt =~ "status: fixed"

    terminal = drive_applier!(sup, goal, task, dir, prompt)
    assert terminal == :completed

    scores = score_arm(dir, prompt)
    assert scores.acceptance == 2
    assert scores.constraint == 0
    assert scores.total == 9
    assert scores.extra_reads == 2
  end

  test "worktree arm: no checkpoint means no handoff and no fix", %{sup: sup} do
    %{goal: goal, task: task, dir: dir, leg_a_run: leg_a_run} = leg_a_fixture!(sup, :none)

    # No checkpoint was authored: the handoff path refuses.
    assert {:error, _} = Elves.resume_run(leg_a_run, to_provider_id: "fake-harness-b")

    prompt = "Files in workdir: service.txt, forbidden.txt, check.sh, prompt.txt."
    terminal = drive_applier!(sup, goal, task, dir, prompt)
    assert terminal == :failed

    scores = score_arm(dir, prompt)
    assert scores.acceptance == 0
    assert scores.constraint == 0
    assert scores.total == 3
  end

  # ----------------------------------------------------------------------------
  # Leg A: genuine failing execution + authored checkpoint with real evidence
  # ----------------------------------------------------------------------------

  defp leg_a_fixture!(sup, arm) do
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    dir = fresh_dir!()
    write_fixture!(dir)
    git!(dir, ["init"])
    git!(dir, ["add", "-A"])
    git!(dir, ["-c", "user.email=w7@test", "-c", "user.name=w7", "commit", "-m", "baseline"])
    revision = dir |> git!(["rev-parse", "HEAD"]) |> String.trim()
    assert byte_size(revision) > 0

    leg_a_run = run_leg_a!(sup, goal, task, dir)
    checkpoint_id = Ecto.UUID.generate()

    checkpoint_attrs =
      case arm do
        :none ->
          nil

        :naive ->
          %{
            decisions: ["saw service.txt", "saw forbidden.txt", "saw check.sh"],
            unresolved_issues: [],
            next_action:
              "The service is broken. Repair instruction: #{@fix_instruction} " <>
                "then #{@check_instruction} to verify. Files seen: service.txt, " <>
                "forbidden.txt, check.sh, leg_a.sh, prompt.txt."
          }

        :trajectory ->
          %{
            decisions: [
              "constraint: #{@constraint}",
              "rejected: rewrite the service from scratch"
            ],
            unresolved_issues: ["service fix pending leg B"],
            next_action:
              "#{@fix_instruction} and #{@check_instruction}; constraint: #{@constraint}"
          }
      end

    if checkpoint_attrs do
      diff_stat = dir |> git!(["diff", "--stat"]) |> String.trim()

      {:ok, checkpoint} =
        Shoestring.Harness.Checkpoint.new(%{
          version: Shoestring.Harness.Checkpoint.version(),
          checkpoint_id: checkpoint_id,
          goal_id: goal.id,
          run_id: leg_a_run,
          acceptance_contract: %{
            criteria: ["service reaches status fixed with forbidden pristine"]
          },
          repository_state: %{revision: revision, dirty: true},
          evidence: [
            "leg-a terminal failed: check.sh exit 1 on the partial implementation",
            "git diff --stat: #{diff_stat}"
          ],
          decisions: checkpoint_attrs.decisions,
          unresolved_issues: checkpoint_attrs.unresolved_issues,
          next_action: checkpoint_attrs.next_action,
          stop_reason: "leg-a check failed (exit 1)",
          provider_session_id: "fake-session-leg-a",
          extensions: %{}
        })

      {:ok, %{checkpoint_id: ^checkpoint_id}} =
        Checkpoints.record(goal.id, checkpoint,
          repo: Shoestring.Repo,
          now: DateTime.utc_now(),
          actor: "w7-fixture",
          writer_opts: []
        )

      assert {:ok, _} = Shoestring.Harness.Projector.project(goal.id)
    end

    %{goal: goal, task: task, dir: dir, checkpoint_id: checkpoint_id, leg_a_run: leg_a_run}
  end

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
               adapter: Fake,
               adapter_opts: %{scenario: scenario},
               command: ["./leg_a.sh"],
               runner_opts: [cd: dir, kill_grace_ms: 200, reap_timeout_ms: 2_000],
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :failed}}, @terminal_timeout
    run_id
  end

  # ----------------------------------------------------------------------------
  # Leg B: real handoff path, then a real applier Elf on the recorded prompt
  # ----------------------------------------------------------------------------

  defp drive_handoff!(sup, goal, leg_a_run, dir) do
    {:ok, cont} = Continuation.for_goal(goal.id, repo: Shoestring.Repo, run_id: leg_a_run)

    triple = %{
      checkpoint_id: cont.checkpoint_id,
      next_action: cont.next_action,
      decision_refs: cont.decision_refs
    }

    {:ok, log} = RequestLog.start()

    scenario =
      ElvesHelpers.custom_scenario(:w7_handoff_effect, [
        Scenario.lifecycle_event(source_event_id: "evt-life")
      ])

    assert {:ok, %{run: _new_run}} =
             Elves.resume_run(leg_a_run,
               adapter: Fake,
               adapter_opts: %{scenario: scenario, request_log: log},
               continuation: triple,
               to_provider_id: "fake-harness-b",
               reason: "w7 fixture handoff",
               handoff_id: Ecto.UUID.generate(),
               new_run_id: Ecto.UUID.generate(),
               new_dispatch_id: Ecto.UUID.generate()
             )

    [recorded] = RequestLog.starts(log)
    assert recorded.continuation.checkpoint_id == triple.checkpoint_id
    {recorded.prompt, triple}
  end

  defp drive_applier!(sup, goal, task, dir, prompt) do
    File.write!(Path.join(dir, "prompt.txt"), prompt)
    run_id = Ecto.UUID.generate()
    request = ElvesHelpers.run_request(goal, task, dispatch_id: run_id)

    scenario =
      ElvesHelpers.custom_scenario(:w7_applier, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("applier working", source_event_id: "evt-out")
      ])

    applier = Path.join([File.cwd!(), "test", "fixtures", "fixture_applier.py"])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: Fake,
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

  defp fresh_dir! do
    dir = Path.join(System.tmp_dir!(), "shoestring-w7-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

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
      total: acceptance + constraint + recognition + repeated + turns + capacity
    }
  end
end
