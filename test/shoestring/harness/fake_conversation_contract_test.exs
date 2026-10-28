defmodule Shoestring.Harness.FakeConversationContractTest do
  use ExUnit.Case, async: true

  use Shoestring.Harness.ConversationContractSuite,
    module: Shoestring.Harness.Fake.Conversation

  def open(spec, _context),
    do: Shoestring.Harness.Fake.Conversation.start_link(spec, refuse_model: "not-a-model")
end
