defmodule Shoestring.Harness.ClaudeHeadless.ConversationContractTest do
  use ExUnit.Case, async: true

  use Shoestring.Harness.ConversationContractSuite,
    module: Shoestring.Harness.ClaudeHeadless.Conversation

  use Shoestring.Harness.ConversationMemorySuite

  @cli Path.expand("../../../support/fake_claude_converse.py", __DIR__)

  def open(spec, context),
    do:
      Shoestring.Harness.ClaudeHeadless.Conversation.start_link(spec,
        executable: @cli,
        env: Shoestring.Harness.ConversationMemorySuite.env(context)
      )
end
