defmodule ShoestringWeb.RunNewPrivateStorageTest do
  @moduledoc """
  `/runs/new` Claude and Codex runs get private per-run Git storage, and a
  Claude run there is launched sandboxed (iteration 8). Hermetic: a fixture
  repository, no provider CLI; the provider run is not admitted (no capacity
  reading), only its worktree and launch options are checked.
  """
  use ShoestringWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Shoestring.Harness.CodexAppServer.GitSandbox
  alias Shoestring.Harness.Dispatch.ElfEffect
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Worktrees

  setup do
    unique = "#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}"
    tmp_root = Path.join(System.tmp_dir!(), "shoestring_private_manual_#{unique}")
    repo_path = Path.join(tmp_root, "source_repo")
    File.mkdir_p!(repo_path)

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.name", "Shoestring Test"],
          ["config", "user.email", "test@shoestring.local"]
        ],
        do: {_, 0} = System.cmd("git", args, cd: repo_path)

    File.write!(Path.join(repo_path, "README.md"), "# Fixture\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: repo_path)

    {_, 0} =
      System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-qm", "Base"], cd: repo_path)

    prev_roots = Application.get_env(:shoestring, :manual_run_allowed_repo_roots)
    Application.put_env(:shoestring, :manual_run_allowed_repo_roots, [tmp_root])

    on_exit(fn ->
      if prev_roots,
        do: Application.put_env(:shoestring, :manual_run_allowed_repo_roots, prev_roots),
        else: Application.delete_env(:shoestring, :manual_run_allowed_repo_roots)
    end)

    {:ok, repo_path: repo_path}
  end

  test "a Claude manual run gets private storage and a sandboxed launch", %{
    conn: conn,
    repo_path: repo_path
  } do
    before = MapSet.new(Worktrees.list(), & &1.run_id)
    {:ok, view, _html} = live(conn, ~p"/runs/new")
    _ = render_submit(view, :start_run, %{"run" => params(repo_path, "claude")})

    assert [wt] = Enum.reject(Worktrees.list(), &MapSet.member?(before, &1.run_id))
    assert wt.metadata["shoestring.manual:source"] == repo_path
    refute GitSandbox.physical_path(wt.repo_path) == GitSandbox.physical_path(repo_path)
    assert {:ok, %{"writableRoots" => _}} = GitSandbox.policy(wt.path, wt.workspace_ref)

    run = %RunRecord{
      provider_id: "claude_headless_stream_json",
      extensions: %{},
      workspace_ref: wt.workspace_ref
    }

    assert {:ok, opts} = ElfEffect.launch_opts(run)
    assert opts[:adapter_opts][:sandbox] == true

    # A run in shared storage (as manual runs were before) keeps its launch.
    {:ok, shared} = Worktrees.create(repo_path, Ecto.UUID.generate(), "HEAD")
    assert {:ok, opts} = ElfEffect.launch_opts(%{run | workspace_ref: shared.workspace_ref})
    refute Map.has_key?(opts[:adapter_opts], :sandbox)
  end

  test "a Codex manual run gets private Git roots without registering in the source", %{
    conn: conn,
    repo_path: repo_path
  } do
    before = MapSet.new(Worktrees.list(), & &1.run_id)
    {:ok, view, _html} = live(conn, ~p"/runs/new")
    _ = render_submit(view, :start_run, %{"run" => params(repo_path, "codex")})
    assert [wt] = Enum.reject(Worktrees.list(), &MapSet.member?(before, &1.run_id))
    assert wt.metadata["shoestring.manual:source"] == repo_path
    refute GitSandbox.physical_path(wt.repo_path) == GitSandbox.physical_path(repo_path)
    assert {:ok, %{"writableRoots" => roots}} = GitSandbox.policy(wt.path, wt.workspace_ref)
    assert GitSandbox.physical_path(wt.path) in roots
    source_git = Path.join(GitSandbox.physical_path(repo_path), ".git")
    refute Enum.any?(roots, &String.starts_with?(&1, source_git))
    refute File.exists?(Path.join(repo_path, ".git/worktrees"))
  end

  test "a Fake manual run retains shared Git storage", %{conn: conn, repo_path: repo_path} do
    before = MapSet.new(Worktrees.list(), & &1.run_id)
    {:ok, view, _html} = live(conn, ~p"/runs/new")
    _ = render_submit(view, :start_run, %{"run" => params(repo_path, "fake")})
    assert [wt] = Enum.reject(Worktrees.list(), &MapSet.member?(before, &1.run_id))
    assert wt.repo_path == GitSandbox.physical_path(repo_path)
    refute Map.has_key?(wt.metadata, "shoestring.manual:source")
    assert {:ok, nil} = GitSandbox.policy(wt.path, wt.workspace_ref)
  end

  defp params(repo_path, provider) do
    %{
      "repo_path" => repo_path,
      "base_revision" => "HEAD",
      "provider" => provider,
      "prompt" => "Private storage prompt",
      "timeout_seconds" => "60",
      "max_events" => "100",
      "lease_seconds" => "300"
    }
  end
end
