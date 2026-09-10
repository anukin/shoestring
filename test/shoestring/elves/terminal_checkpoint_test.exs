defmodule Shoestring.Elves.TerminalCheckpointTest do
  @moduledoc """
  Unit tests for `Shoestring.Elves.TerminalCheckpoint` collection bounds and
  the deterministic floor template.

  Standing-contract label: DOCUMENTATION. This module does not exist on the
  pre-fix base commit, so these tests cannot fail there for a behavioural
  reason. The behavioural locks live in `ElfTerminalCheckpointTest`, which
  drives the real Elf terminal path and references only base-present modules.
  """

  use Shoestring.DataCase, async: false

  alias Shoestring.Elves.TerminalCheckpoint
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.ElfWorktreeFixture
  alias Shoestring.Test.FixedClock
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.ArtifactStore

  test "checkpoint_id/1 is deterministic, UUID-shaped, and distinct per run" do
    run_a = Ecto.UUID.generate()
    run_b = Ecto.UUID.generate()

    assert TerminalCheckpoint.checkpoint_id(run_a) == TerminalCheckpoint.checkpoint_id(run_a)
    assert TerminalCheckpoint.checkpoint_id(run_a) != TerminalCheckpoint.checkpoint_id(run_b)

    assert {:ok, _} = Ecto.UUID.cast(TerminalCheckpoint.checkpoint_id(run_a))
  end

  test "collect/3 gathers real worktree evidence from a fixture worktree" do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

    File.write!(Path.join(fixture.worktree.path, "terminal-note.txt"), "note\n")

    state = elf_state(fixture.worktree.workspace_ref)
    terminal = %{class: :completed}

    assert {:ok, inputs} = TerminalCheckpoint.collect(state, terminal)
    assert inputs.repository_revision == fixture.base_commit
    assert inputs.repository_dirty == true
    assert inputs.acceptance_criteria != []

    evidence = Enum.join(inputs.evidence, "\n")
    assert evidence =~ fixture.base_commit
    assert evidence =~ "terminal-note.txt"
    assert evidence =~ "no verification recorded"
    assert evidence =~ "last safe boundary: none recorded"
    assert evidence =~ "outcome completed"

    assert inputs.next_action =~ "mix precommit"
    assert inputs.extensions["shoestring.elf:checkpoint_kind"] == "terminal"
    assert inputs.extensions["shoestring.elf:terminal_key"] == "elf-terminal:#{state.dispatch_id}"
  end

  test "collect/3 hard-fails to an error on changed-file overflow (never truncated)" do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

    files = Enum.map_join(1..51, "\n", &"file-#{&1}.txt")

    git = fn _path, args ->
      case args do
        ["rev-parse", "HEAD"] -> {fixture.base_commit <> "\n", 0}
        ["status", "--porcelain=v1", "--untracked-files=all"] -> {files <> "\n", 0}
        ["diff", "HEAD", "--stat"] -> {"", 0}
        ["branch", "--show-current"] -> {"shoestring/run-test\n", 0}
      end
    end

    state = elf_state(fixture.worktree.workspace_ref)

    assert {:error, {:checkpoint_overflow, %{field: :changed_files, limit: 50, actual: 51}}} =
             TerminalCheckpoint.collect(state, %{class: :completed}, git: git)
  end

  test "collect/3 hard-fails to an error on diff-stat overflow (never truncated)" do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

    stat = String.duplicate("x", 32 * 1024 + 1)

    git = fn _path, args ->
      case args do
        ["rev-parse", "HEAD"] -> {fixture.base_commit <> "\n", 0}
        ["status", "--porcelain=v1", "--untracked-files=all"] -> {" M fixture.txt\n", 0}
        ["diff", "HEAD", "--stat"] -> {stat, 0}
        ["branch", "--show-current"] -> {"shoestring/run-test\n", 0}
      end
    end

    state = elf_state(fixture.worktree.workspace_ref)

    assert {:error, {:checkpoint_overflow, %{field: :diff_stat}}} =
             TerminalCheckpoint.collect(state, %{class: :completed}, git: git)
  end

  test "record/3 falls back to the floor template when collection finds nothing" do
    state = elf_state("workspace/missing-#{System.unique_integer([:positive])}")
    terminal = %{class: :failed, error_category: "transport", error_code: "process_launch_failed"}

    test_pid = self()

    writer = fn _goal_id, checkpoint, _opts ->
      send(test_pid, {:written, checkpoint})

      {:ok,
       %{
         checkpoint_id: checkpoint.checkpoint_id,
         outcome: :recorded,
         events: [],
         checkpoint: checkpoint
       }}
    end

    assert {:ok, checkpoint_id} = TerminalCheckpoint.record(state, terminal, writer: writer)
    assert checkpoint_id == TerminalCheckpoint.checkpoint_id(state.run_id)

    assert_received {:written, checkpoint}
    assert checkpoint.repository_state.revision == "unknown"
    assert checkpoint.repository_state.dirty == false
    assert Enum.any?(checkpoint.evidence, &(&1 =~ "no verification recorded"))
    assert Enum.any?(checkpoint.evidence, &(&1 =~ "process_launch_failed"))
    assert checkpoint.next_action =~ "mix precommit"
    assert checkpoint.extensions["shoestring.elf:checkpoint_error"] =~ "no_worktree_evidence"
  end

  test "record/3 replays converge: full failure then floor share one checkpoint id" do
    state = elf_state("workspace/missing-#{System.unique_integer([:positive])}")
    terminal = %{class: :completed}
    test_pid = self()

    writer = fn _goal_id, checkpoint, _opts ->
      send(test_pid, {:attempt, checkpoint.checkpoint_id})
      {:error, :boom}
    end

    assert {:error, _reason} = TerminalCheckpoint.record(state, terminal, writer: writer)

    assert_received {:attempt, first_id}
    assert_received {:attempt, second_id}
    assert first_id == second_id
    assert first_id == TerminalCheckpoint.checkpoint_id(state.run_id)
  end

  describe "terminal decisions from admission history (round-2 finding 6, P1)" do
    test "collect/3 fills decisions from recent admission.decided history" do
      goal = FakeHelpers.insert_goal()
      run_id = Ecto.UUID.generate()
      fixture = ElfWorktreeFixture.create!(run_id)
      on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

      d1 = Ecto.UUID.generate()
      d2 = Ecto.UUID.generate()

      CobblerHelpers.append_admission_event!(
        goal.id,
        CobblerHelpers.admission_payload(decision_id: d1)
        |> Map.put("reason_code", "automatic_admission_eligible")
      )

      CobblerHelpers.append_admission_event!(
        goal.id,
        CobblerHelpers.admission_payload(decision_id: d2)
        |> Map.put("reason_code", "operator_confirmed_manual")
      )

      state = elf_state_for(goal.id, run_id, fixture.worktree.workspace_ref)

      assert {:ok, inputs} = TerminalCheckpoint.collect(state, %{class: :completed})
      assert length(inputs.decisions) == 2

      # Oldest first; each entry carries the decision id, the reason code,
      # and the admission source event pointer.
      assert Enum.at(inputs.decisions, 0) =~ d1
      assert Enum.at(inputs.decisions, 0) =~ "automatic_admission_eligible"
      assert Enum.at(inputs.decisions, 0) =~ "admission event"
      assert Enum.at(inputs.decisions, 1) =~ d2
      assert Enum.at(inputs.decisions, 1) =~ "operator_confirmed_manual"
    end

    test "collect/3 caps decisions at the newest 8 entries" do
      goal = FakeHelpers.insert_goal()
      run_id = Ecto.UUID.generate()
      fixture = ElfWorktreeFixture.create!(run_id)
      on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

      # Bound literal (mirrors TerminalCheckpoint.max_decision_entries/0):
      # on the base commit collect/3 always returns decisions [], so the
      # length assertion below fails there for the right behavioural reason.

      ids =
        Enum.map(1..10, fn _ ->
          id = Ecto.UUID.generate()

          CobblerHelpers.append_admission_event!(
            goal.id,
            CobblerHelpers.admission_payload(decision_id: id)
          )

          id
        end)

      state = elf_state_for(goal.id, run_id, fixture.worktree.workspace_ref)

      assert {:ok, inputs} = TerminalCheckpoint.collect(state, %{class: :completed})
      assert length(inputs.decisions) == 8

      # Newest 8, oldest first.
      for id <- Enum.take(ids, -8) do
        assert Enum.any?(inputs.decisions, &String.contains?(&1, id)),
               "expected decision #{id} in #{inspect(inputs.decisions)}"
      end

      for id <- Enum.take(ids, 2) do
        refute Enum.any?(inputs.decisions, &String.contains?(&1, id)),
               "expected decision #{id} to be capped away"
      end
    end

    test "collect/3 leaves decisions honestly [] when no admission history exists" do
      # DOCUMENTATION (standing-contract label): passes on the base commit
      # too (decisions were always []). Locks that empty history is never
      # papered over with invented entries.
      run_id = Ecto.UUID.generate()
      fixture = ElfWorktreeFixture.create!(run_id)
      on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

      state = elf_state(fixture.worktree.workspace_ref)

      assert {:ok, inputs} = TerminalCheckpoint.collect(state, %{class: :completed})
      assert inputs.decisions == []
    end

    test "collect/3 populates artifact_ids from the run's recorded artifact references" do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = Ecto.UUID.generate()
      run = FakeHelpers.insert_run_record(goal, task, dispatch_id)
      fixture = ElfWorktreeFixture.create!(run.id)
      on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

      {:ok, artifact} =
        ArtifactStore.put(goal.id, "terminal log bytes", %{"media_type" => "text/plain"},
          task_id: task.id
        )

      assert {:ok, _event} =
               Trajectory.append(
                 goal.id,
                 %{
                   "type" => "harness.event_recorded",
                   "schema_version" => 1,
                   "actor" => "elf",
                   "occurred_at" => CobblerHelpers.now(),
                   "idempotency_key" => "elf-log:#{dispatch_id}",
                   "payload" => %{
                     "run_id" => run.id,
                     "source_event_id" => "elf-log:#{dispatch_id}",
                     "ordinal" => 1,
                     "occurred_at" => DateTime.to_iso8601(CobblerHelpers.now()),
                     "kind" => "artifact",
                     "artifact_id" => artifact.id
                   }
                 },
                 trusted: [task_id: task.id, run_id: run.id]
               )

      state = elf_state_for(goal.id, run.id, fixture.worktree.workspace_ref, dispatch_id)

      assert {:ok, inputs} = TerminalCheckpoint.collect(state, %{class: :completed})
      assert inputs.artifact_ids == [artifact.id]
    end

    test "collect/3 keeps artifact_ids [] when the run recorded no artifacts" do
      # DOCUMENTATION (standing-contract label): passes on base too.
      # Locks the honest-empty side of the artifact inventory.
      goal = FakeHelpers.insert_goal()
      run_id = Ecto.UUID.generate()
      fixture = ElfWorktreeFixture.create!(run_id)
      on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

      state = elf_state_for(goal.id, run_id, fixture.worktree.workspace_ref)

      assert {:ok, inputs} = TerminalCheckpoint.collect(state, %{class: :completed})
      assert inputs.artifact_ids == []
    end
  end

  # -- Helpers --

  defp elf_state_for(goal_id, run_id, workspace_ref, dispatch_id \\ nil) do
    %{
      goal_id: goal_id,
      run_id: run_id,
      dispatch_id: dispatch_id || Ecto.UUID.generate(),
      request: %{workspace_ref: workspace_ref},
      provider_session_id: nil,
      lease_bounds: nil,
      lease_grant_id: nil,
      lease_deadline: nil,
      lease_checkpoint_id: nil,
      lease_checkpointed?: false,
      os_exit: :unknown,
      repo: Shoestring.Repo,
      clock: FixedClock
    }
  end

  defp elf_state(workspace_ref) do
    %{
      goal_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      dispatch_id: Ecto.UUID.generate(),
      request: %{workspace_ref: workspace_ref},
      provider_session_id: nil,
      lease_bounds: nil,
      lease_grant_id: nil,
      lease_deadline: nil,
      lease_checkpoint_id: nil,
      lease_checkpointed?: false,
      os_exit: :unknown,
      repo: Shoestring.Repo,
      clock: FixedClock
    }
  end
end
