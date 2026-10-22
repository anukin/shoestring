defmodule Shoestring.Harness.HTTPTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Harness.{Adapter, ContractSuite, HTTP, OpenAIResponses, OllamaLocal, Runs}
  alias Shoestring.Harness.HTTP.Session
  alias Shoestring.Test.{ElvesHelpers, HTTPTransport}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    api = Application.fetch_env(:shoestring, :api_execution)
    local = Application.fetch_env(:shoestring, :local_execution)
    key = System.get_env("OPENAI_API_KEY")
    artifacts = Application.fetch_env(:shoestring, :artifact_root)
    Application.put_env(:shoestring, :artifact_root, root)
    Application.put_env(:shoestring, :api_execution, Shoestring.Test.ApiSpendHelpers.config())

    Application.put_env(:shoestring, :local_execution, %{
      enabled: true,
      cloud_disabled_confirmed: true,
      server_version: "0.30.0",
      model: "fixture:local",
      model_digest: String.duplicate("a", 64),
      context_tokens: 8192,
      max_output_tokens: 512
    })

    System.put_env("OPENAI_API_KEY", "synthetic-unit-credential")

    on_exit(fn ->
      for {name, previous} <- [
            api_execution: api,
            local_execution: local,
            artifact_root: artifacts
          ] do
        case previous do
          {:ok, value} -> Application.put_env(:shoestring, name, value)
          :error -> Application.delete_env(:shoestring, name)
        end
      end

      if key, do: System.put_env("OPENAI_API_KEY", key), else: System.delete_env("OPENAI_API_KEY")
    end)

    :ok
  end

  test "both adapters obey shared identity, lifecycle, secret-free and terminal contracts" do
    for adapter <- [OpenAIResponses, OllamaLocal] do
      ContractSuite.assert_identity(adapter)
      ContractSuite.assert_missing_capacity(adapter, %{})
      request = request(adapter)

      opts = %{
        transport: HTTPTransport,
        clock: Shoestring.Test.HTTPClock,
        await_completion: fn identity ->
          {:ok, events} = Session.await(identity.run_id)

          assert Enum.any?(events, &(&1.kind == :result)),
                 inspect({adapter.identity().adapter_id, Enum.map(events, &{&1.kind, &1.error})})
        end
      }

      ContractSuite.assert_start_stream_completion_failure_cancellation(adapter, request, opts)

      run =
        Shoestring.Repo.get_by!(Shoestring.Harness.RunRecord, dispatch_id: request.dispatch_id)

      {:ok, events} = Session.await(run.id)

      {:ok, identity} =
        Shoestring.Harness.RunIdentity.new(%{
          run_id: run.id,
          harness_id: adapter.identity().adapter_id
        })

      ContractSuite.assert_secret_free(adapter, identity, events)
      ContractSuite.assert_terminal_idempotency(adapter, identity, opts)
      assert {:ok, %{status: "completed"}} = adapter.status(identity, opts)

      assert {:error, %{category: :unsupported_capability}} =
               Adapter.invoke_optional(adapter, :resume, :resume, [identity, request, opts])

      [result] = Enum.filter(events, &(&1.kind == :result))
      {:ok, artifact} = Shoestring.Trajectory.ArtifactStore.read(result.result.artifact_id)
      assert artifact.bytes =~ "Visible"
      refute artifact.bytes =~ "synthetic-private-value"
      refute artifact.bytes =~ "synthetic-private-thinking"
      HTTP.release(identity)
    end
  end

  test "default API zero/disabled policy refuses before any credential or transport work" do
    Application.delete_env(:shoestring, :api_execution)

    assert {:error, %{category: :quota_refused}} =
             OpenAIResponses.start(request(OpenAIResponses), %{
               transport: HTTPTransport,
               notify: self()
             })

    refute_received {:http_request, _, _, _}
    ContractSuite.assert_quota_refusal(OpenAIResponses, %{})
    ContractSuite.assert_missing_capacity(OpenAIResponses, %{})
    assert {:error, %{category: :unsupported_capability}} = OllamaLocal.probe(%{})
  end

  test "cancellation keeps ambiguous spend reserved and repeated delivery never calls again" do
    request = request(OpenAIResponses)

    opts = %{
      transport: HTTPTransport,
      clock: Shoestring.Test.HTTPClock,
      notify: self(),
      hold: true
    }

    {:ok, identity} = OpenAIResponses.start(request, opts)
    assert_receive {:http_request, task, "/v1/responses", body}, 1000
    assert body["store"] == false and body["tools"] == [] and body["truncation"] == "disabled"
    ref = Process.monitor(task)
    assert {:ok, :cancelled} = OpenAIResponses.cancel(identity, %{})
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 1000
    assert {:ok, %{"reserved_microusd" => 319_096}} = Shoestring.ApiSpend.summary()
    assert {:error, _} = OpenAIResponses.start(request, opts)
    HTTP.release(identity)
    assert {:error, _} = OpenAIResponses.start(request, opts)
    refute_received {:http_request, _, _, _}
  end

  test "missing usage and transport/provider refusals fail closed without persisting raw errors" do
    for opts <- [%{missing_usage: true}, %{scenario: :failure}, %{scenario: :quota}] do
      {:ok, identity} =
        OpenAIResponses.start(
          request(OpenAIResponses),
          Map.merge(opts, %{transport: HTTPTransport, clock: Shoestring.Test.HTTPClock})
        )

      assert {:ok, events} = Session.await(identity.run_id)
      refute Enum.any?(events, &(&1.kind == :result))
      assert Enum.any?(events, &(&1.kind == :error))
      HTTP.release(identity)
    end
  end

  test "local digest/cloud checks refuse inference and no subscription capacity is invented" do
    {:ok, identity} =
      OllamaLocal.start(request(OllamaLocal), %{
        transport: HTTPTransport,
        cloud: true,
        notify: self()
      })

    {:ok, events} = Session.await(identity.run_id)
    assert Enum.any?(events, &(&1.kind == :error))
    refute_received {:http_request, _, "/api/generate", _}
    HTTP.release(identity)
  end

  test "Elf owns the HTTP lifecycle without inventing a process group" do
    for adapter <- [OpenAIResponses, OllamaLocal] do
      %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
      request = ElvesHelpers.run_request(goal, task)

      {:ok, dispatch, _} =
        Shoestring.Harness.Dispatches.enqueue(request, adapter.identity(),
          clock: Shoestring.Test.HTTPClock
        )

      {:ok, _pid} =
        Shoestring.Elves.start_elf(request, dispatch,
          adapter: adapter,
          process_owner: :request,
          command: [],
          adapter_opts: %{transport: HTTPTransport},
          clock: Shoestring.Test.HTTPClock,
          event_interval_ms: 0,
          notify: self()
        )

      run_id = dispatch.run_id
      assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 10_000
      assert ElvesHelpers.count_events(goal.id, run_id, ["run.completed"]) == 1
    end
  end

  test "named queue-only client creates and recovers one dispatch without invoking a provider" do
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    dispatch_id = Ecto.UUID.generate()

    Shoestring.CLI.Jobs.with_client(fn client ->
      opts = [oban: client, dispatch_id: dispatch_id]

      assert {:ok, first, _} =
               Shoestring.TextRuns.enqueue("local", goal.id, task.id, "Synthetic text", opts)

      assert {:ok, second, _} =
               Shoestring.TextRuns.enqueue("local", goal.id, task.id, "Synthetic text", opts)

      assert first.dispatch_id == second.dispatch_id
    end)
  end

  test "write access is refused for both atom and string policy keys" do
    for policy <- [
          %{"mode" => "supervised", "write_access" => true},
          %{mode: "supervised", write_access: true}
        ] do
      request = %{request(OpenAIResponses) | policy: policy}

      assert {:error, _} =
               OpenAIResponses.start(request, %{
                 transport: HTTPTransport,
                 clock: Shoestring.Test.HTTPClock,
                 notify: self()
               })

      refute_received {:http_request, _, _, _}
    end
  end

  test "manual text creation is usable without preexisting goal/task records" do
    assert {:ok, dispatch, _} = Shoestring.TextRuns.create("local", "Synthetic visible prompt")

    assert Shoestring.Repo.get!(Shoestring.Trajectory.Goal, dispatch.goal_id).title ==
             "Manual text response"

    assert Shoestring.Repo.get!(Shoestring.Trajectory.Task, dispatch.task_id).status == "pending"
    refute_received {:http_request, _, _, _}

    assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
      Mix.Tasks.Shoestring.Text.run([
        "--provider",
        "local",
        "--prompt-file",
        "unused",
        "--goal",
        Ecto.UUID.generate()
      ])
    end
  end

  test "session crash ends its owned task and permanently fences replacement inference" do
    request = request(OpenAIResponses)

    opts = %{
      transport: HTTPTransport,
      clock: Shoestring.Test.HTTPClock,
      hold: true,
      notify: self()
    }

    {:ok, identity} = OpenAIResponses.start(request, opts)
    assert_receive {:http_request, task, "/v1/responses", _}, 1000
    [{session, _}] = Registry.lookup(Shoestring.Harness.HTTP.Registry, identity.run_id)
    task_ref = Process.monitor(task)
    session_ref = Process.monitor(session)
    Shoestring.Test.ElvesHelpers.kill_idle(session)
    assert_receive {:DOWN, ^session_ref, :process, ^session, _}, 1000
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1000
    assert {:error, _} = OpenAIResponses.start(request, opts)
    assert {:ok, %{"reserved_microusd" => 319_096}} = Shoestring.ApiSpend.summary()
    refute_received {:http_request, _, _, _}
  end

  test "explicit Elf cancellation stops the HTTP task and records cancellation with held spend" do
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    request = ElvesHelpers.run_request(goal, task)

    {:ok, dispatch, _} =
      Shoestring.Harness.Dispatches.enqueue(request, OpenAIResponses.identity(),
        clock: Shoestring.Test.HTTPClock
      )

    {:ok, elf} =
      Shoestring.Elves.start_elf(request, dispatch,
        adapter: OpenAIResponses,
        process_owner: :request,
        command: [],
        adapter_opts: %{transport: HTTPTransport, hold: true, notify: self()},
        clock: Shoestring.Test.HTTPClock,
        event_interval_ms: 0,
        notify: self()
      )

    assert_receive {:http_request, task_pid, "/v1/responses", _}, 1000
    ref = Process.monitor(task_pid)
    assert {:ok, :cancelled} = Shoestring.Elves.Elf.cancel(elf)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _}, 1000
    run_id = dispatch.run_id
    assert_receive {:elf_terminal, ^run_id, %{class: :cancelled}}, 1000
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.cancelled"]) == 1
    assert {:ok, %{"reserved_microusd" => 319_096}} = Shoestring.ApiSpend.summary()
  end

  defp request(adapter) do
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    request = ElvesHelpers.run_request(goal, task)
    {:ok, _} = Runs.request(request, adapter.identity())
    request
  end
end
