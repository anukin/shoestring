defmodule Shoestring.Harness.CodexAppServer.ConversationContractTest do
  use ExUnit.Case, async: true

  use Shoestring.Harness.ConversationContractSuite,
    module: Shoestring.Harness.CodexAppServer.Conversation

  use Shoestring.Harness.ConversationMemorySuite

  alias Shoestring.Harness.CodexAppServer.Conversation
  @cli Path.expand("../../../support/fake_codex_converse.py", __DIR__)

  def open(spec, context) do
    case start_supervised(%{
           id: make_ref(),
           start:
             {Conversation, :start_link,
              [
                spec,
                [executable: @cli, env: Shoestring.Harness.ConversationMemorySuite.env(context)]
              ]}
         }) do
      {:error, {error, _child}} -> {:error, error}
      result -> result
    end
  end

  @tag :tmp_dir
  test "approval requests are refused and reasoning never leaves the adapter", ctx do
    {:ok, pid} = open(%{owner: self(), model: "opus", workdir: ctx.tmp_dir}, ctx)
    assert %{type: :session} = next_event(pid)
    :ok = Conversation.send_turn(pid, "one", "APPROVAL")
    events = events_until(pid, :turn_completed)
    assert List.last(events).status == :failed
    refute Enum.any?(events, &(&1.type == :text))
    :ok = Conversation.send_turn(pid, "two", "SAY readable")
    events = events_until(pid, :turn_completed)
    text = Enum.filter(events, &(&1.type == :text))
    assert Enum.map_join(text, & &1.text) == "readable"
    assert List.last(text).text_complete
  end

  @tag :tmp_dir
  test "MCP token stays out of argv and model effort is checked", ctx do
    spec = %{
      owner: self(),
      model: "opus",
      effort: "wrong",
      workdir: ctx.tmp_dir,
      tools: %{url: "http://127.0.0.1:4000/mcp", token: "synthetic-private-token"}
    }

    argv = Conversation.argv(spec)
    refute Enum.any?(argv, &String.contains?(&1, spec.tools.token))
    assert Enum.any?(argv, &String.contains?(&1, "bearer_token_env_var"))
    assert {:error, %{code: "effort_not_offered"}} = open(spec, ctx)
  end

  test "the code-mode host stays enabled: codex-cli 0.166.0 offers tools only through exec" do
    argv = Conversation.argv(%{tools: %{url: "http://127.0.0.1:4000/mcp"}})

    assert "features.code_mode=false" in argv
    assert "features.apps=false" in argv
    refute "features.code_mode_host=false" in argv
  end
end
