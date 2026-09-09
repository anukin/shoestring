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
  alias Shoestring.Test.ElfWorktreeFixture
  alias Shoestring.Test.FixedClock

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

  # -- Helpers --

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
