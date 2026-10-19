defmodule Shoestring.Harness.SessionTableOwnershipTest do
  use ExUnit.Case, async: false

  alias Shoestring.Harness.{ClaudeHeadless, CodexAppServer, Error, RunIdentity}
  alias Shoestring.Test.ProviderCliGuard

  for {adapter, session, transport, table, label} <- [
        {ClaudeHeadless, ClaudeHeadless.Session, Shoestring.Harness.ClaudeScriptedTransport,
         :claude_headless_sessions, "Claude"},
        {CodexAppServer, CodexAppServer.Session, Shoestring.Harness.Capacity.Codex.FakeTransport,
         :codex_app_server_sessions, "Codex"}
      ] do
    @adapter adapter
    @session session
    @transport transport
    @table table

    test "#{label}: finishing the first cache caller cannot hide a different live session" do
      guard = ProviderCliGuard.install!()
      test_pid = self()
      first = Ecto.UUID.generate()
      run_id = Ecto.UUID.generate()

      caller =
        start_supervised!(
          {Task,
           fn ->
             @adapter.lookup_session(first)
             send(test_pid, :cache_ready)

             receive do
               :finish -> :ok
             end
           end}
        )

      monitor = Process.monitor(caller)
      assert_receive :cache_ready

      transport = start_supervised!({@transport, emit_connected: false})

      session =
        start_supervised!(
          Supervisor.child_spec(
            {@session,
             run_id: run_id,
             owner: self(),
             transport: @transport,
             transport_pid: transport,
             auto_handshake: false,
             handshake_timeout_ms: 60_000,
             thread_id: "01950000-0000-7000-8000-000000000001"},
            restart: :temporary
          )
        )

      _ = :sys.get_state(session)
      true = :ets.insert(@table, {run_id, session})

      {:ok, identity} =
        RunIdentity.new(%{
          run_id: run_id,
          harness_id: "test",
          process_id: nil,
          provider_session_id: nil
        })

      on_exit(fn -> @adapter.release(identity) end)

      assert {:ok, []} = @adapter.stream(identity, %{live: true})
      send(caller, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}

      # The session itself still answers; only the former caller has ended.
      assert {:ok, %{}} = @session.status(session)
      assert {:ok, []} = @adapter.stream(identity, %{live: true})

      session_monitor = Process.monitor(session)
      :ok = stop_supervised(@session)
      assert_receive {:DOWN, ^session_monitor, :process, ^session, :shutdown}
      assert {:error, :not_found} = @adapter.lookup_session(run_id)

      assert {:error, %Error{category: :transport, code: "session_not_found"}} =
               @adapter.stream(identity, %{live: true})

      ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
    end
  end
end
