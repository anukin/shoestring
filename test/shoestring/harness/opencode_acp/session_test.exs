defmodule Shoestring.Harness.OpencodeAcp.SessionTest do
  # Drives the adapter end to end over real stdio against a scripted
  # `opencode acp` stand-in (`test/support/fake_opencode_acp.py`). No test
  # starts the real opencode binary or touches the network.
  use ExUnit.Case, async: true

  import Shoestring.Test.ElvesHelpers, only: [wait_until: 1]

  alias Shoestring.Harness.{Error, OpencodeAcp, RunIdentity, RunRequest}

  @fake Path.expand("../../../support/fake_opencode_acp.py", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "opencode-acp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, log: Path.join(dir, "frames.jsonl")}
  end

  defp request do
    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        workspace_ref: "workspace/opencode-test",
        prompt: "Do the task",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: [],
        dispatch_id: Ecto.UUID.generate()
      })

    request
  end

  defp opts(context, scenario, extra \\ %{}) do
    Map.merge(
      %{
        live: true,
        executable: System.find_executable("python3"),
        args: [@fake],
        workdir: context.dir,
        model: "opencode/test-model",
        handshake_timeout_ms: 10_000,
        env: [{"FAKE_OPENCODE_SCENARIO", scenario}, {"FAKE_OPENCODE_LOG", context.log}]
      },
      extra
    )
  end

  defp sent(context) do
    context.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp events_until_terminal(identity) do
    {:ok, events} =
      wait_until(fn ->
        {:ok, events} = OpencodeAcp.stream(identity, %{live: true})
        if Enum.any?(events, &(&1.kind in [:result, :error])), do: events
      end)

    events
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  test "a completed prompt streams normalized events and ends with the result", context do
    {:ok, %RunIdentity{} = identity} = OpencodeAcp.start(request(), opts(context, "complete"))
    assert identity.harness_id == "opencode_acp"
    assert identity.provider_session_id == "ses_000000000000000000000001"

    events = events_until_terminal(identity)
    kinds = Enum.map(events, & &1.kind)

    # Hidden reasoning and session metadata never become events.
    refute Enum.any?(events, &(inspect(&1.extensions) =~ "private reasoning"))

    assert [
             :output,
             :output,
             :output,
             :command,
             :lifecycle,
             :command,
             :tool,
             :tool,
             :lifecycle,
             :output,
             :output,
             :result
           ] =
             kinds

    [message | _] = Enum.filter(events, &Map.has_key?(&1.extensions, "opencode-acp:text"))
    assert message.extensions["opencode-acp:text"] == "Working in $HOME/x"

    [start, finish] = Enum.filter(events, &(&1.kind == :command))
    # The command arrives after the start (opencode 2.0.31), so the end
    # event carries it, with the exit status.
    assert start.extensions["opencode-acp:boundary"] == "start"
    refute Map.has_key?(start.extensions, "opencode-acp:command")
    assert finish.extensions["opencode-acp:boundary"] == "end"
    assert finish.extensions["opencode-acp:tool_call_id"] == "call_1"
    assert finish.extensions["opencode-acp:command"] == "printf hello"
    assert finish.extensions["opencode-acp:exit_code"] == 0
    assert List.last(events).extensions["opencode-acp:output_tokens"] == 10

    assert List.last(events).result == %{status: "completed", artifact_id: nil}
    assert Enum.map(events, & &1.ordinal) == Enum.to_list(1..length(events))

    # The model is set before the prompt; opencode's own default is never used.
    methods = sent(context) |> Enum.map(& &1["method"])
    assert methods == ["initialize", "session/new", "session/set_config_option", "session/prompt"]

    assert %{"configId" => "model", "value" => "opencode/test-model"} =
             Enum.at(sent(context), 2)["params"]

    OpencodeAcp.release(identity)
  end

  test "an expired provider login is an authentication error, not a task failure", context do
    {:ok, identity} = OpencodeAcp.start(request(), opts(context, "auth"))
    [error] = identity |> events_until_terminal() |> Enum.filter(&(&1.kind == :error))

    assert %Error{category: :authentication_required, code: "provider_auth_required"} =
             error.error

    OpencodeAcp.release(identity)
  end

  test "an unknown model refuses the start", context do
    assert {:error, %Error{category: :schema_incompatible, message: message}} =
             OpencodeAcp.start(request(), opts(context, "complete", %{model: "opencode/missing"}))

    assert message =~ "model not found"
  end

  test "a run without a model refuses before prompting", context do
    assert {:error, %Error{code: "model_required"}} =
             OpencodeAcp.start(request(), opts(context, "complete", %{model: nil}))

    refute "session/prompt" in Enum.map(sent(context), & &1["method"])
  end

  test "effort is applied only when the model offers it", context do
    {:ok, identity} = OpencodeAcp.start(request(), opts(context, "complete", %{effort: "medium"}))
    _ = events_until_terminal(identity)

    assert Enum.any?(
             sent(context),
             &(&1["params"]["configId"] == "effort" and &1["params"]["value"] == "medium")
           )

    OpencodeAcp.release(identity)

    assert {:error, %Error{code: "effort_not_offered"}} =
             OpencodeAcp.start(request(), opts(context, "complete", %{effort: "xhigh"}))
  end

  test "a newer protocol version refuses the start", context do
    assert {:error, %Error{category: :schema_incompatible, code: "protocol_version"}} =
             OpencodeAcp.start(request(), opts(context, "protocol"))
  end

  test "a stop reason other than end_turn fails the run", context do
    {:ok, identity} = OpencodeAcp.start(request(), opts(context, "refusal"))
    [error] = identity |> events_until_terminal() |> Enum.filter(&(&1.kind == :error))
    assert %Error{category: :task_failed, code: "refusal"} = error.error
    OpencodeAcp.release(identity)
  end

  test "an oversized frame fails the run closed", context do
    {:ok, identity} =
      OpencodeAcp.start(request(), opts(context, "oversized", %{max_frame_size: 65_536}))

    [error] = identity |> events_until_terminal() |> Enum.filter(&(&1.kind == :error))
    assert %Error{code: "oversized_frame"} = error.error
    OpencodeAcp.release(identity)
  end

  test "resume continues the earlier provider session in a new process", context do
    {:ok, first} = OpencodeAcp.start(request(), opts(context, "complete"))
    _ = events_until_terminal(first)
    OpencodeAcp.release(first)
    File.rm!(context.log)

    {:ok, resumed} = OpencodeAcp.resume(first, request(), opts(context, "complete"))
    assert resumed.provider_session_id == first.provider_session_id
    _ = events_until_terminal(resumed)

    assert ["initialize", "session/resume", "session/set_config_option", "session/prompt"] =
             Enum.map(sent(context), & &1["method"])

    assert Enum.at(sent(context), 1)["params"]["sessionId"] == first.provider_session_id
    OpencodeAcp.release(resumed)
  end

  # Base: an opencode run's sandbox temporary directory was never removed.
  test "shutdown removes the run's sandbox temporary directory after reaping", context do
    {:ok, temp} = Shoestring.SandboxTemp.create("shoestring-opencode")
    File.write!(Path.join(temp, "cache"), "x")

    session_opts =
      context
      |> opts("hang", %{sandbox_temp_dir: temp})
      |> Map.to_list()
      |> Keyword.merge(run_request: request(), run_id: Ecto.UUID.generate())

    {:ok, pid} = OpencodeAcp.Session.start_link(session_opts)
    {:ok, _identity} = OpencodeAcp.Session.await_run_identity(pid, 10_000)

    {:ok, %{"sleeper_pid" => sleeper}} =
      wait_until(fn ->
        File.exists?(context.log) && Enum.find(sent(context), &Map.has_key?(&1, "sleeper_pid"))
      end)

    OpencodeAcp.Session.shutdown(pid)
    refute File.exists?(temp)
    assert {:ok, true} = wait_until(fn -> not alive?(sleeper) end)
  end

  describe "permission requests" do
    test "an unsandboxed run refuses every permission request", context do
      {:ok, identity} = OpencodeAcp.start(request(), opts(context, "permission"))
      events = events_until_terminal(identity)

      assert Enum.any?(events, &(&1.extensions["opencode-acp:permission"] == "refused"))

      assert Enum.any?(
               events,
               &(&1.extensions["opencode-acp:text"] == "permission selected reject")
             )

      OpencodeAcp.release(identity)
    end

    test "a caller cannot claim a sandbox the adapter did not build", context do
      {:ok, identity} =
        OpencodeAcp.start(request(), opts(context, "permission", %{sandboxed: true}))

      events = events_until_terminal(identity)
      assert Enum.any?(events, &(&1.extensions["opencode-acp:permission"] == "refused"))
      OpencodeAcp.release(identity)
    end

    test "a sandboxed session allows once, never always", context do
      session_opts =
        context
        |> opts("permission", %{sandboxed: true})
        |> Map.to_list()
        |> Keyword.merge(run_request: request(), run_id: Ecto.UUID.generate())

      {:ok, pid} = OpencodeAcp.Session.start_link(session_opts)
      {:ok, identity} = OpencodeAcp.Session.await_run_identity(pid, 10_000)

      {:ok, events} =
        wait_until(fn ->
          {:ok, events} = OpencodeAcp.Session.stream_events(pid)
          if Enum.any?(events, &(&1.kind == :result)), do: events
        end)

      assert identity.harness_id == "opencode_acp"

      assert Enum.any?(events, &(&1.extensions["opencode-acp:permission"] == "allowed_once"))

      assert Enum.any?(
               events,
               &(&1.extensions["opencode-acp:text"] == "permission selected once")
             )

      OpencodeAcp.Session.shutdown(pid)
    end
  end

  describe "cancellation" do
    test "explicit cancel reaps every process group in the tree", context do
      {:ok, identity} = OpencodeAcp.start(request(), opts(context, "hang"))

      {:ok, %{"sleeper_pid" => sleeper, "child_pid" => child}} =
        wait_until(fn ->
          File.exists?(context.log) && Enum.find(sent(context), &Map.has_key?(&1, "sleeper_pid"))
        end)

      assert alive?(sleeper) and alive?(child)
      assert {:ok, :cancelled} = OpencodeAcp.cancel(identity, %{})

      # Both the separate-group child and the separate-group tool process
      # are gone: a killpg of the acp group alone would leave the sleeper.
      assert {:ok, true} = wait_until(fn -> not alive?(sleeper) and not alive?(child) end)

      events = events_until_terminal(identity)
      assert List.last(events).result == %{status: "interrupted", artifact_id: nil}
      OpencodeAcp.release(identity)
    end

    # Base: the Elf kills the acp group first on a verdict, then releases the
    # adapter; by then the tool's process was reparented and the tree walk
    # could not find it, so it outlived the run.
    test "release after the Elf killed the acp group still reaps tools in other groups",
         context do
      session_opts =
        context
        |> opts("hang", %{elf_owned_process_group: true})
        |> Map.to_list()
        |> Keyword.merge(run_request: request(), run_id: Ecto.UUID.generate())

      {:ok, pid} = OpencodeAcp.Session.start_link(session_opts)
      {:ok, identity} = OpencodeAcp.Session.await_run_identity(pid, 10_000)

      {:ok, %{"sleeper_pid" => sleeper}} =
        wait_until(fn ->
          File.exists?(context.log) && Enum.find(sent(context), &Map.has_key?(&1, "sleeper_pid"))
        end)

      # The session has seen the tool call (and so the tool's group).
      {:ok, _} =
        wait_until(fn ->
          {:ok, events} = OpencodeAcp.Session.stream_events(pid)
          Enum.any?(events, &(&1.kind == :command))
        end)

      pgid = String.to_integer(identity.process_id)
      System.cmd("kill", ["-KILL", "-#{pgid}"])
      assert {:ok, true} = wait_until(fn -> not alive?(pgid) end)
      assert alive?(sleeper)

      OpencodeAcp.Session.shutdown(pid)
      assert {:ok, true} = wait_until(fn -> not alive?(sleeper) end)
    end

    test "a safe stop only pends; nothing is sent until the outcome", context do
      {:ok, identity} = OpencodeAcp.start(request(), opts(context, "hang"))

      {:ok, _} =
        wait_until(fn ->
          File.exists?(context.log) && Enum.find(sent(context), &Map.has_key?(&1, "sleeper_pid"))
        end)

      {:ok, pid} = OpencodeAcp.lookup_session(identity.run_id)

      assert {:ok, :stop_requested} = OpencodeAcp.Session.request_safe_stop(pid)

      assert {:ok, %{stop_requested: :safe_boundary, status: :turn_in_progress}} =
               OpencodeAcp.status(identity)

      refute "session/cancel" in Enum.map(sent(context), & &1["method"])

      assert {:ok, :cancelled} = OpencodeAcp.cancel(identity, %{})
      OpencodeAcp.release(identity)
    end

    test "cancelling a finished run is idempotent", context do
      {:ok, identity} = OpencodeAcp.start(request(), opts(context, "complete"))
      _ = events_until_terminal(identity)
      assert {:ok, :cancelled} = OpencodeAcp.cancel(identity, %{})
      OpencodeAcp.release(identity)
      assert {:ok, :cancelled} = OpencodeAcp.cancel(identity, %{})
    end
  end
end
