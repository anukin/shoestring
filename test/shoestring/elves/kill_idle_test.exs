defmodule Shoestring.Elves.KillIdleTest do
  @moduledoc """
  Locks `ElvesHelpers.kill_idle/1`, the crash simulation the Elf restart
  tests use (CI 36063516494: ElfTest:998 lost the sandbox owner).

  A process holding a sandbox connection is killed. With a bare
  `Process.exit(pid, :kill)` (the pre-fix test code) the kill lands inside
  the transaction, the shared owner's proxy shuts down, and the final query
  here raises `DBConnection.OwnershipError`. `kill_idle/1` waits for the
  callback to finish, so the test keeps its connection.
  """

  use Shoestring.DataCase, async: false

  alias Shoestring.Test.ElvesHelpers

  test "the kill never lands while the process holds a sandbox connection" do
    test_pid = self()
    {:ok, holder} = Agent.start(fn -> nil end)
    ref = Process.monitor(holder)

    Agent.cast(holder, fn state ->
      Repo.transaction(fn ->
        Repo.query!("SELECT 1")
        send(test_pid, :holding_connection)

        receive do
          :release -> :ok
        end
      end)

      state
    end)

    assert_receive :holding_connection, 5_000

    killer = Task.async(fn -> ElvesHelpers.kill_idle(holder) end)

    # Release the transaction only once the kill has either happened or is
    # parked behind the running callback as a suspend request.
    assert {:ok, _} =
             ElvesHelpers.wait_until(fn ->
               case Process.info(holder, :messages) do
                 nil -> :dead
                 {:messages, messages} -> Enum.any?(messages, &match?({:system, _, _}, &1))
               end
             end)

    send(holder, :release)
    assert Task.await(killer, 35_000) == true
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 5_000

    assert %{rows: [[1]]} = Repo.query!("SELECT 1")
  end
end
