defmodule Shoestring.Harness.ClaudeHeadless.TransportTest do
  @moduledoc """
  Hermetic tests for the production one-shot transport, using trivial
  local commands only (never a provider CLI, never the network).
  """

  use ExUnit.Case, async: true

  alias Shoestring.Harness.ClaudeHeadless.Transport

  @fixture_dir "plans/evidence/04-single-elf/fixtures/claude"

  defp collect_frames(pid, acc \\ []) do
    receive do
      {:claude_transport_frame, ^pid, line} -> collect_frames(pid, [line | acc])
      {:claude_transport_closed, ^pid, reason} -> {Enum.reverse(acc), reason}
    after
      10_000 -> flunk("timed out waiting for transport messages")
    end
  end

  test "spawns a process whose stdout lines arrive as frames, then exit status" do
    cat = System.find_executable("cat")
    assert is_binary(cat)

    fixture = Path.join(@fixture_dir, "stream-json-tool-exec.jsonl") |> Path.expand()

    # Directly linked: the transport stops normally when `cat` exits, and
    # a supervised restart would replay the stream into this mailbox.
    {:ok, pid} =
      Transport.start_link(owner: self(), command: cat, executable: cat, args: [fixture])

    assert_receive {:claude_transport_connected, ^pid}, 5_000

    {lines, reason} = collect_frames(pid)
    assert length(lines) == 8
    assert reason == {:exit_status, 0}

    assert {:ok, first} = Jason.decode(hd(lines))
    assert first["type"] == "system"
  end

  test "stdin is closed and the child leads its own process group" do
    sleep_bin = System.find_executable("sleep")
    assert is_binary(sleep_bin)

    {:ok, pid} =
      Transport.start_link(
        owner: self(),
        command: sleep_bin,
        executable: sleep_bin,
        args: ["30"]
      )

    assert_receive {:claude_transport_connected, ^pid}, 5_000

    os_pid = Transport.os_pid(pid)
    assert is_integer(os_pid) and os_pid > 1

    # pid == pgid (verified at spawn; re-check here against `ps`).
    {ps_out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", to_string(os_pid)])
    assert String.trim(ps_out) == to_string(os_pid)

    assert {:ok, status} = Transport.terminate_group(pid)
    assert status in [:exited, :killed, :already_exited]

    # The whole process group is gone.
    assert {_out, 1} = System.cmd("kill", ["-0", "-#{os_pid}"], stderr_to_stdout: true)
  end

  test "fast-exiting children never fail spawn (already-exited reconciliation)" do
    # Regression tripwire for the full-suite flake: `false` exits in ~1ms,
    # so under scheduling pressure the child is routinely dead before
    # Port.info runs. Every spawn must still start cleanly and report its
    # exit; each iteration is an independent sample of that window and any
    # failure is loud. Unlinked starts: an abnormal init-stop returns
    # {:error, _} instead of taking this process down.
    false_bin = System.find_executable("false")
    assert is_binary(false_bin)

    pids =
      for _ <- 1..25 do
        assert {:ok, pid} =
                 GenServer.start(Transport,
                   owner: self(),
                   command: false_bin,
                   executable: false_bin,
                   args: []
                 )

        assert_receive {:claude_transport_connected, ^pid}, 5_000
        pid
      end

    for pid <- pids do
      assert_receive {:claude_transport_closed, ^pid, {:exit_status, 1}}, 10_000
    end
  end

  # A worker that may ask is driven over stdin (`--input-format stream-json`).
  test "an open input carries lines to the child; closing it lets the child exit at EOF" do
    cat = System.find_executable("cat")

    {:ok, pid} = Transport.start_link(owner: self(), command: cat, executable: cat, input: :open)
    assert_receive {:claude_transport_connected, ^pid}, 5_000
    os_pid = Transport.os_pid(pid)

    assert :ok = Transport.send_frame(pid, %{"type" => "user", "n" => 1})
    assert_receive {:claude_transport_frame, ^pid, line}, 5_000
    assert Jason.decode!(line) == %{"type" => "user", "n" => 1}

    assert :ok = Transport.close_input(pid)
    assert {:error, :input_closed} = Transport.send_frame(pid, %{"n" => 2})
    # `cat` exits at its EOF; the transport still owns the group and never
    # reports the closed port as the run's end.
    assert {:ok, :already_exited} = Transport.terminate_group(pid, kill_grace_ms: 5_000)
    {_, status} = System.cmd("kill", ["-0", "-#{os_pid}"], stderr_to_stdout: true)
    assert status != 0
    refute_received {:claude_transport_closed, ^pid, _}
  end

  test "a child left running after its input closes is still reaped with its group" do
    sh = System.find_executable("sh")

    # Ignores its EOF: `sleep` holds the group open.
    {:ok, pid} =
      Transport.start_link(
        owner: self(),
        command: sh,
        executable: sh,
        args: ["-c", "sleep 30"],
        input: :open
      )

    assert_receive {:claude_transport_connected, ^pid}, 5_000
    os_pid = Transport.os_pid(pid)
    assert :ok = Transport.close_input(pid)
    assert {:ok, :exited} = Transport.terminate_group(pid, kill_grace_ms: 5_000)
    {_, status} = System.cmd("kill", ["-0", "-#{os_pid}"], stderr_to_stdout: true)
    assert status != 0
  end

  test "a closed input takes no frames" do
    sleep_bin = System.find_executable("sleep")

    {:ok, pid} =
      Transport.start_link(owner: self(), command: sleep_bin, executable: sleep_bin, args: ["30"])

    assert_receive {:claude_transport_connected, ^pid}, 5_000
    assert {:error, :input_not_open} = Transport.send_frame(pid, %{"n" => 1})
    assert {:ok, _} = Transport.terminate_group(pid)
  end

  test "missing executable fails closed" do
    # Unlinked start: a linked init-stop with an abnormal reason would
    # take the test process down with it.
    assert {:error, :executable_not_found} =
             GenServer.start(Transport,
               owner: self(),
               command: "definitely-not-a-real-binary-xyz"
             )
  end

  test "invalid workdir fails closed" do
    cat = System.find_executable("cat")
    assert is_binary(cat)

    assert {:error, {:invalid_workdir, "/no/such/dir/xyz"}} =
             GenServer.start(Transport,
               owner: self(),
               command: cat,
               executable: cat,
               args: [],
               cd: "/no/such/dir/xyz"
             )
  end
end
