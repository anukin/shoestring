defmodule Shoestring.Harness.ClaudeHeadlessContractTest do
  @moduledoc """
  Verifies that Shoestring.Harness.ClaudeHeadless satisfies the shared
  Shoestring.Harness.ContractSuite.

  Capability record: the adapter declares `[:cancel]` only. `:resume` is
  deliberately withheld — resume mechanics are VERIFIED but resumed-turn
  completion is UNVERIFIED (see `ClaudeHeadless` moduledoc and
  `plans/evidence/04-single-elf/claude-exec-events.md`) — so the
  capability-appropriate resume test is legitimately skipped by the suite,
  not bypassed.
  """
  use Shoestring.Harness.ContractSuite,
    adapter: Shoestring.Harness.ClaudeHeadless,
    config: %{}
end
