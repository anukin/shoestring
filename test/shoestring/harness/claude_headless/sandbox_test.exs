defmodule Shoestring.Harness.ClaudeHeadless.SandboxTest do
  @moduledoc """
  Sandboxed Claude launches: settings derived from a real private run
  worktree, refusals that fail closed, the launch argv, and the plan-run
  default. Local git only; no provider CLI. Scratch directories are kept.
  """
  # Not async: one case changes the :elf_dispatch_opts application config.
  use ExUnit.Case, async: false

  alias Shoestring.Harness.{ClaudeHeadless, Error, RunRecord, RunRequest}
  alias Shoestring.Harness.ClaudeHeadless.{Sandbox, Session}
  alias Shoestring.Harness.Dispatch.ElfEffect
  alias Shoestring.Worktrees

  setup do
    base = Path.join(System.tmp_dir!(), "shoestring-claude-sandbox-#{Ecto.UUID.generate()}")
    source = Path.join(base, "source")
    worktrees = Path.join(base, "worktrees")
    File.mkdir_p!(source)
    git!(source, ["init", "-q", "-b", "main"])
    git!(source, ["config", "user.name", "Fixture Author"])
    git!(source, ["config", "user.email", "fixture@example.test"])
    File.write!(Path.join(source, "code.txt"), "before\n")
    git!(source, ["add", "code.txt"])
    git!(source, ["-c", "commit.gpgsign=false", "commit", "-qm", "Fixture base"])
    %{source: source, worktrees: worktrees, home: Path.join(base, "home")}
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

  defp prepare(ctx, wt, ref \\ nil),
    do:
      Sandbox.prepare(wt.path, ref || wt.workspace_ref,
        worktrees_dir: ctx.worktrees,
        home: ctx.home
      )

  test "a private run worktree gets write roots, read limits, flags and a home-free Git", ctx do
    wt = worktree!(ctx, true)
    assert {:ok, sandbox} = prepare(ctx, wt)

    filesystem = sandbox.settings["sandbox"]["filesystem"]
    [worktree, gitdir, objects, heads, logs] = filesystem["allowWrite"]
    store = Path.dirname(objects)

    assert Path.basename(worktree) == Path.basename(wt.path)
    assert Path.basename(Path.dirname(Path.dirname(store))) == "worktrees"
    assert Path.basename(Path.dirname(store)) == ".git-repositories"
    assert Path.dirname(gitdir) == Path.join(store, "worktrees")
    assert heads == Path.join(store, "refs/heads")
    assert logs == Path.join(store, "logs/refs/heads")
    assert filesystem["allowRead"] == [worktree, store]
    assert filesystem["denyRead"] == [Path.expand(ctx.home)]

    # The source repository is never writable.
    source = git!(ctx.source, ["rev-parse", "--show-toplevel"])
    refute Enum.any?(filesystem["allowWrite"], &String.starts_with?(&1, source))

    assert sandbox.settings["sandbox"]["network"] == %{"allowedDomains" => []}
    assert sandbox.settings["sandbox"]["allowUnsandboxedCommands"] == false

    options = sandbox.options
    assert ["--permission-mode", "dontAsk"] == Enum.slice(options, -4, 2)
    assert "--restricted" in options
    refute "--dangerously-skip-permissions" in options
    settings = Enum.at(options, Enum.find_index(options, &(&1 == "--settings")) + 1)
    assert Jason.decode!(settings) == sandbox.settings

    assert {"GIT_CONFIG_GLOBAL", "/dev/null"} in sandbox.env
    assert {"GIT_CONFIG_VALUE_1", "/dev/null"} in sandbox.env
  end

  test "anything but a registered private run worktree fails closed", ctx do
    shared = worktree!(ctx, false)
    assert {:error, :not_a_private_run_worktree} = prepare(ctx, shared)

    wt = worktree!(ctx, true)
    assert {:error, :invalid_run_worktree} = prepare(ctx, wt, "someone-else")

    [_worktree, _gitdir, objects | _] =
      prepare(ctx, wt) |> elem(1) |> get_in([:settings, "sandbox", "filesystem", "allowWrite"])

    File.mkdir_p!(Path.join(objects, "info"))
    File.write!(Path.join([objects, "info", "alternates"]), "/elsewhere\n")
    assert {:error, :invalid_run_worktree} = prepare(ctx, wt)
  end

  test "a sandboxed adapter start refuses before launching anything", ctx do
    shared = worktree!(ctx, false)

    assert {:error, %Error{code: "sandbox_unavailable"}} =
             ClaudeHeadless.start(request(shared.workspace_ref), %{
               live: true,
               sandbox: true,
               workdir: shared.path,
               sandbox_worktrees_dir: ctx.worktrees,
               transport: Shoestring.Test.ArgvCaptureTransport
             })
  end

  test "sandbox flags go before the prompt and replace the permission bypass" do
    session =
      start_supervised!(
        {Session,
         [
           run_request: request("workspace/fixture"),
           owner: self(),
           transport: Shoestring.Test.ArgvCaptureTransport,
           model: "opus",
           permission_bypass: true,
           sandbox_options: ["--permission-mode", "dontAsk"]
         ]}
      )

    args = :sys.get_state(:sys.get_state(session).transport_pid) |> Keyword.fetch!(:args)
    assert Enum.take(args, -3) == ["--permission-mode", "dontAsk", "Check the fixture"]
    assert "--tools=Bash" in args
    refute "--dangerously-skip-permissions" in args
  end

  test "plan-bound Claude runs are sandboxed by default; manual and configured launches are not" do
    binding = %{"model" => "opus", "role" => "Worker"}
    key = Shoestring.Cobbler.ExecutionProfile.key()

    plan = %RunRecord{provider_id: "claude_headless_stream_json", extensions: %{key => binding}}
    assert {:ok, opts} = ElfEffect.launch_opts(plan)
    assert opts[:adapter_opts][:sandbox] == true
    assert opts[:adapter_opts][:model] == "opus"

    manual = %RunRecord{provider_id: "claude_headless_stream_json", extensions: %{}}
    assert {:ok, opts} = ElfEffect.launch_opts(manual)
    refute Map.has_key?(opts[:adapter_opts], :sandbox)

    codex = %RunRecord{provider_id: "codex_app_server_stdio", extensions: %{key => binding}}
    assert {:ok, opts} = ElfEffect.launch_opts(codex)
    refute Map.has_key?(opts[:adapter_opts], :sandbox)

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
    {:ok, req} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        dispatch_id: "00000000-0000-4000-8000-000000000003",
        workspace_ref: workspace_ref,
        prompt: "Check the fixture",
        policy: %{mode: "supervised"},
        requested_capabilities: []
      })

    req
  end
end
