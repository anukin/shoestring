defmodule Shoestring.Test.RaisingRepo do
  @moduledoc """
  Hermetic test repo whose reads always raise.

  Used to drive fail-closed `rescue` paths (e.g.
  `Shoestring.Cobbler.Leases.consumed/2` must return `nil`, never raise or
  invent spend, when the trajectory log is unreadable). Never backed by a
  database; never touches the network.
  """

  def all(_query), do: raise("boom: repository state reconstruction failed")
end
