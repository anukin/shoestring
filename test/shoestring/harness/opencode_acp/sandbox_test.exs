defmodule Shoestring.Harness.OpencodeAcp.SandboxTest do
  @moduledoc """
  The OS sandbox an opencode Elf runs under: a profile derived from a real
  private run worktree, refusals that fail closed, enforcement checked with
  the real `sandbox-exec` on a shell (never opencode), and the plan-run
  default. Local git only; no provider CLI. Scratch directories are kept.
  """
  # Not async: one case changes the :elf_dispatch_opts application config.
  use ExUnit.Case, async: false

  alias Shoestring.Harness.{Error, OpencodeAcp, RunRecord, RunRequest}
  alias Shoestring.Harness.OpencodeAcp.Sandbox
  alias Shoestring.Harness.Dispatch.ElfEffect
  alias Shoestring.Worktrees

  setup do
    base = Path.join(System.tmp_dir!(), "shoestring-opencode-sandbox-#{Ecto.UUID.generate()}")
    source = Path.join(base, "source")
    File.mkdir_p!(source)
    git!(source, ["init", "-q", "-b", "main"])
    git!(source, ["config", "user.name", "Fixture Author"])
    git!(source, ["config", "user.email", "fixture@example.test"])
    File.write!(Path.join(source, "code.txt"), "before\n")
    git!(source, ["add", "code.txt"])
    git!(source, ["-c", "commit.gpgsign=false", "commit", "-qm", "Fixture base"])
    home = Path.join(base, "home")
    File.mkdir_p!(Path.join(home, ".local/share/opencode"))
    File.mkdir_p!(Path.join(home, ".config/opencode"))
    File.mkdir_p!(Path.join(home, "shared"))
    File.write!(Path.join(home, "shared/AGENTS.md"), "instructions\n")
    File.write!(Path.join(home, "shared/private.txt"), "private\n")
    File.ln_s!(Path.join(home, "shared/AGENTS.md"), Path.join(home, ".config/opencode/AGENTS.md"))
    File.mkdir_p!(Path.join(home, ".opencode/bin"))
    # The service's state lives under the home directory in production, so
    # the worktrees do here: home reads are denied except the run's paths.
    %{source: source, worktrees: Path.join(home, "state/worktrees"), home: home}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp worktree!(ctx, private?) do
    {:ok, wt} =
      Worktrees.create(ctx.source, Ecto.UUID.generate(), "HEAD",
        private_git: private?,
        worktrees_dir: ctx.worktrees
      )

    wt
  end

  defp prepare(ctx, wt, ref \\ nil) do
    result =
      Sandbox.prepare(wt.path, ref || wt.workspace_ref,
        worktrees_dir: ctx.worktrees,
        home: ctx.home,
        env: %{},
        executable: Path.join(ctx.home, ".opencode/bin/opencode")
      )

    with {:ok, %{temp_dir: dir}} <- result, do: on_exit(fn -> Sandbox.release(dir) end)
    result
  end

  defp physical(path), do: Shoestring.Harness.CodexAppServer.GitSandbox.physical_path(path)

  test "a private run worktree gets a profile that launches opencode acp", ctx do
    wt = worktree!(ctx, true)
    assert {:ok, sandbox} = prepare(ctx, wt)

    assert sandbox.command == "/usr/bin/sandbox-exec"
    assert ["-p", profile, executable, "acp"] = sandbox.args
    assert executable == physical(Path.join(ctx.home, ".opencode/bin/opencode"))
    assert sandbox.identity =~ ~r/^macos_seatbelt:v1:sha256:[0-9a-f]{64}$/

    assert profile =~ ~s[(subpath "#{physical(wt.path)}")]
    assert profile =~ ~s[(subpath "#{physical(Path.join(ctx.home, ".local/share/opencode"))}")]
    assert profile =~ ~s[(deny file-read* (subpath "#{physical(ctx.home)}"))]
    refute profile =~ physical(ctx.source)

    assert {"GIT_CONFIG_GLOBAL", "/dev/null"} in sandbox.env
    assert {"PYTHONDONTWRITEBYTECODE", "1"} in sandbox.env
    assert {"TMPDIR", tmp} = List.keyfind(sandbox.env, "TMPDIR", 0)
    assert File.dir?(tmp)

    # opencode keeps its own directories; nothing else resolves under home.
    assert {"HOME", ^tmp} = List.keyfind(sandbox.env, "HOME", 0)
    assert {"XDG_DATA_HOME", data} = List.keyfind(sandbox.env, "XDG_DATA_HOME", 0)
    assert data == physical(Path.join(ctx.home, ".local/share"))
    assert {"OPENCODE_DISABLE_CLAUDE_CODE", "1"} in sandbox.env
    refute List.keyfind(sandbox.env, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", 0)
  end

  test "anything but a registered private run worktree fails closed", ctx do
    shared = worktree!(ctx, false)
    assert {:error, :not_a_private_run_worktree} = prepare(ctx, shared)

    wt = worktree!(ctx, true)
    assert {:error, :invalid_run_worktree} = prepare(ctx, wt, "someone-else")

    assert {:error, :no_sandbox_mechanism} =
             Sandbox.prepare(wt.path, wt.workspace_ref,
               worktrees_dir: ctx.worktrees,
               sandbox_exec: "/nonexistent/sandbox-exec"
             )
  end

  test "the profile lets a process write the worktree and opencode's data, nothing else", ctx do
    wt = worktree!(ctx, true)
    {:ok, %{args: ["-p", profile | _], env: env}} = prepare(ctx, wt)
    {"TMPDIR", tmp} = List.keyfind(env, "TMPDIR", 0)

    write = fn path ->
      {_, status} =
        System.cmd(
          "/usr/bin/sandbox-exec",
          ["-p", profile, "/bin/sh", "-c", ~s(echo x > "$1"), "sh", path],
          stderr_to_stdout: true
        )

      status == 0
    end

    assert write.(Path.join(wt.path, "allowed.txt"))
    assert write.(Path.join(ctx.home, ".local/share/opencode/state.db"))
    assert write.(Path.join(tmp, "scratch"))

    # Git inside the worktree reads the private store it links to.
    {status_out, 0} =
      System.cmd(
        "/usr/bin/sandbox-exec",
        ["-p", profile, "git", "-C", wt.path, "status", "--short"],
        env: Enum.to_list(env),
        stderr_to_stdout: true
      )

    assert status_out =~ "allowed.txt"

    read = fn path ->
      {_, status} =
        System.cmd("/usr/bin/sandbox-exec", ["-p", profile, "/bin/cat", path],
          stderr_to_stdout: true
        )

      status == 0
    end

    # A config entry linked elsewhere is readable through its link; its
    # neighbours are not.
    assert read.(Path.join(ctx.home, ".config/opencode/AGENTS.md"))
    refute read.(Path.join(ctx.home, "shared/private.txt"))

    refute write.(Path.join(ctx.source, "code.txt"))
    refute write.(Path.join(ctx.home, "outside.txt"))

    refute write.(
             Path.join(System.tmp_dir!(), "shoestring-opencode-escape-#{Ecto.UUID.generate()}")
           )

    assert File.read!(Path.join(ctx.source, "code.txt")) == "before\n"
  end

  test "a sandboxed adapter start refuses before launching anything", ctx do
    shared = worktree!(ctx, false)

    assert {:error, %Error{code: "sandbox_unavailable"}} =
             OpencodeAcp.start(request(shared.workspace_ref), %{
               live: true,
               sandbox: true,
               workdir: shared.path,
               model: "opencode/fixture",
               sandbox_worktrees_dir: ctx.worktrees,
               executable: "/nonexistent/opencode"
             })
  end

  test "plan-bound opencode runs are always sandboxed unless the launch is configured" do
    binding = %{"model" => "opencode/fixture", "role" => "Worker"}
    key = Shoestring.Cobbler.ExecutionProfile.key()

    plan = %RunRecord{provider_id: "opencode_acp", extensions: %{key => binding}}
    assert {:ok, opts} = ElfEffect.launch_opts(plan)
    assert opts[:adapter] == OpencodeAcp
    assert opts[:process_owner] == :adapter
    assert opts[:adapter_opts][:sandbox] == true
    assert opts[:adapter_opts][:model] == "opencode/fixture"

    previous = Application.get_env(:shoestring, :elf_dispatch_opts)

    try do
      Application.put_env(:shoestring, :elf_dispatch_opts,
        adapter_opts: %{live: true, command: "/path/to/launcher"}
      )

      assert {:ok, opts} = ElfEffect.launch_opts(plan)
      refute Map.has_key?(opts[:adapter_opts], :sandbox)
    after
      if previous,
        do: Application.put_env(:shoestring, :elf_dispatch_opts, previous),
        else: Application.delete_env(:shoestring, :elf_dispatch_opts)
    end
  end

  defp request(workspace_ref) do
    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        workspace_ref: workspace_ref,
        prompt: "Check the fixture",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: [],
        dispatch_id: Ecto.UUID.generate()
      })

    request
  end
end
