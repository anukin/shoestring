defmodule Shoestring.WorktreesTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.Capacity.CommandRunner
  alias Shoestring.Worktrees
  alias Shoestring.Worktrees.Worktree

  defmodule MissingGitRunner do
    @behaviour CommandRunner
    @impl true
    def find_executable("git"), do: nil
    def find_executable(_), do: nil
    @impl true
    def cmd(_cmd, _args, _opts), do: {"", 127}
  end

  defmodule FailingCleanupRunner do
    @behaviour CommandRunner
    @impl true
    def find_executable(cmd), do: System.find_executable(cmd)
    @impl true
    def cmd("git", ["worktree", "remove" | _], _opts) do
      {"fatal: failed to remove worktree: lock file present", 1}
    end

    def cmd(cmd, args, opts), do: System.cmd(cmd, args, opts)
  end

  defmodule FailingGitDirRunner do
    @behaviour CommandRunner
    @impl true
    def find_executable(cmd), do: System.find_executable(cmd)
    @impl true
    def cmd("git", ["rev-parse", "--git-dir"], _opts) do
      {"fatal: not a git repository", 128}
    end

    def cmd(cmd, args, opts), do: System.cmd(cmd, args, opts)
  end

  setup do
    unique = System.unique_integer([:positive, :monotonic])

    # Random per-run component: unique_integer restarts low each VM, so an
    # orphaned root from a killed run (where on_exit never fires) can never be
    # collided with and re-inited into the commit MatchError below.
    token = Ecto.UUID.generate()
    tmp_root = Path.join(System.tmp_dir!(), "shoestring_wt_test_#{token}_#{unique}")
    repo_path = Path.join(tmp_root, "source_repo")
    state_dir = Path.join(tmp_root, "state")
    worktrees_dir = Path.join(state_dir, "worktrees")

    File.mkdir_p!(repo_path)
    File.mkdir_p!(worktrees_dir)

    # Initialize fixture repo
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: repo_path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Shoestring Test"], cd: repo_path)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@shoestring.local"], cd: repo_path)

    File.write!(Path.join(repo_path, "README.md"), "# Fixture Repo\nInitial content\n")
    File.write!(Path.join(repo_path, "lib.ex"), "defmodule Lib do\n  def value, do: 42\nend\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: repo_path)

    {_, 0} =
      System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-m", "Initial commit"],
        cd: repo_path
      )

    {commit_out, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
    initial_commit = String.trim(commit_out)

    on_exit(fn ->
      File.rm_rf(tmp_root)
    end)

    %{
      tmp_root: tmp_root,
      repo_path: repo_path,
      worktrees_dir: worktrees_dir,
      initial_commit: initial_commit
    }
  end

  describe "happy path" do
    test "creates worktree, inspects status, commit, changed files, and diff", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir,
      initial_commit: initial_commit
    } do
      assert {:ok, %Worktree{} = wt} =
               Worktrees.create(repo_path, "run-happy", "HEAD", worktrees_dir: worktrees_dir)

      assert wt.run_id == "run-happy"
      assert wt.base_commit == initial_commit
      assert wt.branch == "shoestring/run-run-happy"
      assert wt.status == :active
      assert File.dir?(wt.path)

      assert {:ok, ^initial_commit} = Worktrees.current_commit(wt, worktrees_dir: worktrees_dir)
      assert {:ok, status} = Worktrees.status(wt, worktrees_dir: worktrees_dir)
      assert status.clean? == true
      assert status.dirty? == false
      assert status.commits_ahead == 0
      assert status.changed_files == []

      # Edit file in worktree
      File.write!(Path.join(wt.path, "README.md"), "# Mutated by Elf\nNew content\n")
      File.write!(Path.join(wt.path, "new_file.txt"), "elf created\n")

      assert {:ok, files} = Worktrees.changed_files(wt, worktrees_dir: worktrees_dir)
      assert "README.md" in files
      assert "new_file.txt" in files

      assert {:ok, diff_meta} = Worktrees.diff(wt, worktrees_dir: worktrees_dir)
      assert diff_meta.dirty? == true
      assert diff_meta.clean? == false
      assert "new_file.txt" in diff_meta.untracked_files
      assert diff_meta.patch =~ "Mutated by Elf"

      # Commit changes inside worktree
      {_, 0} = System.cmd("git", ["add", "."], cd: wt.path)

      {_, 0} =
        System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-m", "Elf commit"],
          cd: wt.path
        )

      assert {:ok, new_commit} = Worktrees.current_commit(wt, worktrees_dir: worktrees_dir)
      assert new_commit != initial_commit

      assert {:ok, status_after} = Worktrees.status(wt, worktrees_dir: worktrees_dir)
      assert status_after.commits_ahead == 1
      assert status_after.dirty? == false
      assert status_after.clean? == false
      assert "README.md" in status_after.changed_files
      assert "new_file.txt" in status_after.changed_files
    end
  end

  describe "SOURCE ISOLATION eval" do
    test "edits, creations, deletions, commits in worktree AND cleanup leave source checkout provably unchanged",
         %{
           repo_path: repo_path,
           worktrees_dir: worktrees_dir,
           initial_commit: initial_commit
         } do
      # Snapshot exact pre-run source repo state
      {status_before, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo_path)
      {sha_before, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
      readme_content_before = File.read!(Path.join(repo_path, "README.md"))
      lib_content_before = File.read!(Path.join(repo_path, "lib.ex"))
      source_files_before = File.ls!(repo_path) |> Enum.sort()
      {branches_before, 0} = System.cmd("git", ["branch", "--list"], cd: repo_path)

      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-isolation", "HEAD", worktrees_dir: worktrees_dir)

      # Destructive mutations inside worktree
      File.write!(Path.join(wt.path, "README.md"), "CORRUPTED CONTENT IN WORKTREE\n")
      File.rm!(Path.join(wt.path, "lib.ex"))
      File.write!(Path.join(wt.path, "elf_output.txt"), "brand new elf file\n")

      {_, 0} = System.cmd("git", ["add", "-A"], cd: wt.path)

      {_, 0} =
        System.cmd(
          "git",
          ["-c", "commit.gpgsign=false", "commit", "-m", "Destructive mutation in worktree"],
          cd: wt.path
        )

      File.write!(Path.join(wt.path, "untracked.log"), "diagnostic log\n")

      # Mid-run source verification
      {status_mid, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo_path)
      assert status_mid == status_before
      assert status_mid == ""

      {sha_mid, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
      assert sha_mid == sha_before
      assert String.trim(sha_mid) == initial_commit

      assert File.read!(Path.join(repo_path, "README.md")) == readme_content_before
      assert File.read!(Path.join(repo_path, "lib.ex")) == lib_content_before
      assert File.exists?(Path.join(repo_path, "lib.ex"))

      refute File.exists?(Path.join(repo_path, "elf_output.txt"))
      refute File.exists?(Path.join(repo_path, "untracked.log"))

      # Full lifecycle completion: complete and clean up with delete_branch: true
      assert {:ok, wt_completed} =
               Worktrees.update_status(wt, :completed, worktrees_dir: worktrees_dir)

      assert :ok =
               Worktrees.cleanup(wt_completed,
                 policy: :safe,
                 delete_branch: true,
                 worktrees_dir: worktrees_dir
               )

      refute File.exists?(wt.path)

      # Post-cleanup source checkout assertions: MUST BE 100% BYTE-IDENTICAL
      {status_after, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo_path)
      assert status_after == status_before
      assert status_after == ""

      {sha_after, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
      assert sha_after == sha_before
      assert String.trim(sha_after) == initial_commit

      assert File.read!(Path.join(repo_path, "README.md")) == readme_content_before
      assert File.read!(Path.join(repo_path, "lib.ex")) == lib_content_before
      assert File.exists?(Path.join(repo_path, "lib.ex"))

      refute File.exists?(Path.join(repo_path, "elf_output.txt"))
      refute File.exists?(Path.join(repo_path, "untracked.log"))

      source_files_after = File.ls!(repo_path) |> Enum.sort()
      assert source_files_after == source_files_before

      {branches_after, 0} = System.cmd("git", ["branch", "--list"], cd: repo_path)
      assert branches_after == branches_before
      assert branches_after =~ "main"
      refute branches_after =~ "shoestring/run-run-isolation"
    end
  end

  describe "uncommitted source changes" do
    test "uncommitted changes in source repo are preserved and not stashed or reset", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      # Create dirty uncommitted changes in source checkout
      File.write!(Path.join(repo_path, "README.md"), "# Dirty unstaged edit\n")
      File.write!(Path.join(repo_path, "staged.txt"), "staged file content\n")
      {_, 0} = System.cmd("git", ["add", "staged.txt"], cd: repo_path)
      File.write!(Path.join(repo_path, "untracked_source.txt"), "untracked file\n")

      {source_status_before, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo_path)

      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-dirty-source", "HEAD",
                 worktrees_dir: worktrees_dir
               )

      # Worktree is based on clean committed HEAD
      assert File.read!(Path.join(wt.path, "README.md")) == "# Fixture Repo\nInitial content\n"
      refute File.exists?(Path.join(wt.path, "staged.txt"))
      refute File.exists?(Path.join(wt.path, "untracked_source.txt"))

      # Source repo uncommitted changes are untouched
      {source_status_after, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo_path)
      assert source_status_after == source_status_before
      assert File.read!(Path.join(repo_path, "README.md")) == "# Dirty unstaged edit\n"
      assert File.read!(Path.join(repo_path, "staged.txt")) == "staged file content\n"
      assert File.read!(Path.join(repo_path, "untracked_source.txt")) == "untracked file\n"
    end
  end

  describe "branch collisions" do
    test "fails cleanly without creating orphaned worktree", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      {_, 0} = System.cmd("git", ["branch", "colliding-branch"], cd: repo_path)

      assert {:error, {:branch_already_exists, "colliding-branch"}} =
               Worktrees.create(repo_path, "run-collide", "HEAD",
                 branch: "colliding-branch",
                 worktrees_dir: worktrees_dir
               )

      entries = File.ls!(worktrees_dir) -- [".records"]
      assert entries == []
    end
  end

  describe "directory reuse and overwriting refusals" do
    test "refuses to overwrite or reuse unrecognized existing directory", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      unrecognized = Path.join(worktrees_dir, "iter3-existing-worktree")
      File.mkdir_p!(unrecognized)
      File.write!(Path.join(unrecognized, "important_data.txt"), "do not destroy me\n")

      assert {:error, {:unrecognized_existing_directory, ^unrecognized}} =
               Worktrees.create(repo_path, "run-reuse-attempt", "HEAD",
                 path: unrecognized,
                 worktrees_dir: worktrees_dir
               )

      assert File.read!(Path.join(unrecognized, "important_data.txt")) == "do not destroy me\n"
    end

    test "refuses to overwrite recognized existing directory", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-existing-rec", "HEAD",
                 worktrees_dir: worktrees_dir
               )

      assert {:error, {:directory_already_exists, path}} =
               Worktrees.create(repo_path, "run-another", "HEAD",
                 path: wt.path,
                 worktrees_dir: worktrees_dir
               )

      assert path == wt.path
    end
  end

  describe "invalid revisions" do
    test "fails cleanly for nonexistent base revision", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:error, {:invalid_base_revision, "nonexistent-ref-deadbeef"}} =
               Worktrees.create(repo_path, "run-bad-rev", "nonexistent-ref-deadbeef",
                 worktrees_dir: worktrees_dir
               )

      entries = File.ls!(worktrees_dir) -- [".records"]
      assert entries == []
    end
  end

  describe "run_id validation and sanitization" do
    test "rejects path-escaping run_id", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:error, {:invalid_run_id, "../../escape"}} =
               Worktrees.create(repo_path, "../../escape", "HEAD", worktrees_dir: worktrees_dir)

      assert {:error, {:invalid_run_id, "run with spaces"}} =
               Worktrees.create(repo_path, "run with spaces", "HEAD",
                 worktrees_dir: worktrees_dir
               )
    end

    test "rejects duplicate run_id even with distinct custom path", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:ok, _wt} =
               Worktrees.create(repo_path, "run-dup-id", "HEAD", worktrees_dir: worktrees_dir)

      custom_target = Path.join(worktrees_dir, "custom-other-dir")

      assert {:error, {:run_id_already_exists, "run-dup-id"}} =
               Worktrees.create(repo_path, "run-dup-id", "HEAD",
                 path: custom_target,
                 branch: "shoestring/other-branch",
                 worktrees_dir: worktrees_dir
               )
    end
  end

  describe "missing git binary" do
    test "returns clean error without crashing", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:error, {:missing_git_binary, "git"}} =
               Worktrees.create(repo_path, "run-no-git", "HEAD",
                 runner: MissingGitRunner,
                 worktrees_dir: worktrees_dir
               )
    end
  end

  describe "authoritative record enforcement in cleanup (Blocker 1)" do
    test "cleanup rejects caller-supplied struct with spoofed completed status on failed worktree",
         %{
           repo_path: repo_path,
           worktrees_dir: worktrees_dir
         } do
      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-spoofed-status", "HEAD",
                 worktrees_dir: worktrees_dir
               )

      assert {:ok, %Worktree{} = wt_failed} =
               Worktrees.update_status(wt, :failed, worktrees_dir: worktrees_dir)

      # Caller tries to bypass preservation by crafting a %Worktree{} with :completed
      spoofed_struct = %Worktree{wt_failed | status: :completed}

      assert {:error, :record_mismatch} =
               Worktrees.cleanup(spoofed_struct, policy: :safe, worktrees_dir: worktrees_dir)

      assert File.dir?(wt.path)
    end

    test "cleanup rejects caller-supplied struct with spoofed branch to protect user branch",
         %{
           repo_path: repo_path,
           worktrees_dir: worktrees_dir
         } do
      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-spoofed-branch", "HEAD",
                 worktrees_dir: worktrees_dir
               )

      assert {:ok, %Worktree{} = wt_done} =
               Worktrees.update_status(wt, :completed, worktrees_dir: worktrees_dir)

      # Caller tries to delete main branch by setting branch: "main"
      spoofed_struct = %Worktree{wt_done | branch: "main"}

      assert {:error, :record_mismatch} =
               Worktrees.cleanup(spoofed_struct,
                 policy: :safe,
                 delete_branch: true,
                 worktrees_dir: worktrees_dir
               )

      # Verify main branch was not deleted
      {branches, 0} = System.cmd("git", ["branch", "--list"], cd: repo_path)
      assert branches =~ "main"
      assert File.dir?(wt.path)
    end

    test "cleanup strictly refuses branch deletion for non-shoestring/ branches",
         %{
           repo_path: repo_path,
           worktrees_dir: worktrees_dir
         } do
      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-custom-branch", "HEAD",
                 branch: "custom-user-branch",
                 worktrees_dir: worktrees_dir
               )

      assert {:ok, wt_done} =
               Worktrees.update_status(wt, :completed, worktrees_dir: worktrees_dir)

      assert {:error, {:unsafe_branch_deletion, "custom-user-branch"}} =
               Worktrees.cleanup(wt_done,
                 policy: :safe,
                 delete_branch: true,
                 worktrees_dir: worktrees_dir
               )

      {branches, 0} = System.cmd("git", ["branch", "--list"], cd: repo_path)
      assert branches =~ "custom-user-branch"
      assert File.dir?(wt.path)
    end
  end

  describe "record divergence detection (Blocker 2)" do
    test "detects diverged record between .records and gitdir metadata", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-diverged", "HEAD", worktrees_dir: worktrees_dir)

      # Tamper with gitdir metadata to simulate torn state
      {:ok, gitdir} = Shoestring.Worktrees.Git.git_dir(wt.path)
      gitdir_file = Path.join(gitdir, "shoestring_worktree.json")
      assert File.exists?(gitdir_file)

      # Modify status in gitdir to "failed" while .records has "active"
      gitdir_data =
        gitdir_file
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("status", "failed")

      File.write!(gitdir_file, Jason.encode!(gitdir_data, pretty: true))

      # load_by_path and cleanup detect divergence
      assert {:error, {:record_diverged, %{records: rec, gitdir: gd}}} =
               Worktrees.get(wt.path, worktrees_dir: worktrees_dir)

      assert rec.status == :active
      assert gd.status == :failed

      assert {:error, {:record_diverged, _}} =
               Worktrees.cleanup(wt.path, policy: :safe, worktrees_dir: worktrees_dir)
    end
  end

  describe "lifecycle preservation and cleanup" do
    test "preserves failed and suspended worktrees by default", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-fail-preserve", "HEAD",
                 worktrees_dir: worktrees_dir
               )

      # Mark failed
      assert {:ok, wt_failed} =
               Worktrees.update_status(wt, :failed, worktrees_dir: worktrees_dir)

      assert {:error, {:worktree_preserved, :failed}} =
               Worktrees.cleanup(wt_failed, policy: :safe, worktrees_dir: worktrees_dir)

      assert File.dir?(wt.path)

      # Mark suspended
      assert {:ok, wt_suspended} =
               Worktrees.update_status(wt, :suspended, worktrees_dir: worktrees_dir)

      assert {:error, {:worktree_preserved, :suspended}} =
               Worktrees.cleanup(wt_suspended, policy: :safe, worktrees_dir: worktrees_dir)

      assert File.dir?(wt.path)

      # Explicit override can clean up preserved worktrees
      assert :ok =
               Worktrees.cleanup(wt_suspended,
                 policy: :safe,
                 override_preserved: true,
                 worktrees_dir: worktrees_dir
               )

      refute File.exists?(wt.path)
    end

    test "cleans up only completed and cancelled worktrees under safe policy", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-cleanable", "HEAD", worktrees_dir: worktrees_dir)

      assert {:ok, wt_done} =
               Worktrees.update_status(wt, :completed, worktrees_dir: worktrees_dir)

      # Cleanup without safe policy is rejected
      assert {:error, :cleanup_policy_required} =
               Worktrees.cleanup(wt_done, worktrees_dir: worktrees_dir)

      assert File.dir?(wt.path)

      # Cleanup with safe policy succeeds
      assert :ok = Worktrees.cleanup(wt_done, policy: :safe, worktrees_dir: worktrees_dir)
      refute File.exists?(wt.path)

      # Cancelled worktree also cleans up with safe policy
      assert {:ok, wt2} =
               Worktrees.create(repo_path, "run-cancelled", "HEAD", worktrees_dir: worktrees_dir)

      assert {:ok, wt2_canc} =
               Worktrees.update_status(wt2, :cancelled, worktrees_dir: worktrees_dir)

      assert :ok = Worktrees.cleanup(wt2_canc, policy: :safe, worktrees_dir: worktrees_dir)
      refute File.exists?(wt2.path)
    end

    test "cleanup refuses to delete unrecognized directory", %{
      worktrees_dir: worktrees_dir
    } do
      unrec = Path.join(worktrees_dir, "unrecognized_tree")
      File.mkdir_p!(unrec)
      File.write!(Path.join(unrec, "keep.txt"), "valuable data")

      assert {:error, {:unrecognized_directory, ^unrec}} =
               Worktrees.cleanup(unrec, policy: :safe, worktrees_dir: worktrees_dir)

      assert File.dir?(unrec)
      assert File.read!(Path.join(unrec, "keep.txt")) == "valuable data"
    end

    test "cleanup handles runner failure and preserves directory", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-failing-cleanup", "HEAD",
                 worktrees_dir: worktrees_dir
               )

      assert {:ok, wt_done} =
               Worktrees.update_status(wt, :completed, worktrees_dir: worktrees_dir)

      assert {:error, {:cleanup_failed, msg}} =
               Worktrees.cleanup(wt_done,
                 policy: :safe,
                 runner: FailingCleanupRunner,
                 worktrees_dir: worktrees_dir
               )

      assert msg =~ "failed to remove worktree"
      assert Worktrees.recognized?(wt.path, worktrees_dir: worktrees_dir)

      # Cleanup remains retryable
      assert :ok = Worktrees.cleanup(wt_done, policy: :safe, worktrees_dir: worktrees_dir)
      refute Worktrees.recognized?(wt.path, worktrees_dir: worktrees_dir)
    end
  end

  describe "source checkout protection" do
    test "create and cleanup strictly refuse to operate on the source repository or nested directories",
         %{
           repo_path: repo_path,
           worktrees_dir: worktrees_dir
         } do
      assert {:error, :source_checkout_protection} =
               Worktrees.create(repo_path, "run-suicide", "HEAD",
                 path: repo_path,
                 worktrees_dir: worktrees_dir
               )

      # Nested directory inside source repo is strictly rejected (E1)
      nested_path = Path.join(repo_path, "nested/worktree")

      assert {:error, :source_checkout_protection} =
               Worktrees.create(repo_path, "run-nested", "HEAD",
                 path: nested_path,
                 worktrees_dir: worktrees_dir
               )

      assert {:error, _} =
               Worktrees.cleanup(repo_path, policy: :safe, worktrees_dir: worktrees_dir)

      assert File.dir?(repo_path)
      assert File.exists?(Path.join(repo_path, "README.md"))
    end
  end

  describe "metadata failure resilience" do
    test "non-serializable metadata returns clean error without crashing", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:error, {:record_save_failed, %Protocol.UndefinedError{protocol: Jason.Encoder}}} =
               Worktrees.create(repo_path, "run-bad-meta", "HEAD",
                 metadata: %{bad_pid: self()},
                 worktrees_dir: worktrees_dir
               )
    end

    test "update_status failure restores prior record without destroying it", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:ok, wt} =
               Worktrees.create(repo_path, "run-rollback-preserve", "HEAD",
                 worktrees_dir: worktrees_dir
               )

      assert Worktrees.recognized?(wt.path, worktrees_dir: worktrees_dir)

      record_file = Shoestring.Worktrees.Record.record_path(worktrees_dir, wt.run_id)
      pre_update_bytes = File.read!(record_file)

      assert {:error, {:record_save_failed, {:gitdir_unavailable, _}}} =
               Worktrees.update_status(wt, :failed,
                 runner: FailingGitDirRunner,
                 worktrees_dir: worktrees_dir
               )

      assert File.exists?(record_file)
      assert File.read!(record_file) == pre_update_bytes
      assert Worktrees.recognized?(wt.path, worktrees_dir: worktrees_dir)
    end

    test "Record.save validates run_id format", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      assert {:ok, %Worktree{} = wt} =
               Worktrees.create(repo_path, "run-valid-id", "HEAD", worktrees_dir: worktrees_dir)

      invalid_wt = %Worktree{wt | run_id: "../escaping"}

      assert {:error, {:invalid_run_id, "../escaping"}} =
               Shoestring.Worktrees.Record.save(
                 invalid_wt,
                 worktrees_dir,
                 Shoestring.Harness.Capacity.SystemCommandRunner
               )
    end
  end

  describe "durable records, get, and list" do
    test "retrieves durable worktrees and ignores unrecognized directories", %{
      repo_path: repo_path,
      worktrees_dir: worktrees_dir
    } do
      # Pre-existing unrecognized directories from earlier iterations
      File.mkdir_p!(Path.join(worktrees_dir, "iter1-foundation"))
      File.mkdir_p!(Path.join(worktrees_dir, "iter2-fake-harness"))

      assert {:ok, wt1} =
               Worktrees.create(repo_path, "run-a", "HEAD",
                 metadata: %{"worker" => "codex"},
                 worktrees_dir: worktrees_dir
               )

      assert {:ok, wt2} =
               Worktrees.create(repo_path, "run-b", "HEAD",
                 metadata: %{"worker" => "claude"},
                 worktrees_dir: worktrees_dir
               )

      records = Worktrees.list(worktrees_dir: worktrees_dir)
      run_ids = Enum.map(records, & &1.run_id)

      assert "run-a" in run_ids
      assert "run-b" in run_ids
      assert length(records) == 2

      assert {:ok, loaded} = Worktrees.get("run-a", worktrees_dir: worktrees_dir)
      assert loaded.run_id == "run-a"
      assert loaded.metadata == %{"worker" => "codex"}

      assert {:ok, loaded_by_path} = Worktrees.get(wt2.path, worktrees_dir: worktrees_dir)
      assert loaded_by_path.run_id == "run-b"
      assert loaded_by_path.branch == wt2.branch

      assert Worktrees.recognized?(wt1.path, worktrees_dir: worktrees_dir)

      refute Worktrees.recognized?(Path.join(worktrees_dir, "iter1-foundation"),
               worktrees_dir: worktrees_dir
             )
    end
  end
end
