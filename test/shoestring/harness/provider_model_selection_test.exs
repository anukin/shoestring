defmodule Shoestring.Harness.ProviderModelSelectionTest do
  use ExUnit.Case, async: true
  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.CodexAppServer.Session
  alias Shoestring.Harness.RunRequest

  defp request do
    {:ok, req} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        dispatch_id: "00000000-0000-4000-8000-000000000003",
        workspace_ref: "workspace/fixture",
        prompt: "Check the fixture",
        policy: %{mode: "supervised"},
        requested_capabilities: []
      })

    req
  end

  for resumed? <- [false, true] do
    test "Codex sends the pinned model for #{if resumed?, do: "resumed", else: "fresh"} threads and turns" do
      response = fn frame ->
        result =
          case frame["method"] do
            "initialize" ->
              %{}

            method when method in ["thread/start", "thread/resume"] ->
              %{"thread" => %{"id" => "01950000-0000-7000-8000-000000000001"}}

            "turn/start" ->
              %{"turn" => %{"id" => "01950000-0000-7000-8000-000000000002"}}

            _ ->
              nil
          end

        if result, do: %{"id" => frame["id"], "result" => result}, else: :ignore
      end

      transport = start_supervised!({FakeTransport, [auto_respond: response]})

      session =
        start_supervised!(
          {Session,
           [
             run_request: request(),
             transport: FakeTransport,
             transport_pid: transport,
             auto_handshake: false,
             owner: self(),
             model: "fixture-model-v1",
             resume: unquote(resumed?),
             thread_id: if(unquote(resumed?), do: "01950000-0000-7000-8000-000000000001")
           ]}
        )

      :ok = FakeTransport.set_owner(transport, session)
      assert {:ok, _} = Session.await_run_identity(session)
      frames = FakeTransport.get_sent_frames(transport)
      method = if unquote(resumed?), do: "thread/resume", else: "thread/start"
      thread = Enum.find(frames, &(&1["method"] == method))
      turn = Enum.find(frames, &(&1["method"] == "turn/start"))
      assert thread["params"]["model"] == "fixture-model-v1"
      assert turn["params"]["model"] == "fixture-model-v1"
      assert turn["params"]["input"] == [%{"type" => "text", "text" => "Check the fixture"}]
    end
  end

  test "Claude launch includes the configured model as a distinct argv value" do
    session =
      start_supervised!(
        {Shoestring.Harness.ClaudeHeadless.Session,
         [
           run_request: request(),
           owner: self(),
           transport: Shoestring.Test.ArgvCaptureTransport,
           model: "fixture-claude-v1",
           permission_bypass: false
         ]}
      )

    state = :sys.get_state(session)
    opts = :sys.get_state(state.transport_pid)
    args = Keyword.fetch!(opts, :args)
    index = Enum.find_index(args, &(&1 == "--model"))
    assert is_integer(index)
    assert Enum.at(args, index + 1) == "fixture-claude-v1"
    assert List.last(args) == "Check the fixture"
    refute "--dangerously-skip-permissions" in args
  end
end
