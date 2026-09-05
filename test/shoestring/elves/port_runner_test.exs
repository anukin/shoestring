defmodule Shoestring.Elves.PortRunnerTest do
  use ExUnit.Case, async: false

  alias Shoestring.Elves.PortRunner
  alias Shoestring.Test.ElvesHelpers

  test "spawned child owns its process group (pgid == os pid)" do
    assert {:ok, runner} = PortRunner.spawn(["sleep", "30"])
    on_exit(fn -> ElvesHelpers.cleanup_group(runner.pgid) end)

    assert runner.os_pid > 1
    assert runner.pgid == runner.os_pid
    assert runner.setsid
    assert PortRunner.alive?(runner)

    assert {:ok, result} = PortRunner.terminate(runner)
    assert result in [:exited, :killed]
    refute PortRunner.alive?(runner)
  end

  test "stdin is /dev/null: cat exits immediately instead of hanging on a pipe" do
    # Wave-0 finding: a harness that blocks on an open stdin pipe hangs
    # forever with zero output. With stdin deliberately redirected, `cat`
    # sees EOF at once and exits zero.
    assert {:ok, runner} = PortRunner.spawn(["cat"])
    on_exit(fn -> ElvesHelpers.cleanup_group(runner.pgid) end)

    assert {:ok, status} =
             (fn ->
                receive do
                  {port, {:exit_status, code}} when port == runner.port -> {:ok, code}
                after
                  5_000 -> {:error, :no_exit}
                end
              end).()

    assert status == 0
    _ = PortRunner.close(runner)
  end

  test "killpg terminates the whole group including a real descendant" do
    spawner =
      ~s|import subprocess,time; subprocess.Popen(["sleep","30"]); time.sleep(30)|

    assert {:ok, runner} = PortRunner.spawn(["python3", "-c", spawner])
    on_exit(fn -> ElvesHelpers.cleanup_group(runner.pgid) end)

    assert {:ok, members} =
             ElvesHelpers.wait_until(fn ->
               members = ElvesHelpers.group_members(runner.pgid)
               if length(members) >= 2, do: members
             end)

    assert length(members) >= 2

    assert :ok = PortRunner.killpg(runner, "KILL")

    assert {:ok, []} =
             ElvesHelpers.wait_until(fn ->
               if ElvesHelpers.group_members(runner.pgid) == [], do: []
             end)

    _ = PortRunner.close(runner)
  end

  test "terminate escalates TERM then KILL and reaps" do
    assert {:ok, runner} = PortRunner.spawn(["sleep", "30"])
    on_exit(fn -> ElvesHelpers.cleanup_group(runner.pgid) end)

    assert {:ok, result} =
             PortRunner.terminate(runner, kill_grace_ms: 200, reap_timeout_ms: 2_000)

    assert result in [:exited, :killed]
    refute PortRunner.alive?(runner)
  end

  test "argv arrays only: rejects shell strings, NUL bytes, and missing executables" do
    assert {:error, :invalid_argv} = PortRunner.spawn([])
    assert {:error, :invalid_argv} = PortRunner.spawn(["sleep", "30\0"])

    assert {:error, {:executable_not_found, _}} =
             PortRunner.spawn(["definitely-not-a-real-binary-xyz"])
  end

  test "killpg refuses the BEAM's own process group and invalid pgids" do
    assert {:error, :invalid_pgid} = PortRunner.killpg_id(0, "TERM")
    assert {:error, :invalid_pgid} = PortRunner.killpg_id(-5, "TERM")
    refute PortRunner.alive_id?(0)
  end

  defp collect_until_exit(port, acc) do
    receive do
      {^port, {:data, bytes}} -> collect_until_exit(port, acc <> bytes)
      {^port, {:exit_status, 0}} -> {:ok, acc}
      {^port, {:exit_status, status}} -> {:error, {:exit_status, status}}
    after
      5_000 -> {:error, :no_exit}
    end
  end

  test "cd runs the command inside the given directory" do
    dir = Path.join(System.tmp_dir!(), "elf-cd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "marker.txt"), "here-123")
    on_exit(fn -> File.rm_rf(dir) end)

    # A relative argv entry only resolves inside `dir`, proving the child cwd.
    cat = System.find_executable("cat")
    assert is_binary(cat)

    assert {:ok, runner} = PortRunner.spawn([cat, "marker.txt"], cd: dir)
    on_exit(fn -> ElvesHelpers.cleanup_group(runner.pgid) end)

    assert {:ok, "here-123"} = collect_until_exit(runner.port, "")
    _ = PortRunner.close(runner)

    assert {:error, {:invalid_workdir, _}} =
             PortRunner.spawn([cat, "marker.txt"], cd: "/nonexistent-wpb-workdir")
  end

  test "missing python3 fails closed with a diagnosable reason" do
    previous_path = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent-wpb-fixture")
      assert {:error, :setsid_unavailable} = PortRunner.spawn(["/bin/sleep", "30"])
    after
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
    end
  end
end
