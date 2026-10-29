defmodule Shoestring.Harness.OpencodeAcp.ConversationContractTest do
  use ExUnit.Case, async: true

  use Shoestring.Harness.ConversationContractSuite,
    module: Shoestring.Harness.OpencodeAcp.Conversation

  alias Shoestring.Harness.OpencodeAcp.Conversation
  @cli Path.expand("../../../support/fake_opencode_converse.py", __DIR__)
  def open(spec, _context), do: open_with(spec, [])

  defp open_with(spec, opts) do
    opts = Keyword.put(opts, :executable, @cli)

    case start_supervised(%{id: make_ref(), start: {Conversation, :start_link, [spec, opts]}}) do
      {:error, {error, _}} -> {:error, error}
      result -> result
    end
  end

  @tag :tmp_dir
  test "direct MCP is offered while Code Mode, writes, permission grants and reasoning are refused",
       ctx do
    file = Path.join(ctx.tmp_dir, "keep.txt")
    File.write!(file, "readable original")

    spec = %{
      owner: self(),
      workdir: ctx.tmp_dir,
      model: "opus",
      tools: %{url: "http://127.0.0.1:4000/mcp", token: "synthetic-private-token"}
    }

    config = Conversation.config(spec)
    refute Jason.encode!(config) =~ spec.tools.token
    assert config.mcp.servers.shoestring.codemode == false
    {:ok, pid} = open(spec, ctx)
    assert %{type: :session} = next_event(pid)
    :ok = Conversation.send_turn(pid, "write", "WRITE")
    events = events_until(pid, :turn_completed)

    assert Enum.map(Enum.filter(events, &(&1.type == :text)), & &1.text) == [
             "Write refused; readable original retained"
           ]

    assert File.read!(file) == "readable original"
    :ok = Conversation.send_turn(pid, "permission", "PERMISSION")
    assert List.last(events_until(pid, :turn_completed)).status == :failed
  end

  @tag :tmp_dir
  test "older agents refuse before any prompt; unsupported effort refuses", ctx do
    spec = %{owner: self(), workdir: ctx.tmp_dir, model: "opus"}

    assert {:error, %{code: "direct_tools_not_supported"}} =
             open_with(spec, env: [{"FAKE_OPENCODE_VERSION", "2.0.30"}])

    assert {:error, %{code: "effort_not_offered"}} = open(Map.put(spec, :effort, "wrong"), ctx)
  end

  @tag :tmp_dir
  test "missing read-only agent and silent model fallback refuse before a turn", ctx do
    spec = %{owner: self(), workdir: ctx.tmp_dir, model: "opus"}

    assert {:error, %{code: "readonly_agent_not_offered"}} =
             open_with(spec, env: [{"FAKE_OPENCODE_NO_AGENT", "1"}])

    assert {:error, %{code: "model_not_offered"}} =
             open_with(spec, env: [{"FAKE_OPENCODE_FALLBACK", "1"}])

    refute_received {:conversation_event, _, _}
  end
end
