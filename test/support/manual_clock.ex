defmodule Shoestring.Test.ManualClock do
  @moduledoc """
  A controllable clock for deterministic time-sensitive tests.

  Reads the current time from the calling process's dictionary so that
  concurrent tests can have independent clocks without affecting each other.
  The default is the same epoch used by FixedClock.

  Usage:

      ManualClock.set(~U[2026-09-01 11:00:00.000000Z])
      assert ManualClock.now() == ~U[2026-09-01 11:00:00.000000Z]
      ManualClock.advance(60, :second)
      assert ManualClock.now() == ~U[2026-09-01 11:01:00.000000Z]

  """

  @behaviour Shoestring.Harness.Clock

  @epoch ~U[2026-08-30 12:00:00.000000Z]

  @impl true
  def now do
    base = Process.get(:manual_clock_base, @epoch)
    offset_us = Process.get(:manual_clock_offset_us, 0)
    DateTime.add(base, offset_us, :microsecond) |> DateTime.truncate(:microsecond)
  end

  @spec set(DateTime.t()) :: :ok
  def set(%DateTime{} = datetime) do
    Process.put(:manual_clock_base, datetime |> DateTime.truncate(:microsecond))
    Process.put(:manual_clock_offset_us, 0)
    :ok
  end

  @spec advance(non_neg_integer(), :second | :millisecond | :microsecond) :: :ok
  def advance(amount, unit \\ :second) do
    us =
      case unit do
        :second -> amount * 1_000_000
        :millisecond -> amount * 1_000
        :microsecond -> amount
      end

    current = Process.get(:manual_clock_offset_us, 0)
    Process.put(:manual_clock_offset_us, current + us)
    :ok
  end

  @spec reset() :: :ok
  def reset do
    Process.put(:manual_clock_base, @epoch)
    Process.put(:manual_clock_offset_us, 0)
    :ok
  end
end
