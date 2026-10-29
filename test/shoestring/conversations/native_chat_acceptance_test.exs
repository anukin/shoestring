defmodule Shoestring.Conversations.NativeChatAcceptanceTest do
  @moduledoc "Integrated hermetic native-chat acceptance story. No provider CLI or remote network."
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_CHAT_ACCEPTANCE_CHILD") == "1" do
    import Phoenix.ChannelTest
    import Ecto.Query

    alias Shoestring.{
      AgentProfiles,
      Conversations,
      Dispatches,
      Grants,
      ModelCatalog,
      Repo,
      Trajectory
    }

    alias Shoestring.CLI.Commands.{Chat, Grant, Runs}
    alias Shoestring.Conversations.Engine
    alias Shoestring.Coordinator.Tools
    alias Shoestring.Harness.{DispatchRecord, Fake, RunRecord}
    alias Shoestring.Cobbler.{PlanExecutionWorker, PlanCancellationWorker}
    alias Shoestring.Test.{NativeChatWorker, ExploreStandIn, ReviewStandIn}
    @endpoint ShoestringWeb.Endpoint
    @brief "IMPLEMENT - make add() return the sum\nContract: test/test_calc.py passes.\n"
    @opts [conversation_module: Fake.Conversation, tools_url: nil, poll_ms: nil]

    setup do
      config = Application.fetch_env!(:shoestring, Repo)

      Application.put_env(
        :shoestring,
        Repo,
        Keyword.merge(config, pool: DBConnection.ConnectionPool, pool_size: 5)
      )

      Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)
      Application.put_env(:shoestring, :conversation_engine_opts, @opts)

      Application.put_env(:shoestring, :dispatch_calls,
        adapters: %{{"explore", "codex"} => ExploreStandIn, {"review", "codex"} => ReviewStandIn},
        adapter_opts: [test_pid: self(), blocking: false]
      )

      restart!()
      guard = Shoestring.Test.ProviderCliGuard.install!()
      on_exit(fn -> Shoestring.Test.ProviderCliGuard.assert_no_provider_cli_spawned!(guard) end)
      :ok
    end

    @tag timeout: 90_000
    test "grant, concurrent dispatches, checked commit, review, exact cancellation, restart and turn extension" do
      source = source!()
      base = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
      original = File.read!(Path.join(source, "calc.py"))
      {:ok, _} = ModelCatalog.add("claude", "opus")
      {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")

      {:ok, agent} =
        AgentProfiles.create(
          Shoestring.ConfigurationFixtures.agent_attrs(%{
            "roles" => [
              %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
              %{"name" => "Worker", "provider" => "claude", "model" => "opus"},
              %{"name" => "Reviewer", "provider" => "codex", "model" => "gpt-6-luna"}
            ]
          })
        )

      {:ok, _} =
        AgentProfiles.save_settings(AgentProfiles.settings(), %{"default_agent_id" => agent.id})

      ctx = %{
        shell: Mix.Shell.Process,
        with_repo: fn f -> f.(Repo) end,
        cwd: source,
        service: fn -> :ok end,
        start_hint: "fixture",
        interactive?: fn -> true end,
        find: fn _ -> "/synthetic/provider" end,
        chat_client: System.find_executable("true")
      }

      send(self(), {:mix_shell_input, :prompt, "y"})

      Grant.run(
        [
          "--session",
          "chat-acceptance",
          "--models",
          "claude:opus,codex:gpt-6-luna",
          "--max-dispatches",
          "8",
          "--max-parallel",
          "3",
          "--unread-usage",
          "8",
          "--max-turns",
          "4"
        ],
        ctx
      )

      assert_receive {:mix_shell, :info, [_]}
      assert Grants.active("chat-acceptance").max_turns == 4
      Chat.run(["--session", "chat-acceptance"], ctx)
      assert_receive {:mix_shell, :info, [launch]}
      assert Jason.decode!(launch)["argv"] |> hd() == ctx.chat_client
      conversation = Conversations.get("chat-acceptance")
      Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(conversation.id))
      socket = join!()
      engine = Conversations.engine(conversation)
      binding = %{session_id: "chat-acceptance", repository: source}
      say!(socket, "SAY Begin the acceptance story")
      ended!()
      assert turns() == 1

      # Scripted coordinator invokes the real tool boundary, with different worker harnesses.
      implement = dispatch!(binding, "implement", "claude:opus", "Implement sum")
      explore = dispatch!(binding, "explore", "codex:gpt-6-luna", "Explain missing sum")
      healthy_claude!()
      healthy_codex!()
      {:ok, udp} = :gen_udp.open(0, [:binary, active: true, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(udp) end)
      {:ok, {_ip, port}} = :inet.sockname(udp)
      configure_worker(port, Fake.Scenario.normal_completion(now: DateTime.utc_now()))
      worker = start_worker!(implement)
      assert_receive {:udp, ^udp, _, _, group}, 5_000
      [pgid, descendant] = group |> String.split() |> Enum.map(&String.to_integer/1)
      assert Shoestring.Elves.PortRunner.alive_id?(pgid)

      state!(socket, fn rows ->
        Enum.any?(rows, &(&1["dispatch_id"] == implement.id and &1["state"] == "running")) and
          Enum.any?(
            rows,
            &(&1["dispatch_id"] == explore.id and &1["worker"] == "codex:gpt-6-luna")
          )
      end)

      complete_call!(explore)
      :ok = Engine.poll(engine)
      ended!()
      assert turns() == 2
      ref = Process.monitor(worker)
      send(worker, :release_stream)
      assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 15_000
      assert :ok = PlanExecutionWorker.perform(job!(implement))
      assert Dispatches.state(implement) == "completed"
      :ok = Engine.poll(engine)
      ended!()
      assert turns() == 3
      result = (Runs.detail(implement) |> Jason.encode!() |> Jason.decode!())["result"]
      commit = result["commit"]
      assert commit != base
      assert Enum.any?(result["checks"], &(&1["exit_status"] == 0))
      assert Enum.any?(result["take"], &String.contains?(&1, "git"))
      refute Shoestring.Elves.PortRunner.alive_id?(pgid)
      assert {_, 1} = System.cmd("kill", ["-0", to_string(descendant)], stderr_to_stdout: true)

      review =
        dispatch!(binding, "review", "codex:gpt-6-luna", "Review sum", %{"of" => implement.id})

      complete_call!(review)
      assert Runs.detail(review)["report"]["outcome"] == "approved"
      :ok = Engine.poll(engine)
      ended!()
      assert turns() == 4
      ref = push(socket, "watch_dispatch", %{"dispatch_id" => implement.id})
      assert_reply ref, :ok, %{"lines" => lines, "steps" => %{"entries" => entries}}, 5_000
      assert Enum.any?(lines, &String.contains?(&1, commit))
      assert Enum.any?(lines, &String.contains?(&1, "checks"))
      assert Enum.any?(entries, &String.contains?(&1["line"], "All checks passed"))
      ref = push(socket, "watch_dispatch", %{"dispatch_id" => review.id})
      assert_reply ref, :ok, %{"lines" => review_lines}, 5_000
      assert Enum.any?(review_lines, &String.contains?(&1, "approved"))

      # Implement executions run one at a time across goals: while the first
      # holds the execution claim the second waits (scope_occupied). An explore
      # call runs alongside it in its own process group, as real explorers do.
      # Cancelling the running implement from the chat channel reaps exactly
      # its owned group; the running explore and its group, and the waiting
      # dispatch, are untouched. The waiting one then runs.
      working = Shoestring.Test.FanoutNodeHelpers.working_scenario()
      configure_worker(port, working)
      first = dispatch!(binding, "implement", "claude:opus", "Cancel only this")

      second =
        dispatch!(binding, "implement", "claude:opus", "Keep running", %{
          "files" => ["notes.md"]
        })

      first_elf = start_worker!(first)
      assert_receive {:udp, ^udp, _, _, first_group}, 5_000
      send(first_elf, :release_stream)
      _ = :sys.get_state(first_elf)
      [first_pgid, first_child] = group_ids(first_group)
      assert {:snooze, 60} = PlanExecutionWorker.perform(job!(second))
      assert Dispatches.advance(second) == :none

      calls = Application.fetch_env!(:shoestring, :dispatch_calls)

      Application.put_env(
        :shoestring,
        :dispatch_calls,
        Keyword.update!(calls, :adapter_opts, &Keyword.put(&1, :scenario, :process_group))
      )

      alongside = dispatch!(binding, "explore", "codex:gpt-6-luna", "Explore alongside")
      assert {:snooze, 30} = Shoestring.Dispatches.Calls.step(alongside.id)
      assert Dispatches.advance(alongside) == :confirmed
      exploring = Task.async(fn -> Shoestring.Dispatches.Calls.step(alongside.id) end)
      assert_receive {:explore_group, explore_pgid, explorer}, 5_000
      assert Shoestring.Elves.PortRunner.alive_id?(explore_pgid)
      assert Dispatches.state(alongside) == "running"
      first_ref = Process.monitor(first_elf)

      ref =
        push(socket, "cancel_dispatch", %{
          "dispatch_id" => first.id,
          "reason" => "Cancelled by the person from the chat screen"
        })

      assert_reply ref, :ok, %{}, 5_000
      cancel_jobs!(first)
      assert_receive {:DOWN, ^first_ref, :process, ^first_elf, :normal}, 10_000
      refute Shoestring.Elves.PortRunner.alive_id?(first_pgid)
      assert {_, 1} = System.cmd("kill", ["-0", to_string(first_child)], stderr_to_stdout: true)
      assert Dispatches.state(first) == "cancelled"
      assert Shoestring.Elves.PortRunner.alive_id?(explore_pgid)
      assert Dispatches.state(alongside) == "running"
      assert Dispatches.state(second) == "waiting"
      assert Dispatches.latest_run(second) == nil

      send(explorer, :release_explore)
      assert :done = Task.await(exploring, 10_000)
      assert Dispatches.state(alongside) == "completed"
      Application.put_env(:shoestring, :dispatch_calls, calls)

      second_elf = start_worker!(second)
      assert_receive {:udp, ^udp, _, _, second_group}, 5_000
      send(second_elf, :release_stream)
      _ = :sys.get_state(second_elf)
      [second_pgid, _] = group_ids(second_group)
      assert Dispatches.state(second) == "running"

      # A fifth turn is held while the remaining Elf continues, then extended by a person.
      say!(socket, "SAY After extension")

      assert_receive {:trajectory_event_committed,
                      %{type: "conversation.turn.held", payload: %{"reason" => "turns_exhausted"}}},
                     5_000

      assert turns() == 4
      assert Shoestring.Elves.PortRunner.alive_id?(second_pgid)
      {:ok, _} = Grants.extend(Grants.active("chat-acceptance"), %{add_turns: 2}, "human:fixture")
      :ok = Engine.poll(engine)
      ended!()
      assert turns() == 5
      # No source-editing tool is offered to this scripted coordinator.
      assert {:error, _} =
               Tools.call("write_file", %{"path" => "calc.py", "text" => "pwned"}, binding)

      assert File.read!(Path.join(source, "calc.py")) == original
      assert String.trim(git!(source, ["rev-parse", "HEAD"])) == base
      assert git!(source, ["status", "--porcelain"]) == ""

      # Client detach and service restart mid-run retain identities and never charge a call again.
      requested = Repo.aggregate(RunRecord, :count)
      calls = Repo.aggregate(Shoestring.Dispatches.Call, :count)
      charged = turns()
      {:ok, history_before} = Conversations.history(conversation)
      Process.unlink(socket.channel_pid)
      close(socket)
      # Each subscription (ours and subscribe_and_join's) links this process to
      # a PubSub registry partition, whose shutdown in the restart would
      # otherwise end this test.
      Phoenix.PubSub.unsubscribe(Shoestring.PubSub, Trajectory.topic(conversation.id))
      Phoenix.PubSub.unsubscribe(Shoestring.PubSub, "conversation:chat-acceptance")
      restart!()
      assert Shoestring.Elves.PortRunner.alive_id?(second_pgid)

      assert {:ok, :adopted} =
               Shoestring.Elves.reconcile(Dispatches.latest_run(second).id,
                 runner_opts: [kill_grace_ms: 100, reap_timeout_ms: 2000]
               )

      socket = join!()
      assert turns() == charged
      assert Repo.aggregate(RunRecord, :count) == requested
      assert Repo.aggregate(Shoestring.Dispatches.Call, :count) == calls
      {:ok, history_after} = Conversations.history(conversation)
      assert history_after.messages == history_before.messages
      assert history_after.inbox == history_before.inbox
      assert Dispatches.latest_run(second).id != nil

      state!(socket, fn rows ->
        Enum.any?(rows, &(&1["dispatch_id"] == second.id and &1["state"] == "running"))
      end)

      # Explicitly end the remaining demo run; nothing is abandoned or timer-cancelled.
      ref =
        push(socket, "cancel_dispatch", %{
          "dispatch_id" => second.id,
          "reason" => "Acceptance demo finished"
        })

      assert_reply ref, :ok, %{}, 5_000
      cancel_jobs!(second)
      refute Shoestring.Elves.PortRunner.alive_id?(second_pgid)
      assert turns() == charged

      IO.puts(
        "NATIVE_CHAT_ACCEPTANCE: explore + implement + review, checks/take, exact group cancellation beside a running explore, restart, turn cap/extension, edit refusal; zero provider invocations"
      )
    end

    defp group_ids(text), do: text |> String.split() |> Enum.map(&String.to_integer/1)
    defp turns, do: Grants.active("chat-acceptance").turns_used

    defp ended!,
      do: assert_receive({:trajectory_event_committed, %{type: "conversation.turn.ended"}}, 5_000)

    defp say!(socket, text) do
      ref = push(socket, "say", %{"message_id" => Ecto.UUID.generate(), "text" => text})
      assert_reply ref, :ok, %{}, 5_000
    end

    defp join! do
      {:ok, _, socket} =
        subscribe_and_join(
          socket(ShoestringWeb.ChatSocket, nil, %{session_id: "chat-acceptance"}),
          ShoestringWeb.ChatChannel,
          "conversation:chat-acceptance",
          %{}
        )

      socket
    end

    defp state!(socket, predicate) do
      send(socket.channel_pid, :state)
      state_until(predicate, System.monotonic_time(:millisecond) + 5_000)
    end

    defp state_until(predicate, deadline) do
      wait = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        %Phoenix.Socket.Message{event: "state", payload: %{"dispatches" => rows}} ->
          if predicate.(rows), do: :ok, else: state_until(predicate, deadline)
      after
        wait -> flunk("chat did not show the expected dispatch state")
      end
    end

    defp dispatch!(binding, purpose, worker, title, extra \\ %{}) do
      {:ok, %{"dispatch_id" => id}} =
        Tools.call(
          "dispatch",
          Map.merge(
            %{
              "request_id" => Ecto.UUID.generate(),
              "purpose" => purpose,
              "worker" => worker,
              "title" => title,
              "brief" => @brief,
              "files" => ["calc.py"]
            },
            extra
          ),
          binding
        )

      Dispatches.get(id)
    end

    defp complete_call!(dispatch) do
      assert {:snooze, 30} = Shoestring.Dispatches.Calls.step(dispatch.id)
      assert Dispatches.advance(dispatch) == :confirmed
      assert :done = Shoestring.Dispatches.Calls.step(dispatch.id)
    end

    defp job!(dispatch),
      do:
        Repo.one!(
          from j in Oban.Job,
            where:
              j.worker == "Shoestring.Cobbler.PlanExecutionWorker" and
                fragment("json_extract(?, '$.goal_id')", j.args) == ^dispatch.goal_id
        )

    defp start_worker!(dispatch) do
      assert {:snooze, 60} = PlanExecutionWorker.perform(job!(dispatch))
      assert Dispatches.advance(dispatch) == :confirmed
      assert {:snooze, 5} = PlanExecutionWorker.perform(job!(dispatch))
      run = Dispatches.latest_run(dispatch)
      delivery = Repo.get_by!(DispatchRecord, run_id: run.id)
      assert :ok = Shoestring.Harness.DispatchWorker.perform(Repo.get!(Oban.Job, delivery.job_id))
      assert_receive {:fanout_stream_ready, pid, _}, 5_000

      on_exit(fn ->
        send(pid, :release_stream)
        Shoestring.Elves.cancel_run(run.id)
      end)

      pid
    end

    defp cancel_jobs!(dispatch) do
      jobs =
        Repo.all(
          from j in Oban.Job,
            where:
              j.worker == "Shoestring.Cobbler.PlanCancellationWorker" and
                fragment("json_extract(?, '$.goal_id')", j.args) == ^dispatch.goal_id
        )

      for job <- jobs, do: assert(:ok = PlanCancellationWorker.perform(job))
    end

    defp configure_worker(port, scenario) do
      Application.put_env(:shoestring, :elf_dispatch_opts,
        adapter: NativeChatWorker,
        process_owner: :runner,
        command: [
          System.find_executable("python3"),
          Path.expand("test/support/native_chat_process.py"),
          to_string(port)
        ],
        adapter_opts: %{scenario: scenario, barrier_parent: self()},
        runner_opts: [kill_grace_ms: 1000, reap_timeout_ms: 2000]
      )
    end

    defp restart! do
      pid = Process.whereis(Shoestring.Supervisor)
      ref = Process.monitor(pid)
      :ok = Application.stop(:shoestring)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
      assert {:ok, _} = Application.ensure_all_started(:shoestring)
    end

    defp source! do
      dir = Path.join(Shoestring.State.root(), "native-chat-repository")
      File.mkdir_p!(Path.join(dir, "test"))
      File.write!(Path.join(dir, "test/__init__.py"), "")
      File.write!(Path.join(dir, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")

      File.write!(
        Path.join(dir, "test/test_calc.py"),
        "import unittest\nfrom calc import add\nclass SumTest(unittest.TestCase):\n    def test_sum(self): self.assertEqual(add(2, 3), 5)\n"
      )

      git!(dir, ["init", "-q", "-b", "main"])
      git!(dir, ["config", "user.name", "Fixture"])
      git!(dir, ["config", "user.email", "fixture@example.invalid"])
      git!(dir, ["add", "."])
      git!(dir, ["commit", "-qm", "base"])
      dir
    end

    defp git!(dir, args) do
      {output, status} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      assert status == 0, output
      output
    end

    defp healthy_codex! do
      now = DateTime.utc_now()
      snapshot = Fake.Scenario.healthy_snapshot(Ecto.UUID.generate(), now)

      snapshot = %{
        snapshot
        | source: %{
            adapter_id: "codex_app_server_stdio",
            provider_id: "codex",
            invocation_mode: "app_server_stdio",
            event: :explicit_read
          },
          support_tier: :proactive,
          windows:
            snapshot.windows ++
              [%{kind: "seven_day", state: :observed, used_percent: 10.0, reset_at: nil}]
      }

      {:ok, _, _} = Shoestring.Harness.Observatory.ingest(snapshot, now: now)
    end

    defp healthy_claude! do
      now = DateTime.utc_now()
      reset = DateTime.to_unix(DateTime.add(now, 3600))

      frame = %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "status" => "allowed",
          "rateLimitType" => "five_hour",
          "unifiedWindows" => %{
            "five_hour" => %{"utilization" => 0.2, "resetsAt" => reset, "status" => "allowed"},
            "seven_day" => %{
              "utilization" => 0.1,
              "resetsAt" => reset + 86400,
              "status" => "allowed"
            }
          }
        }
      }

      {:ok, snapshot} =
        Shoestring.Harness.Capacity.normalize(:claude, :headless_stream_json, frame,
          version: "2.1.310",
          now: now,
          captured_at: now,
          adapter_id: "claude_headless_stream_json",
          scope: "subscription"
        )

      {:ok, _, _} = Shoestring.Harness.Observatory.ingest(snapshot, now: now)
    end
  else
    @tag timeout: 120_000
    test "the native chat acceptance story on an isolated hermetic node" do
      root = Path.join(File.cwd!(), ".shoestring/chat-acceptance-#{Ecto.UUID.generate()}")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess,sys; r=subprocess.run(['mix','test',sys.argv[1],'--seed','0'],stdin=subprocess.DEVNULL,timeout=100); sys.exit(r.returncode)",
            "test/shoestring/conversations/native_chat_acceptance_test.exs"
          ],
          env: [{"SHOESTRING_CHAT_ACCEPTANCE_CHILD", "1"}, {"SHOESTRING_TEST_STATE_DIR", root}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "NATIVE_CHAT_ACCEPTANCE:"
      assert output =~ "1 test, 0 failures"
    end
  end
end
