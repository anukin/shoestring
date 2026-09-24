defmodule Shoestring.Harness.ClaudeHeadless.AdapterIsolationTest do
  @moduledoc """
  A crash or corrupt input in the Claude parser/session must not affect
  the Codex adapter or any other running session: separate processes,
  total parser, no shared mutable state.

  Hermetic by construction, not by the host's luck: the Codex session runs on
  the in-memory `FakeTransport`. It used to start its default
  `StdioTransport`, assuming "no provider CLI here", so wherever `codex` was
  on `PATH` every `mix test` launched a real `codex app-server --stdio`.
  `Shoestring.Test.ProviderCliGuard` proves no provider CLI is spawned.
  """

  use ExUnit.Case, async: false

  alias Shoestring.Harness.{ClaudeHeadless, CodexAppServer, RunRequest}
  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.ClaudeHeadless.{EventNormalizer, Session}
  alias Shoestring.Test.ProviderCliGuard

  @run_id "00000000-0000-4000-8000-000000000003"

  defp make_test_run_request do
    {:ok, req} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        workspace_ref: "workspace/test",
        prompt: "test isolation",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: [],
        dispatch_id: @run_id
      })

    req
  end

  setup do
    %{guard: ProviderCliGuard.install!()}
  end

  describe "adapter isolation" do
    test "corrupt input to the Claude parser never raises and never touches Codex", %{
      guard: guard
    } do
      # 1. Feed malformed JSON-shaped payloads into the Claude normalizer.
      assert {:skip, :unhandled_frame} =
               EventNormalizer.normalize(%{"corrupted" => true}, @run_id, 1, %{})

      assert {:skip, :no_emittable_content} =
               EventNormalizer.normalize(
                 %{"type" => "assistant", "message" => %{"content" => nil}},
                 @run_id,
                 1,
                 %{}
               )

      assert {:skip, :unhandled_frame} =
               EventNormalizer.normalize(nil, @run_id, 1, %{})

      assert {:skip, :unhandled_frame} =
               EventNormalizer.normalize([["deeply", ["nested", ["lists"]]]], @run_id, 1, %{})

      result =
        EventNormalizer.normalize(
          %{"type" => "result", "is_error" => "maybe", "result" => %{}},
          @run_id,
          1,
          %{}
        )

      assert match?({:ok, _}, result) or match?({:skip, _}, result)

      # 2. ASSERTION: the Codex adapter is completely unaffected.
      identity = CodexAppServer.identity()
      assert identity.adapter_id == "codex_app_server_stdio"
      assert CodexAppServer.capabilities() == MapSet.new([:resume, :cancel])

      {:ok, req} =
        RunRequest.new(%{
          version: 1,
          goal_id: "00000000-0000-4000-8000-000000000001",
          task_id: "00000000-0000-4000-8000-000000000002",
          workspace_ref: "workspace/test",
          prompt: "codex still works",
          policy: %{mode: "supervised", network: false, write_access: true},
          requested_capabilities: [],
          dispatch_id: "00000000-0000-4000-8000-000000000004"
        })

      assert {:ok, _} = CodexAppServer.start(req, %{})
      ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
    end

    test "killing a Claude session does not take down a Codex session", %{guard: guard} do
      req = make_test_run_request()

      # A live Codex session on an in-memory transport: a real session
      # process with a connected transport, and no OS process at all.
      transport = start_supervised!({FakeTransport, emit_connected: false})

      {:ok, codex_session} =
        CodexAppServer.Session.start_link(
          run_request: req,
          transport: FakeTransport,
          transport_pid: transport,
          auto_handshake: false,
          handshake_timeout_ms: 60_000,
          thread_id: "01950000-0000-7000-8000-000000000001"
        )

      Process.unlink(codex_session)
      on_exit(fn -> Process.exit(codex_session, :kill) end)

      # The session has adopted the transport (its `handle_continue` ran).
      assert :sys.get_state(codex_session).transport_pid == transport

      # A Claude session on a scripted double, then an abrupt crash.
      {:ok, claude_session} =
        Session.start_link(
          run_request: req,
          run_id: req.dispatch_id,
          transport_pid: self(),
          transport: __MODULE__.NullTransport,
          owner: self()
        )

      Process.unlink(claude_session)
      claude_ref = Process.monitor(claude_session)
      Process.exit(claude_session, :kill)
      assert_receive {:DOWN, ^claude_ref, :process, ^claude_session, :killed}

      # ASSERTION: the Codex session, its transport, and both adapters are
      # unaffected.
      assert Process.alive?(codex_session)
      assert Process.alive?(transport)
      assert :sys.get_state(codex_session).transport_pid == transport
      assert ClaudeHeadless.identity().adapter_id == "claude_headless_stream_json"
      assert CodexAppServer.identity().adapter_id == "codex_app_server_stdio"

      ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
    end
  end

  defmodule NullTransport do
    def os_pid(_pid), do: nil
    def terminate_group(_pid, _opts \\ []), do: {:ok, :already_exited}
  end
end
