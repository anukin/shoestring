defmodule Shoestring.Harness.ClaudeHeadless.AdapterStartTest do
  @moduledoc """
  Closes the seam between `ClaudeHeadless.start/2` and the first frame:
  start must block until the provider session id is observed and return
  it — never a nil placeholder — and must unblock with an error (never
  hang) when no frame can ever arrive.

  Choreography note: `start/2` blocks inside `await_run_identity`, so the
  frames must be emitted concurrently — but the emitter cannot emit until
  the session exists. The double reports the fresh session pid back
  (`:claude_scripted_adopted`), which is the deterministic sync point: no
  polling, no sleeps. `start/2` itself runs in the test process (which
  outlives the test), because a session is bound to the lifetime of
  whatever process starts it.
  """

  use ExUnit.Case, async: true

  alias Shoestring.Harness.{ClaudeHeadless, ClaudeScriptedTransport, Error, RunRequest}

  @fixture_dir "plans/evidence/04-single-elf/fixtures/claude"
  @real_session_id "aaaaaaaa-0000-4000-a000-000000000002"

  defp fixture_lines(name) do
    Path.join(@fixture_dir, name)
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  # Unique dispatch ids: the adapter registers live sessions in a global
  # ETS table, so these must not collide with any other test's run id.
  defp make_request(dispatch_id) do
    {:ok, req} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        workspace_ref: "workspace/contract-test",
        prompt: "Run tests",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: [],
        dispatch_id: dispatch_id
      })

    req
  end

  # Starts an emitter task that registers with the double, waits for the
  # session to boot, then runs the given zero-arity emit fun. Returns the
  # session pid once the emitter observes it.
  defp start_emitter(transport, emit_fun) do
    test = self()

    Task.async(fn ->
      :ok = GenServer.call(transport, {:set_test_pid, self()})
      send(test, :emitter_ready)

      session =
        receive do
          {:claude_scripted_adopted, pid} -> pid
        after
          5_000 -> flunk("session never booted")
        end

      send(test, {:emitter_session, session})
      emit_fun.()
    end)
  end

  test "start/2 returns the real provider session id from the first frame" do
    req = make_request("00000000-0000-4000-8000-000000000031")
    lines = fixture_lines("stream-json-tool-exec.jsonl")

    {:ok, transport} =
      start_supervised({ClaudeScriptedTransport, owner: nil, lines: lines})

    _emitter =
      start_emitter(transport, fn ->
        :ok = ClaudeScriptedTransport.emit(transport)
      end)

    assert_receive :emitter_ready, 5_000

    assert {:ok, identity} =
             ClaudeHeadless.start(req, %{
               transport: ClaudeScriptedTransport,
               transport_pid: transport
             })

    assert identity.run_id == req.dispatch_id
    assert identity.provider_session_id == @real_session_id

    assert_receive {:emitter_session, session}, 5_000
    GenServer.stop(session)
  end

  test "a child that exits before emitting any frame unblocks start/2 with an error" do
    req = make_request("00000000-0000-4000-8000-000000000032")

    {:ok, transport} =
      start_supervised({ClaudeScriptedTransport, owner: nil, lines: [], exit_status: 1})

    _emitter =
      start_emitter(transport, fn ->
        :ok = ClaudeScriptedTransport.emit(transport)
      end)

    assert_receive :emitter_ready, 5_000

    assert {:error, %Error{}} =
             ClaudeHeadless.start(req, %{
               transport: ClaudeScriptedTransport,
               transport_pid: transport
             })

    assert_receive {:emitter_session, session}, 5_000
    GenServer.stop(session)
  end
end
