defmodule Shoestring.Harness.CodexAppServer.GitSandboxTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.GateProcess
  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.CodexAppServer.{GitSandbox, Session}
  alias Shoestring.Harness.RunRequest
  alias Shoestring.Worktrees

  setup do
    source = Path.join(System.tmp_dir!(), "shoestring-private-git-#{Ecto.UUID.generate()}")
    File.mkdir_p!(source)
    git!(source, ["init", "-b", "main"])
    git!(source, ["config", "user.name", "Fixture Author"])
    git!(source, ["config", "user.email", "fixture@example.test"])
    File.write!(Path.join(source, "code.txt"), "before\n")
    git!(source, ["add", "code.txt"])
    git!(source, ["-c", "commit.gpgsign=false", "commit", "-m", "Fixture base"])
    %{source: source, baseline: snapshot(source)}
  end

  test "private commits and successor storage leave every source Git byte unchanged", ctx do
    wt = create!(ctx.source)
    refute wt.repo_path == ctx.source
    refute File.exists?(Path.join(wt.repo_path, "objects/info/alternates"))
    assert git!(wt.path, ["remote"]) == ""
    assert git!(wt.path, ["config", "user.name"]) == "Fixture Author"
    File.write!(Path.join(wt.path, "code.txt"), "accepted\n")
    git!(wt.path, ["add", "code.txt"])
    git!(wt.path, ["-c", "commit.gpgsign=false", "commit", "-m", "Task one"])
    commit = git!(wt.path, ["rev-parse", "HEAD"])

    successor = create!(wt.path, commit)
    refute successor.repo_path == wt.repo_path
    assert git!(successor.path, ["rev-parse", "HEAD"]) == commit
    assert File.read!(Path.join(successor.path, "code.txt")) == "accepted\n"
    assert git!(successor.path, ["status", "--porcelain"]) == ""
    assert snapshot(ctx.source) == ctx.baseline
  end

  for resume <- [false, true] do
    test "#{if resume, do: "resumed", else: "fresh"} turn receives only owned private Git roots",
         ctx do
      wt = create!(ctx.source)
      {:ok, policy} = GitSandbox.policy(wt.path, wt.workspace_ref)
      assert policy["networkAccess"] == false
      assert policy["excludeSlashTmp"] == true
      assert policy["excludeTmpdirEnvVar"] == true
      common = git!(wt.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
      source = git!(ctx.source, ["rev-parse", "--show-toplevel"])
      assert git!(wt.path, ["rev-parse", "--show-toplevel"]) in policy["writableRoots"]
      assert Path.join(common, "objects") in policy["writableRoots"]
      refute common in policy["writableRoots"]
      refute Enum.any?(policy["writableRoots"], &String.starts_with?(&1, source))
      refute Path.join(common, "hooks") in policy["writableRoots"]

      transport =
        start_supervised!(
          {FakeTransport,
           auto_respond: %{
             "initialize" => %{"result" => %{}},
             "thread/start" => %{"result" => %{"thread" => %{"id" => "fixture-thread"}}},
             "thread/resume" => %{"result" => %{"thread" => %{"id" => "fixture-thread"}}},
             "turn/start" => %{"result" => %{"turn" => %{"id" => "fixture-turn"}}}
           }}
        )

      session =
        start_supervised!(
          {Session,
           run_request: request(wt),
           workdir: wt.path,
           transport: FakeTransport,
           transport_pid: transport,
           auto_handshake: false,
           model: "fixture-model",
           resume: unquote(resume),
           thread_id: "fixture-thread"}
        )

      :ok = FakeTransport.set_owner(transport, session)
      assert {:ok, _} = Session.await_run_identity(session, 5_000)
      frames = FakeTransport.get_sent_frames(transport)
      turn = Enum.find(frames, &(&1["method"] == "turn/start"))["params"]

      thread =
        Enum.find(frames, &(&1["method"] in ["thread/start", "thread/resume"]))["params"]

      # Before 2026-11-01 the turn carried the legacy workspaceWrite policy,
      # under which a command could read the whole home directory. Now the
      # thread carries Shoestring's permission profile: home denied, only
      # the run's own roots writable, no network.
      refute Map.has_key?(turn, "sandboxPolicy")
      refute Map.has_key?(thread, "sandbox")
      assert thread["config"] == GitSandbox.permissions(policy)
      %{"default_permissions" => name, "permissions" => profiles} = thread["config"]
      filesystem = profiles[name]["filesystem"]
      assert filesystem[GitSandbox.physical_path(System.user_home!())] == "deny"
      assert filesystem[":root"] == "read"

      assert Enum.sort(for {path, "write"} <- filesystem, do: path) ==
               Enum.sort(policy["writableRoots"])

      refute Map.has_key?(profiles[name], "network")
      assert turn["cwd"] == wt.path
      assert turn["approvalPolicy"] == "never"
      assert turn["model"] == "fixture-model"
      assert snapshot(ctx.source) == ctx.baseline
    end
  end

  # Home is denied beside the run's own paths, never as a whole: a denied
  # ancestor breaks Git's realpath of a private worktree's `.git` file
  # (VERIFIED offline with Codex 0.166.0).
  test "a home holding the worktrees is denied beside the run's paths, not above them", ctx do
    home = Path.join(System.tmp_dir!(), "shoestring-home-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(home) end)
    File.mkdir_p!(Path.join(home, ".ssh"))
    File.write!(Path.join(home, ".gitconfig"), "")
    root = Path.join([home, "Library", "Shoestring", "worktrees"])
    File.mkdir_p!(Path.join([home, "Library", "Keychains"]))
    File.mkdir_p!(Path.join([home, "Library", "Shoestring", "backups"]))

    {:ok, wt} =
      Worktrees.create(ctx.source, Ecto.UUID.generate(), "HEAD",
        private_git: true,
        worktrees_dir: root
      )

    {:ok, other} =
      Worktrees.create(ctx.source, Ecto.UUID.generate(), "HEAD",
        private_git: true,
        worktrees_dir: root
      )

    {:ok, policy} = GitSandbox.policy(wt.path, wt.workspace_ref, root)

    %{"permissions" => %{"shoestring_run" => %{"filesystem" => fs}}} =
      GitSandbox.permissions(policy, home)

    home = GitSandbox.physical_path(home)
    root = GitSandbox.physical_path(root)
    [_worktree, _gitdir, objects | _] = policy["writableRoots"]

    for path <- [".ssh", ".gitconfig", "Library/Keychains", "Library/Shoestring/backups"],
        do: assert(fs[Path.join(home, path)] == "deny", path)

    # Another run's worktree and private storage are denied too.
    assert fs[GitSandbox.physical_path(other.path)] == "deny"
    assert fs[Path.join([root, ".git-repositories", other.run_id])] == "deny"

    # Nothing on the way to the run is denied; its own roots are writable and
    # its store readable.
    for dir <- [home, Path.join(home, "Library"), Path.join(home, "Library/Shoestring"), root],
        do: refute(Map.has_key?(fs, dir), dir)

    for path <- policy["writableRoots"], do: assert(fs[path] == "write")
    assert fs[Path.dirname(objects)] == "read"
    assert fs[":root"] == "read"

    # A read-only profile follows a private worktree's `.git` file to its
    # Git directories, which `git log` reads.
    %{"permissions" => %{"shoestring_run" => %{"filesystem" => ro}}} =
      GitSandbox.read_only_permissions([wt.path], home)

    gitdir = git!(wt.path, ["rev-parse", "--absolute-git-dir"])
    common = git!(wt.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    assert ro[GitSandbox.physical_path(wt.path)] == "read"
    assert ro[GitSandbox.physical_path(gitdir)] == "read"
    assert ro[GitSandbox.physical_path(common)] == "read"
    refute "write" in Map.values(ro)
    assert ro[Path.join(home, ".ssh")] == "deny"
  end

  test "codex exec flags carry the same profile as TOML values" do
    profile = GitSandbox.read_only_permissions(["/nowhere/repo"], "/nowhere/home")

    assert GitSandbox.config_flags(profile) == [
             "-c",
             ~s(default_permissions="shoestring_run"),
             "-c",
             ~s(permissions.shoestring_run.filesystem={"/nowhere/home"="deny","/nowhere/repo"="read",":root"="read"})
           ]
  end

  test "shared source metadata never becomes a writable root", ctx do
    wt = create!(ctx.source, "HEAD", false)
    assert {:ok, nil} = GitSandbox.policy(wt.path, wt.workspace_ref)
  end

  test "a custom worktree path cannot place private storage inside the source", ctx do
    target = Path.join(System.tmp_dir!(), "shoestring-external-#{Ecto.UUID.generate()}")

    assert {:error, :source_checkout_protection} =
             Worktrees.create(ctx.source, Ecto.UUID.generate(), "HEAD",
               private_git: true,
               worktrees_dir: ctx.source,
               path: target
             )

    assert snapshot(ctx.source) == ctx.baseline
    refute File.exists?(target)
  end

  test "private storage refuses a symlinked parent without writing through it", ctx do
    root = Path.join(System.tmp_dir!(), "shoestring-parent-#{Ecto.UUID.generate()}")
    elsewhere = Path.join(root, "elsewhere")
    File.mkdir_p!(elsewhere)
    File.ln_s!(elsewhere, Path.join(root, ".git-repositories"))

    assert {:error, :unsafe_private_git_parent} =
             Worktrees.create(ctx.source, Ecto.UUID.generate(), "HEAD",
               private_git: true,
               worktrees_dir: root
             )

    assert File.ls!(elsewhere) == []
    assert snapshot(ctx.source) == ctx.baseline
  end

  test "a mismatched workspace is refused", ctx do
    wt = create!(ctx.source)
    assert {:error, :invalid_git_sandbox_binding} = GitSandbox.policy(wt.path, "other-run")
  end

  test "redirected common metadata is refused before transport launch", ctx do
    wt = create!(ctx.source)
    gitdir = git!(wt.path, ["rev-parse", "--absolute-git-dir"])
    File.write!(Path.join(gitdir, "commondir"), Path.join(ctx.source, ".git"))
    assert {:error, :invalid_git_sandbox_binding} = GitSandbox.policy(wt.path, wt.workspace_ref)

    assert {:error, :invalid_git_sandbox_binding} =
             Session.start_link(
               workdir: wt.path,
               run_request: request(wt),
               command: "not-a-provider"
             )
  end

  test "symlinked Git roots are refused", ctx do
    wt = create!(ctx.source)
    objects = Path.join(wt.repo_path, "objects")
    :ok = File.rename(objects, objects <> "-preserved")
    :ok = File.ln_s(Path.join(ctx.source, ".git/objects"), objects)
    assert {:error, :invalid_git_sandbox_binding} = GitSandbox.policy(wt.path, wt.workspace_ref)
    assert snapshot(ctx.source) == ctx.baseline
  end

  defp create!(source, base \\ "HEAD", private? \\ true) do
    {:ok, wt} = Worktrees.create(source, Ecto.UUID.generate(), base, private_git: private?)
    wt
  end

  defp request(wt) do
    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        workspace_ref: wt.workspace_ref,
        prompt: "Implement the task",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: [],
        dispatch_id: Ecto.UUID.generate()
      })

    request
  end

  defp git!(cwd, args) do
    {:ok, %{exit_status: 0, output: output}} =
      GateProcess.run(["git" | args], cwd, 15_000, 65_536)

    String.trim(output)
  end

  defp snapshot(source) do
    Path.wildcard(Path.join(source, "**/*"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, source), :crypto.hash(:sha256, File.read!(&1))})
  end
end
