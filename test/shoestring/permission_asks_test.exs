defmodule Shoestring.PermissionAsksTest do
  @moduledoc """
  A Codex worker asking the person for more (iteration 16 permissions): its
  approval request becomes an ask, only a person's decision answers it, and
  nothing answers it on a timer. A scripted transport stands in for Codex;
  local git only, no provider CLI.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.CodexAppServer.Session
  alias Shoestring.Harness.RunRequest
  alias Shoestring.PermissionAsks
  alias Shoestring.PermissionAsks.Ask
  alias Shoestring.Worktrees

  setup do
    source = Path.join(System.tmp_dir!(), "shoestring-asks-#{Ecto.UUID.generate()}")
    File.mkdir_p!(source)
    git!(source, ["init", "-q", "-b", "main"])
    File.write!(Path.join(source, "a.txt"), "a\n")
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=T",
      "-c",
      "user.email=t@x",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-qm",
      "b"
    ])

    on_exit(fn -> File.rm_rf!(source) end)
    {:ok, wt} = Worktrees.create(source, Ecto.UUID.generate(), "HEAD", private_git: true)
    %{wt: wt, goal_id: Ecto.UUID.generate()}
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp session!(ctx, permissions) do
    transport =
      start_supervised!(
        {FakeTransport,
         auto_respond: %{
           "initialize" => %{"result" => %{}},
           "thread/start" => %{"result" => %{"thread" => %{"id" => "thread-1"}}},
           "turn/start" => %{"result" => %{"turn" => %{"id" => "turn-1"}}}
         }},
        id: make_ref()
      )

    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: ctx.goal_id,
        task_id: Ecto.UUID.generate(),
        dispatch_id: Ecto.UUID.generate(),
        workspace_ref: ctx.wt.workspace_ref,
        prompt: "Implement",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: []
      })

    session =
      start_supervised!(
        {Session,
         run_request: request,
         workdir: ctx.wt.path,
         transport: FakeTransport,
         transport_pid: transport,
         auto_handshake: false,
         model: "fixture-model",
         permissions: permissions},
        id: make_ref()
      )

    :ok = FakeTransport.set_owner(transport, session)
    assert {:ok, _} = Session.await_run_identity(session, 5_000)
    {session, transport}
  end

  @approval %{
    "jsonrpc" => "2.0",
    "id" => 77,
    "method" => "item/commandExecution/requestApproval",
    "params" => %{
      "threadId" => "thread-1",
      "turnId" => "turn-1",
      "itemId" => "call_0",
      "reason" => "Fetch the release notes",
      "command" => "/bin/zsh -lc 'curl -sS https://example.invalid/notes'",
      "cwd" => "/work",
      "availableDecisions" => ["accept", "cancel"]
    }
  }

  defp push(session, transport, frame) do
    send(session, {:codex_transport_frame, transport, Jason.encode!(frame)})
    _ = :sys.get_state(session)
  end

  defp answer(transport, id),
    do:
      Enum.find(
        FakeTransport.get_sent_frames(transport),
        &(&1["id"] == id and Map.has_key?(&1, "result"))
      )

  defp sent(transport, method),
    do: Enum.filter(FakeTransport.get_sent_frames(transport), &(&1["method"] == method))

  test "an agent that may ask works on-request; its request waits for the person's denial and reason",
       ctx do
    {session, transport} = session!(ctx, %{"may_ask" => true})

    assert [%{"params" => %{"approvalPolicy" => "on-request"}}] = sent(transport, "thread/start")
    assert [%{"params" => %{"approvalPolicy" => "on-request"}}] = sent(transport, "turn/start")

    push(session, transport, @approval)
    assert [%Ask{state: "pending"} = ask] = PermissionAsks.for_goal(ctx.goal_id)
    assert ask.command =~ "curl -sS https://example.invalid/notes"
    assert ask.reason == "Fetch the release notes"
    assert PermissionAsks.waiting?(ask)
    # Nothing answers it by itself.
    _ = :sys.get_state(session)
    assert answer(transport, 77) == nil

    assert {:error, :non_human_identity} = PermissionAsks.decide(ask.id, "deny", "grant:x")
    assert {:error, :invalid_decision} = PermissionAsks.decide(ask.id, "maybe", "human:p")

    assert {:ok, %Ask{state: "denied", note: "Use the cached copy."}} =
             PermissionAsks.decide(ask.id, "deny", "human:p", "Use the cached copy.")

    _ = :sys.get_state(session)
    assert answer(transport, 77)["result"] == %{"decision" => "decline"}

    assert [%{"params" => %{"expectedTurnId" => "turn-1", "input" => [%{"text" => text}]}}] =
             sent(transport, "turn/steer")

    assert text =~ "Use the cached copy."
    # Decided once.
    assert {:error, :not_pending} = PermissionAsks.decide(ask.id, "allow", "human:p")
    refute PermissionAsks.waiting?(PermissionAsks.for_goal(ctx.goal_id) |> hd())
  end

  test "an allowed request is accepted, with no steer and no persistent rule", ctx do
    {session, transport} = session!(ctx, %{"may_ask" => true})
    push(session, transport, @approval)
    [ask] = PermissionAsks.for_goal(ctx.goal_id)

    assert {:ok, %Ask{state: "allowed", decided_by: "human:p"}} =
             PermissionAsks.decide(ask.id, "allow", "human:p", "ignored for an allow")

    _ = :sys.get_state(session)
    # Never acceptWithExecpolicyAmendment: that writes the person's Codex rules.
    assert answer(transport, 77)["result"] == %{"decision" => "accept"}
    assert sent(transport, "turn/steer") == []
    assert PermissionAsks.for_goal(ctx.goal_id) |> hd() |> Map.get(:note) == nil
  end

  test "an agent that may not ask keeps approval off; a request is refused at once", ctx do
    {session, transport} = session!(ctx, nil)
    assert [%{"params" => %{"approvalPolicy" => "never"}}] = sent(transport, "thread/start")
    push(session, transport, @approval)
    assert answer(transport, 77)["result"] == %{"decision" => "decline"}
    assert PermissionAsks.for_goal(ctx.goal_id) == []
  end

  test "an unsupported request is refused so the worker never waits on it", ctx do
    {session, transport} = session!(ctx, %{"may_ask" => true})

    push(session, transport, %{
      "id" => 9,
      "method" => "item/tool/requestUserInput",
      "params" => %{}
    })

    assert %{"error" => %{"code" => -32601}} =
             Enum.find(FakeTransport.get_sent_frames(transport), &(&1["id"] == 9))

    assert PermissionAsks.for_goal(ctx.goal_id) == []
  end

  test "an ask whose session stops can no longer be answered and is expired", ctx do
    {session, transport} = session!(ctx, %{"may_ask" => true})
    push(session, transport, @approval)
    [ask] = PermissionAsks.for_goal(ctx.goal_id)

    assert :ok = Session.shutdown(session)
    assert %Ask{state: "expired"} = Repo.get(Ask, ask.id)
    assert {:error, :not_pending} = PermissionAsks.decide(ask.id, "allow", "human:p")
  end
end
