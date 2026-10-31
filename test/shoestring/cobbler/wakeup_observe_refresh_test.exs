defmodule Shoestring.Cobbler.WakeupObserveRefreshTest do
  @moduledoc """
  A decision that reads a Codex observation which is missing, stale or
  close to going stale asks the Codex monitor for a fresh one, and still
  uses what it found. The monitor is disabled in tests, so this test takes
  its registered name and sees the request.
  """
  use Shoestring.DataCase, async: false
  import Shoestring.ConfigurationFixtures

  alias Shoestring.Cobbler.WakeupObserve
  alias Shoestring.Harness.Capacity.CodexMonitor

  @identity %{provider_id: "codex", scope: "synthetic-account"}

  setup do
    true = Process.register(self(), CodexMonitor)

    on_exit(fn ->
      if Process.whereis(CodexMonitor) == self(), do: Process.unregister(CodexMonitor)
    end)

    :ok
  end

  defp asked? do
    receive do
      {:"$gen_cast", :refresh} -> true
    after
      0 -> false
    end
  end

  test "a missing Codex reading asks for one" do
    assert {:error, _} = WakeupObserve.observe(@identity)
    assert asked?()
  end

  test "a fresh Codex reading is used as it is; one near or past its age asks for another" do
    now = DateTime.utc_now()
    capacity_fixture(%{observed_at: DateTime.add(now, -30)})
    assert {:ok, _} = WakeupObserve.observe(@identity)
    refute asked?()

    capacity_fixture(%{observed_at: DateTime.add(now, -250)})
    capacity_fixture(%{observed_at: DateTime.add(now, -250), scope: "other"})
    # The newest reading wins: still 30 s old.
    assert {:ok, snapshot} = WakeupObserve.observe(@identity)
    assert DateTime.diff(now, snapshot.observed_at) in 29..31
    refute asked?()

    assert {:ok, _} = WakeupObserve.observe(%{@identity | scope: "other"})
    assert asked?()

    capacity_fixture(%{observed_at: DateTime.add(now, -600), scope: "stale"})
    assert {:ok, stale} = WakeupObserve.observe(%{@identity | scope: "stale"})
    assert stale.observed_at == DateTime.add(now, -600) |> DateTime.truncate(:microsecond)
    assert asked?()
  end

  test "other providers never ask the Codex monitor" do
    assert {:error, _} = WakeupObserve.observe(%{provider_id: "claude", scope: "subscription"})
    refute asked?()
  end
end
