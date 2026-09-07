defmodule Shoestring.Test.ElfWorktreeFixture do
  @moduledoc """
  Creates a real source repository and a Shoestring-managed worktree for Elf
  integration evaluations.

  The fixture deliberately leaves a marker file in the worktree. Child
  commands guard their mutations on that marker so a base-commit run without
  worktree `cwd` fails its assertions without touching the application checkout.
  """

  alias Shoestring.Worktrees

  @doc "Creates a unique fixture and its Shoestring-managed worktree."
  def create!(run_id) do
    # Randomized so a killed prior run's leftover can never be collided with:
    # cleanup!/1 only runs via the caller's on_exit, which cannot register for
    # a create! that raised partway.
    root =
      Path.join(
        System.tmp_dir!(),
        "shoestring_elf_eval_#{Ecto.UUID.generate()}_#{System.unique_integer([:positive])}"
      )

    source_repo = Path.join(root, "source")
    worktrees_dir = Shoestring.State.path(:worktrees)

    File.mkdir_p!(source_repo)
    File.mkdir_p!(worktrees_dir)

    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: source_repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "Shoestring Eval"], cd: source_repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "eval@shoestring.local"], cd: source_repo)

    File.write!(Path.join(source_repo, "fixture.txt"), "fixture baseline\n")
    File.write!(Path.join(source_repo, "README.md"), "source baseline\n")

    {_, 0} = System.cmd("git", ["add", "."], cd: source_repo)

    {_, 0} =
      System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-m", "fixture baseline"],
        cd: source_repo
      )

    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source_repo)

    {:ok, worktree} =
      Worktrees.create(source_repo, run_id, worktrees_dir: worktrees_dir)

    fixture = %{
      root: root,
      source_repo: source_repo,
      worktrees_dir: worktrees_dir,
      worktree: worktree,
      base_commit: String.trim(head)
    }

    fixture
  end

  @doc "Captures Git identity, status, and a byte hash of the whole working tree."
  def source_snapshot(source_repo) do
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source_repo)

    {status, 0} =
      System.cmd("git", ["status", "--porcelain=v1", "--untracked-files=all"], cd: source_repo)

    {files, 0} =
      System.cmd("git", ["ls-files", "-co", "--exclude-standard", "-z"], cd: source_repo)

    paths = String.split(files, <<0>>, trim: true)

    working_tree_hash =
      paths
      |> Enum.sort()
      |> Enum.map(fn path ->
        case File.read(Path.join(source_repo, path)) do
          {:ok, contents} -> path <> <<0>> <> contents
          # A file indexed by git but deleted from disk (uncommitted deletion)
          # must report a snapshot difference, not raise File.Error.
          {:error, _} -> path <> <<0>> <> "<<missing>>"
        end
      end)
      |> IO.iodata_to_binary()
      |> then(fn bytes -> :crypto.hash(:sha256, bytes) end)
      |> Base.encode16(case: :lower)

    %{
      head: String.trim(head),
      status: status,
      working_tree_hash: working_tree_hash
    }
  end

  @doc "Removes the fixture worktree and temporary source repository."
  def cleanup!(%{worktree: worktree, worktrees_dir: worktrees_dir, root: root}) do
    _ =
      Worktrees.cleanup(worktree,
        policy: :safe,
        override_active: true,
        override_preserved: true,
        delete_branch: true,
        worktrees_dir: worktrees_dir
      )

    File.rm_rf(root)
  end
end
