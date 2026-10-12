defmodule Shoestring.Harness.CodexAppServer.SessionHistoryTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.{CodexAppServer, Error, RunIdentity, RunRequest}
  alias Shoestring.Harness.CodexAppServer.Session
  alias Shoestring.Harness.Capacity.Codex.FakeTransport

  for ephemeral <- [true, false] do
    test "fresh execution forwards ephemeral=#{ephemeral} without changing model or task",
      do: assert_fresh([ephemeral: unquote(ephemeral)], unquote(ephemeral))
  end

  test "omitting the option retains provider history for existing resumable execution" do
    assert_fresh([], false)
  end

  test "ephemeral resume is refused before opening a transport" do
    assert {:error, :ephemeral_resume_unsupported} =
             Session.start_link(ephemeral: true, resume: true, command: "not-a-provider")

    {:ok, prior} =
      RunIdentity.new(%{
        run_id: request().dispatch_id,
        harness_id: CodexAppServer.identity().adapter_id,
        process_id: "synthetic-process",
        provider_session_id: "01950000-0000-7000-8000-000000000099"
      })

    assert {:error,
            %Error{category: :unsupported_capability, code: "ephemeral_resume_unsupported"}} =
             CodexAppServer.resume(prior, request(), %{
               live: true,
               ephemeral: true,
               command: "not-a-provider"
             })
  end

  test "invalid history options are refused rather than silently persisting" do
    for value <- [nil, "true", "false", 1] do
      assert {:error, :invalid_ephemeral_option} =
               Session.start_link(ephemeral: value, command: "not-a-provider")
    end
  end

  defp assert_fresh(history_opts, expected_ephemeral) do
    transport =
      start_supervised!(
        {FakeTransport,
         auto_respond: %{
           "initialize" => %{"result" => %{}},
           "thread/start" => %{
             "result" => %{"thread" => %{"id" => "01950000-0000-7000-8000-000000000099"}}
           },
           "turn/start" => %{
             "result" => %{"turn" => %{"id" => "01950000-0000-7000-8000-000000000088"}}
           }
         }}
      )

    session =
      start_supervised!(
        {Session,
         [
           run_request: request(),
           transport_pid: transport,
           transport: FakeTransport,
           auto_handshake: false,
           model: "fixture-model"
         ] ++ history_opts}
      )

    :ok = FakeTransport.set_owner(transport, session)
    assert {:ok, _} = Session.await_run_identity(session, 5_000)

    frames = FakeTransport.get_sent_frames(transport)
    %{"params" => params} = Enum.find(frames, &(&1["method"] == "thread/start"))
    assert params["ephemeral"] == expected_ephemeral
    assert params["model"] == "fixture-model"
    assert params["cwd"] == "workspace/history-fixture"
    assert params["sandbox"] == "workspace-write"

    %{"params" => turn} = Enum.find(frames, &(&1["method"] == "turn/start"))
    assert turn["model"] == "fixture-model"
    assert turn["input"] == [%{"type" => "text", "text" => "Implement the approved task"}]
    refute Enum.any?(frames, &(&1["method"] == "thread/resume"))
  end

  defp request do
    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        workspace_ref: "workspace/history-fixture",
        prompt: "Implement the approved task",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: [],
        dispatch_id: "00000000-0000-4000-8000-000000000003"
      })

    request
  end
end
