defmodule Shoestring.Test.PlanHandoffClock do
  @behaviour Shoestring.Harness.Clock
  def now, do: Shoestring.Test.PlanExecutorHelpers.now()
end
