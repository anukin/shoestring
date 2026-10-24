defmodule Shoestring.Cobbler.GateSandboxTest do
  @moduledoc """
  Plan gates run confined (iteration 8, work package 0). Real `sandbox-exec`
  and `python3` gates over a registered private run worktree that lives under
  a scratch home directory; no provider, and no network beyond a localhost
  listener the test owns. The read, write, network and environment cases
  fail against `b94f477`, where gates ran with the service's access.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Cobbler.{GateProcess, PlanGateRunner}
  alias Shoestring.Worktrees

  @moduletag :tmp_dir

  @token_var "SHOESTRING_GATE_PROBE_TOKEN"

  # Records what the gate could do; the assertions are made by the test.
  @probe ~S"""
  import errno, json, os, socket, tempfile, unittest

  class Probe(unittest.TestCase):
      def test_probe(self):
          cfg = json.load(open("probe.json"))
          report = {}

          def attempt(name, action):
              try:
                  report[name] = action()
              except OSError as error:
                  report[name] = "denied:" + errno.errorcode.get(error.errno, str(error.errno))

          def write(path):
              with open(path, "w") as handle:
                  handle.write("probe")
              return "written"

          def scratch():
              os.makedirs("scratch", exist_ok=True)
              return write("scratch/ok.txt")

          def git_link():
              open(".git", "r+").close()
              return "writable"

          def connect():
              socket.create_connection(("127.0.0.1", cfg["port"]), timeout=2).close()
              return "connected"

          attempt("read_inside", lambda: open("inside.txt").read().strip())
          attempt("read_outside", lambda: open(cfg["secret"]).read().strip())
          attempt("list_home", lambda: sorted(os.listdir(cfg["home"])))
          attempt("write_outside", lambda: write(cfg["outside"]))
          attempt("write_worktree", scratch)
          attempt("write_tmp", lambda: write(os.path.join(tempfile.gettempdir(), "probe.txt")))
          attempt("git_link", git_link)
          attempt("connect", connect)
          report["token"] = os.environ.get(cfg["token_var"])
          report["path"] = bool(os.environ.get("PATH"))
          report["home_is_tmp"] = os.environ.get("HOME") == os.environ.get("TMPDIR")
          report["tmpdir"] = os.environ.get("TMPDIR")
          print("PROBE " + json.dumps(report), flush=True)
  """

  @hang ~S"""
  import os, signal, unittest

  class Hang(unittest.TestCase):
      def test_hang(self):
          rd, wr = os.pipe()
          if os.fork() == 0:
              signal.signal(signal.SIGTERM, signal.SIG_IGN)
              os.write(wr, b"ready")
              signal.pause()
          os.read(rd, 5)
          os.makedirs("scratch", exist_ok=True)
          with open("scratch/hang.pgid", "w") as handle:
              handle.write("%d %d" % (os.getpgrp(), os.getpid()))
          signal.pause()
  """

  @flood ~S"""
  import os, unittest

  class Flood(unittest.TestCase):
      def test_flood(self):
          os.write(1, b"x" * 70000)
  """

  setup %{tmp_dir: home} do
    secret = "synthetic-secret-#{Ecto.UUID.generate()}"
    File.write!(Path.join(home, "secret.txt"), secret)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    token = "synthetic-gate-token-#{Ecto.UUID.generate()}"
    System.put_env(@token_var, token)
    on_exit(fn -> System.delete_env(@token_var) end)

    outside = Path.join(home, "outside.txt")
    source = Path.join(home, "source")

    files = %{
      ".gitignore" => "scratch/\n",
      "inside.txt" => "inside\n",
      "probe.json" =>
        Jason.encode!(%{
          secret: Path.join(home, "secret.txt"),
          home: home,
          outside: outside,
          port: port,
          token_var: @token_var
        }),
      "test/__init__.py" => "",
      "test/test_probe.py" => @probe,
      "test/test_hang.py" => @hang,
      "test/test_flood.py" => @flood
    }

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(source, path)))
      File.write!(Path.join(source, path), content)
    end

    git!(source, ["init", "-b", "main"])
    git!(source, ["config", "user.name", "Fixture"])
    git!(source, ["config", "user.email", "fixture@example.invalid"])
    git!(source, ["add", "."])
    git!(source, ["-c", "commit.gpgsign=false", "commit", "-m", "Gate sandbox fixture"])

    worktrees_dir = Path.join(home, "worktrees")

    {:ok, wt} =
      Worktrees.create(source, Ecto.UUID.generate(), "HEAD",
        private_git: true,
        worktrees_dir: worktrees_dir
      )

    %{
      home: home,
      source: source,
      worktree: wt.path,
      worktrees_dir: worktrees_dir,
      secret: secret,
      token: token,
      listener: listener,
      outside: outside
    }
  end

  test "a gate cannot read the rest of the home directory but reads its worktree", ctx do
    {evidence, report} = probe!(ctx)

    assert report["read_inside"] == "inside"
    assert report["read_outside"] =~ "denied:"
    assert report["list_home"] =~ "denied:"
    refute evidence.output =~ ctx.secret
  end

  test "a gate writes only to its worktree and its own temporary directory", ctx do
    git_link = File.read!(Path.join(ctx.worktree, ".git"))
    {_evidence, report} = probe!(ctx)

    assert report["write_outside"] =~ "denied:"
    refute File.exists?(ctx.outside)
    assert report["git_link"] =~ "denied:"
    assert File.read!(Path.join(ctx.worktree, ".git")) == git_link
    assert report["write_worktree"] == "written"
    assert File.read!(Path.join(ctx.worktree, "scratch/ok.txt")) == "probe"
    assert report["write_tmp"] == "written"
  end

  # Base: every gate left its temporary directory behind (880 had piled up).
  test "a gate's temporary directory is removed once the gate has finished", ctx do
    {_evidence, report} = probe!(ctx)

    assert Path.basename(report["tmpdir"]) =~ ~r/\Ashoestring-gate-/
    refute File.exists?(report["tmpdir"])
  end

  test "a gate cannot connect anywhere, even to a localhost listener", ctx do
    {_evidence, report} = probe!(ctx)

    assert report["connect"] =~ "denied:"
    assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 200)
  end

  test "a gate sees an explicit environment, not the service's", ctx do
    {evidence, report} = probe!(ctx)

    assert report["token"] == nil
    refute evidence.output =~ ctx.token
    assert report["path"] == true
    assert report["home_is_tmp"] == true
  end

  test "evidence records the sandbox profile identity", ctx do
    {evidence, _report} = probe!(ctx)

    assert evidence.sandbox =~ ~r/\Amacos_seatbelt:v1:sha256:[0-9a-f]{64}\z/
  end

  test "without a sandbox mechanism the gate is unavailable and never runs", ctx do
    missing = Path.join(ctx.home, "no-sandbox-exec")

    assert {:error, {:gate_unavailable, %{reason: :no_sandbox_mechanism}}} =
             gate(ctx, "test_probe.py", sandbox_exec: missing)

    refute File.exists?(Path.join(ctx.worktree, "scratch"))
  end

  test "outside a registered private run worktree the gate is unavailable and never runs", ctx do
    assert {:error, {:gate_unavailable, %{reason: :not_a_private_run_worktree}}} =
             gate(%{ctx | worktree: ctx.source}, "test_probe.py")

    refute File.exists?(Path.join(ctx.source, "scratch"))
  end

  test "an executable installed under the home directory is unavailable, not failed", ctx do
    # `mix`, because the process-group launcher itself needs the real python3.
    bin = Path.join(ctx.home, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "mix"), "#!/bin/sh\nexit 99\n")
    File.chmod!(Path.join(bin, "mix"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    assert {:error, {:gate_unavailable, %{reason: :toolchain_under_home}}} =
             PlanGateRunner.run(
               %{"gate" => "mix_format_check"},
               context(),
               worktree_path: ctx.worktree,
               worktrees_dir: ctx.worktrees_dir,
               gate_sandbox: [home: ctx.home]
             )
  end

  test "timeout still kills the wrapped gate's whole process group", ctx do
    assert {:error, {:gate_timeout, %{timeout_ms: 3_000}}} =
             gate(ctx, "test_hang.py", [], timeout_ms: 3_000)

    [pgid, pid] =
      ctx.worktree |> Path.join("scratch/hang.pgid") |> File.read!() |> String.split()

    # The wrapper exec's in place, so the gate is still the group leader.
    assert pgid == pid
    # SIGKILL has been delivered; ps can still report an unreaped orphan zombie.
    {output, _} = System.cmd("ps", ["-axo", "pgid=,stat="], stderr_to_stdout: true)

    states =
      for line <- String.split(output, "\n", trim: true),
          [group, state] <- [String.split(line)],
          group == pgid,
          do: state

    assert Enum.all?(states, &String.starts_with?(&1, "Z"))
  end

  test "oversized output still fails the wrapped gate", ctx do
    assert {:error, {:gate_output_oversized, %{bytes: bytes}}} = gate(ctx, "test_flood.py")
    assert bytes > 65_536
  end

  defp probe!(ctx) do
    assert {:ok, evidence} = gate(ctx, "test_probe.py")
    assert evidence.exit_status == 0, evidence.output
    [_, json] = Regex.run(~r/^PROBE (.*)$/m, evidence.output)
    {evidence, Jason.decode!(json)}
  end

  defp gate(ctx, file, sandbox \\ [], opts \\ []) do
    PlanGateRunner.run(
      %{"gate" => "python_unittest", "test_paths" => ["test/#{file}"]},
      context(),
      Keyword.merge(
        [
          worktree_path: ctx.worktree,
          worktrees_dir: ctx.worktrees_dir,
          timeout_ms: 15_000,
          gate_sandbox: Keyword.put(sandbox, :home, ctx.home)
        ],
        opts
      )
    )
  end

  defp context do
    %{
      goal_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      plan_task_id: "probe",
      revision_number: 1,
      plan_digest: String.duplicate("a", 64),
      attempt: 1
    }
  end

  defp git!(repository, args) do
    assert {:ok, result} = GateProcess.run(["git" | args], repository, 15_000, 65_536)
    assert result.exit_status == 0, result.output
    result.output
  end
end
