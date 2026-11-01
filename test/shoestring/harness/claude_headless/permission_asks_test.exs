defmodule Shoestring.Harness.ClaudeHeadless.PermissionAsksTest do
  @moduledoc """
  A Claude worker asking the person for more (iteration 16 permissions): a
  `can_use_tool` control request becomes an ask, only a person's decision
  answers it, nothing answers it on a timer, and stdin closes after the
  result. A scripted transport stands in for Claude; the frame shapes are
  the ones Claude Code 2.1.316 sent and accepted offline
  (`plans/evidence/16-long-work/permissions-probe.md`).
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.ClaudeHeadless.Session
  alias Shoestring.Harness.ClaudeScriptedTransport, as: Transport
  alias Shoestring.Harness.RunRequest
  alias Shoestring.PermissionAsks
  alias Shoestring.PermissionAsks.Ask

  @input %{
    "command" => "curl -sS https://example.invalid/notes",
    "description" => "Fetch the release notes",
    "dangerouslyDisableSandbox" => true
  }

  setup do
    %{goal_id: Ecto.UUID.generate()}
  end

  defp session!(ctx, opts) do
    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: ctx.goal_id,
        task_id: Ecto.UUID.generate(),
        dispatch_id: Ecto.UUID.generate(),
        workspace_ref: "workspace/asks",
        prompt: "Implement the task",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: []
      })

    transport = start_supervised!({Transport, owner: nil, lines: []}, id: make_ref())

    session =
      start_supervised!(
        {Session,
         [run_request: request, transport: Transport, transport_pid: transport, owner: self()] ++
           opts},
        id: make_ref()
      )

    :sys.replace_state(transport, &%{&1 | owner: session})
    {session, transport}
  end

  defp push(session, frame) do
    send(session, {:claude_transport_frame, self(), Jason.encode!(frame)})
    _ = :sys.get_state(session)
  end

  defp can_use_tool(id, input \\ @input),
    do: %{
      "type" => "control_request",
      "request_id" => id,
      "request" => %{
        "subtype" => "can_use_tool",
        "tool_name" => "Bash",
        "display_name" => "Bash",
        "input" => input,
        "description" => "Fetch the release notes",
        "decision_reason_type" => "sandboxOverride",
        "tool_use_id" => "toolu_01" <> id
      }
    }

  defp responses(transport),
    do: for(%{"type" => "control_response", "response" => r} <- Transport.sent(transport), do: r)

  @result %{
    "type" => "result",
    "subtype" => "success",
    "is_error" => false,
    "result" => "done",
    "session_id" => "11111111-0000-4000-a000-000000000001"
  }

  test "the prompt is the first stdin line; a request waits for the person's denial and reason",
       ctx do
    {session, transport} = session!(ctx, asks: true)

    assert [
             %{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "Implement the task"}]
               }
             }
           ] = Transport.sent(transport)

    push(session, can_use_tool("req-1"))

    assert [%Ask{state: "pending", provider: "claude"} = ask] =
             PermissionAsks.for_goal(ctx.goal_id)

    assert ask.command == "curl -sS https://example.invalid/notes"
    assert ask.rule_key == "curl -sS https://example.invalid/notes"
    assert ask.reason == "Fetch the release notes"
    assert PermissionAsks.waiting?(ask)
    # Nothing answers it by itself.
    _ = :sys.get_state(session)
    assert responses(transport) == []

    assert {:ok, %Ask{state: "denied"}} =
             PermissionAsks.decide(ask.id, "deny", "human:p", "Use the cached copy.")

    _ = :sys.get_state(session)

    assert [
             %{
               "subtype" => "success",
               "request_id" => "req-1",
               "response" => %{
                 "behavior" => "deny",
                 "message" => "The person denied that request: Use the cached copy."
               }
             }
           ] = responses(transport)

    assert {:error, :not_pending} = PermissionAsks.decide(ask.id, "allow", "human:p")
  end

  test "an allowed request runs as asked; the result closes stdin", ctx do
    {session, transport} = session!(ctx, asks: true)
    push(session, can_use_tool("req-2"))
    [ask] = PermissionAsks.for_goal(ctx.goal_id)

    assert {:ok, %Ask{state: "allowed"}} = PermissionAsks.decide(ask.id, "allow", "human:p", "x")
    _ = :sys.get_state(session)

    assert [%{"request_id" => "req-2", "response" => response}] = responses(transport)
    assert response == %{"behavior" => "allow", "updatedInput" => @input}

    refute Transport.input_closed?(transport)
    push(session, @result)
    assert {:ok, %{status: :completed}} = Session.await_terminal(session, 1_000)
    assert Transport.input_closed?(transport)
  end

  test "a worker that may not ask is refused at once, with nothing recorded", ctx do
    {session, transport} = session!(ctx, [])
    # Its prompt is in its argv, not on stdin.
    assert Transport.sent(transport) == []
    push(session, can_use_tool("req-3"))

    assert [%{"request_id" => "req-3", "response" => %{"behavior" => "deny"}}] =
             responses(transport)

    assert PermissionAsks.for_goal(ctx.goal_id) == []
    push(session, @result)
    refute Transport.input_closed?(transport)
  end

  # Shape sent by Claude Code 2.1.316 offline (2026-11-01) for a sandboxed
  # curl to a host not in allowedDomains.
  test "a host not on the list is asked as a network ask, never offered a rule", ctx do
    {session, transport} = session!(ctx, asks: true)

    push(session, %{
      "type" => "control_request",
      "request_id" => "req-net",
      "request" => %{
        "subtype" => "can_use_tool",
        "tool_name" => "SandboxNetworkAccess",
        "display_name" => "SandboxNetworkAccess",
        "input" => %{"host" => "example.org"},
        "description" => "Allow network connection to example.org?",
        "tool_use_id" => "b4023816-998d-4080-9471-96bc9ecb8bac"
      }
    })

    assert [%Ask{kind: "network", rule_key: nil} = ask] = PermissionAsks.for_goal(ctx.goal_id)
    assert ask.command == "Reach example.org from its commands"
    assert ask.reason == "Allow network connection to example.org?"
    assert {:error, :not_ruleable} = PermissionAsks.decide(ask.id, "allow_agent", "human:p")

    {:ok, _} = PermissionAsks.decide(ask.id, "allow", "human:p")
    _ = :sys.get_state(session)

    assert [
             %{
               "request_id" => "req-net",
               "response" => %{
                 "behavior" => "allow",
                 "updatedInput" => %{"host" => "example.org"}
               }
             }
           ] =
             responses(transport)
  end

  test "any other control request is refused so the worker never waits on it", ctx do
    {session, transport} = session!(ctx, asks: true)

    push(session, %{
      "type" => "control_request",
      "request_id" => "req-4",
      "request" => %{"subtype" => "hook_callback", "callback_id" => "x"}
    })

    assert [%{"subtype" => "error", "request_id" => "req-4"}] = responses(transport)
    assert PermissionAsks.for_goal(ctx.goal_id) == []
  end

  test "an ask still open when the run is cancelled or shut down is expired", ctx do
    {session, transport} = session!(ctx, asks: true)
    push(session, can_use_tool("req-5"))
    [ask] = PermissionAsks.for_goal(ctx.goal_id)

    assert {:ok, :cancelled} = Session.cancel(session)
    assert %Ask{state: "expired"} = Repo.get(Ask, ask.id)
    assert {:error, :not_pending} = PermissionAsks.decide(ask.id, "allow", "human:p")
    assert responses(transport) == []

    {session, _transport} = session!(ctx, asks: true)
    push(session, can_use_tool("req-6"))

    [%Ask{state: "pending"} = open] =
      Enum.filter(PermissionAsks.for_goal(ctx.goal_id), &(&1.state == "pending"))

    assert :ok = Session.shutdown(session)
    assert %Ask{state: "expired"} = Repo.get(Ask, open.id)
  end
end
