defmodule Shoestring.Elves.PortRunnerHandshakeTest do
  @moduledoc """
  The launch wrapper's leadership handshake (`PortRunner` moduledoc,
  "Leadership handshake"), for both launchers that use it: `PortRunner` and
  `Shoestring.Harness.ClaudeHeadless.Transport`.

  Why it exists: in OTP 28 `erl_child_setup` reports a forked child's pid to
  the BEAM before the child calls `setsid()`, so a leadership check run as
  soon as the pid is known can see the parent's pgid and fail a good launch
  closed (`not_group_leader`). The handshake makes the check wait until the
  child verifiably leads its group.

  Honest scope: these tests pin the handshake's contract — nothing of it
  leaks into the target's output, the target still leads its group with
  stdin at `/dev/null`, and a launch whose handshake does not complete never
  runs the target. They are DOCUMENTATION of the new behaviour, not a
  regression lock for the race itself: the race depends on the OS scheduler
  and was not reproduced on this host (0 of 1400 stressed spawns), so no
  test here fails on base because of it. The last test's "handshake did not
  complete" branch has no base counterpart at all.

  Hermetic: `sh`, `ps`, `touch` and `python3` only.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Elves.PortRunner
  alias Shoestring.Harness.ClaudeHeadless.Transport
  alias Shoestring.Test.ElvesHelpers

  describe "PortRunner" do
    test "the handshake line never reaches the owner; the target's output is intact" do
      assert {:ok, runner} = PortRunner.spawn(["sh", "-c", "printf 'first\\nsecond\\n'"])
      on_exit(fn -> ElvesHelpers.cleanup_group(runner.pgid) end)

      {output, status} = collect(runner.port, "")

      assert status == 0
      # Present: exactly what the target wrote, nothing before it.
      assert output == "first\nsecond\n"
      # Absent: the wrapper's handshake line.
      refute output =~ PortRunner.handshake_prefix()
    end

    test "the executed target leads its own process group, by its own report" do
      # `sh` is exec'd in place of the wrapper, so `$$` is the spawned pid.
      assert {:ok, runner} = PortRunner.spawn(["sh", "-c", "ps -o pgid= -p $$"])
      on_exit(fn -> ElvesHelpers.cleanup_group(runner.pgid) end)

      {output, 0} = collect(runner.port, "")

      assert {pgid, _rest} = Integer.parse(String.trim(output))
      assert pgid == runner.os_pid
      assert runner.pgid == runner.os_pid
    end

    test "a handshake that does not complete fails closed and never runs the target" do
      marker =
        Path.join(System.tmp_dir!(), "handshake-marker-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(marker) end)

      # A zero wait gives up before the interpreter can have announced
      # itself; the wrapper is then killed while still blocked.
      assert {:error, :setsid_handshake_timeout} =
               PortRunner.spawn(["touch", marker], handshake_timeout_ms: 0)

      # The target runs only after the go byte, which was never sent, and a
      # SIGKILLed wrapper cannot exec. So nothing was created.
      refute File.exists?(marker)

      # And the failed spawn left nothing in the caller's mailbox: the killed
      # wrapper's port may close itself first, and its exit status must not
      # leak to (or crash) the caller. Gate run G1 at 0cf9e2e hit exactly
      # that race: `spawn/2` raised `ArgumentError` from `port_close/1`.
      leftover =
        receive do
          {port, message} when is_port(port) -> {port, message}
        after
          0 -> nil
        end

      assert leftover == nil
    end
  end

  describe "ClaudeHeadless.Transport" do
    test "the handshake line is never delivered as a frame; target lines are intact" do
      sh = System.find_executable("sh")

      assert {:ok, transport} =
               Transport.start_link(
                 owner: self(),
                 command: sh,
                 executable: sh,
                 args: ["-c", ~s(printf '{"a":1}\\n{"b":2}\\n')]
               )

      assert_receive {:claude_transport_connected, ^transport}, 5_000
      assert_receive {:claude_transport_frame, ^transport, first}, 5_000
      assert_receive {:claude_transport_frame, ^transport, second}, 5_000
      assert_receive {:claude_transport_closed, ^transport, {:exit_status, 0}}, 5_000

      # Present: exactly the target's two JSONL lines, in order.
      assert [first, second] == [~s({"a":1}), ~s({"b":2})]
      # Absent: any frame carrying the handshake line.
      refute_received {:claude_transport_frame, ^transport, _any}
      refute first =~ PortRunner.handshake_prefix()
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, bytes}} -> collect(port, acc <> bytes)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      5_000 -> flunk("no exit status from #{inspect(port)}; output so far: #{inspect(acc)}")
    end
  end
end
