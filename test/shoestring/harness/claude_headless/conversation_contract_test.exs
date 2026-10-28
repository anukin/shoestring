defmodule Shoestring.Harness.ClaudeHeadless.ConversationContractTest do
  use ExUnit.Case, async: true

  use Shoestring.Harness.ConversationContractSuite,
    module: Shoestring.Harness.ClaudeHeadless.Conversation

  @cli Path.expand("../../../support/fake_claude_converse.py", __DIR__)

  def open(spec, _context),
    do: Shoestring.Harness.ClaudeHeadless.Conversation.start_link(spec, executable: @cli)
end
