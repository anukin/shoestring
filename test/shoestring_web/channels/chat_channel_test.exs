defmodule ShoestringWeb.ChatChannelTest do
  @moduledoc """
  The chat socket and channel with `Shoestring.Harness.Fake.Conversation`
  as the coordinator, a real temporary Git repository, a grant and Oban in
  manual testing mode: no provider, network or listener.
  """
  use Shoestring.DataCase, async: false

  import Phoenix.ChannelTest
  import Ecto.Query

  alias Shoestring.{Conversations, Grants, ModelCatalog, Repo, Trajectory}
  alias Shoestring.Conversations.{ChatToken, Engine, Resume}
  alias Shoestring.Coordinator.Tools
  alias Shoestring.Harness.Fake
  alias ShoestringWeb.{ChatChannel, ChatSocket}

  @endpoint ShoestringWeb.Endpoint
  @brief "IMPLEMENT - make add() return the sum\nContract: test/test_calc.py passes.\n"
  @engine_opts [conversation_module: Fake.Conversation, tools_url: nil, poll_ms: nil]

  setup do
    session = "chat-#{System.unique_integer([:positive])}"
    repo = Path.join(System.tmp_dir!(), "shoestring-chat-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    on_exit(fn -> File.rm_rf!(repo) end)
    on_exit(fn -> File.rm_rf!(Path.dirname(ChatToken.path(session))) end)
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    # A grant names the repository's canonical root.
    {root, 0} = System.cmd("git", ["-C", repo, "rev-parse", "--show-toplevel"])
    repo = String.trim(root)

    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
    {:ok, grant} = grant(session, repo)
    {:ok, conversation} = open(session, repo)
    {:ok, token} = ChatToken.ensure(session)

    start_supervised!(
      Supervisor.child_spec({Engine, {conversation, @engine_opts}}, restart: :temporary)
    )

    %{
      session: session,
      repo: repo,
      grant: grant,
      conversation: conversation,
      token: token,
      socket: socket(ChatSocket, nil, %{session_id: session})
    }
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  test "a worker lost during a service stop has explicit wording and unknown elapsed time", ctx do
    {:ok, dispatch, :recorded} =
      Shoestring.Dispatches.create(%{
        session_id: ctx.session,
        request_id: "lost",
        purpose: "implement",
        provider: "codex",
        model: "gpt-6-luna",
        title: "One change",
        brief: @brief,
        repository: ctx.repo
      })

    run =
      Repo.insert!(%Shoestring.Harness.RunRecord{
        id: Ecto.UUID.generate(),
        dispatch_id: Ecto.UUID.generate(),
        goal_id: dispatch.goal_id,
        provider_id: Fake.identity().adapter_id,
        workspace_ref: "fixture",
        request_version: 1,
        prompt: "fixture",
        policy: %{},
        requested_capabilities: %{},
        extensions: %{},
        status: "failed"
      })

    {:ok, event} =
      Trajectory.append(
        dispatch.goal_id,
        %{
          "type" => "run.failed",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => DateTime.add(DateTime.utc_now(), 900),
          "payload" => %{
            "run_id" => run.id,
            "error_category" => "transport",
            "error_code" => "supervisor_crash"
          }
        },
        trusted: [run_id: run.id]
      )

    assert Shoestring.CLI.Follow.line(event) =~ "exact stop time is unknown"

    for cache <- [%{}] do
      {[row], _} =
        ShoestringWeb.ChatDispatches.rows(
          ctx.session,
          cache,
          DateTime.add(DateTime.utc_now(), 1800)
        )

      assert row["elapsed_seconds"] == nil
      assert row["latest_step"] =~ "service stop or crash"
    end

    assert Enum.any?(
             ShoestringWeb.ChatDispatches.detail(dispatch)["lines"],
             &String.contains?(&1, "exact running time is unknown")
           )
  end

  defp grant(session, repo) do
    Grants.create(
      %{
        session_id: session,
        repository_root: repo,
        models: ["codex:gpt-6-luna"],
        purposes: Grants.purposes(),
        max_dispatches: 4,
        max_parallel: 2,
        max_total_seconds: 4 * 3600,
        max_dispatch_seconds: 3600,
        unread_usage: 0,
        max_turns: 10
      },
      "human:operator"
    )
  end

  defp open(session, repo) do
    Conversations.open(%{
      session_id: session,
      provider: "claude",
      model: "claude-test-model",
      effort: nil,
      repository_root: repo
    })
  end

  defp info(overrides \\ %{}) do
    Map.merge(
      %{
        peer_data: %{address: {127, 0, 0, 1}},
        uri: URI.parse("http://localhost:4002/chat/socket")
      },
      overrides
    )
  end

  defp join!(ctx, params \\ %{}) do
    {:ok, _reply, socket} =
      subscribe_and_join(ctx.socket, ChatChannel, "conversation:#{ctx.session}", params)

    socket
  end

  # Pushed events until one of `type` arrives, in order.
  defp events_until(type, seen \\ []) do
    assert_push "events", %{"events" => events}, 5_000
    seen = seen ++ events

    if Enum.any?(events, &(&1["type"] == type)), do: seen, else: events_until(type, seen)
  end

  defp say(socket, text, id \\ Ecto.UUID.generate()),
    do: push(socket, "say", %{"message_id" => id, "text" => text})

  test "a socket needs loopback, a local host and its conversation's token", ctx do
    params = %{"session" => ctx.session, "token" => ctx.token}

    assert {:ok, socket} = connect(ChatSocket, params, connect_info: info())
    assert socket.assigns.session_id == ctx.session

    assert :error =
             connect(ChatSocket, params,
               connect_info: info(%{peer_data: %{address: {192, 0, 2, 1}}})
             )

    assert :error =
             connect(ChatSocket, params,
               connect_info: info(%{uri: URI.parse("http://rebound.example/chat/socket")})
             )

    assert :error = connect(ChatSocket, %{params | "token" => "x"}, connect_info: info())
    assert :error = connect(ChatSocket, %{"token" => ctx.token}, connect_info: info())

    # Another session's token opens nothing here.
    {:ok, other} = ChatToken.ensure("chat-other-#{System.unique_integer([:positive])}")
    assert :error = connect(ChatSocket, %{params | "token" => other}, connect_info: info())
  end

  test "a socket joins only its own session's conversation", ctx do
    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(ctx.socket, ChatChannel, "conversation:someone-else", %{})

    assert {:error, %{reason: "invalid_after"}} =
             subscribe_and_join(ctx.socket, ChatChannel, "conversation:#{ctx.session}", %{
               "after" => -1
             })

    lonely = socket(ChatSocket, nil, %{session_id: "chat-none"})

    assert {:error, %{reason: "no_conversation"}} =
             subscribe_and_join(lonely, ChatChannel, "conversation:chat-none", %{})
  end

  test "joining pushes the stored events, then live ones, then resumes after `after` with no repeats",
       ctx do
    socket = join!(ctx)

    assert [%{"type" => "conversation.opened", "sequence" => 1}] =
             events_until("conversation.opened")

    assert_push "state", %{"engine" => %{"state" => "idle"}, "grant" => %{"turns" => _}}

    ref = say(socket, "SAY hello")
    assert_reply ref, :ok

    seen = events_until("conversation.turn.ended")
    sequences = Enum.map(seen, & &1["sequence"])
    assert sequences == Enum.sort(Enum.uniq(sequences))
    assert Enum.any?(seen, &(&1["payload"]["text"] == "hello"))
    last = List.last(sequences)

    Process.unlink(socket.channel_pid)
    :ok = close(socket)

    # More happens with no client attached.
    Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(ctx.conversation.id))
    :ok = Engine.say(Engine.via(ctx.conversation.id), Ecto.UUID.generate(), "SAY again")
    assert_receive {:trajectory_event_committed, %{type: "conversation.turn.ended"}}, 5_000
    {:ok, events} = Trajectory.replay(ctx.conversation.id)
    assert Enum.any?(events, &(&1.type == "conversation.turn.ended" and &1.sequence > last))

    join!(ctx, %{"after" => last})
    resumed = events_until("conversation.turn.ended")
    assert hd(resumed)["sequence"] == last + 1

    assert Enum.map(resumed, & &1["sequence"]) ==
             Enum.map(Enum.filter(events, &(&1.sequence > last)), & &1.sequence)
  end

  test "say and cancel_turn reach the engine and refuse what it refuses", ctx do
    socket = join!(ctx)
    events_until("conversation.opened")

    ref = say(socket, "SLOW 60000 never")
    assert_reply ref, :ok
    events_until("conversation.turn.requested")

    ref = push(socket, "cancel_turn", %{})
    assert_reply ref, :ok

    assert Enum.any?(
             events_until("conversation.turn.ended"),
             &(&1["payload"]["status"] == "interrupted")
           )

    ref = push(socket, "cancel_turn", %{})
    assert_reply ref, :error, %{"reason" => "no_turn"}

    ref = say(socket, String.duplicate("x", Engine.max_message_bytes() + 1))
    assert_reply ref, :error, %{"reason" => "message_too_large"}

    ref = say(socket, "SAY hi", "not-a-uuid")
    assert_reply ref, :error, %{"reason" => "invalid_message"}

    ref = push(socket, "delete_everything", %{})
    assert_reply ref, :error, %{"reason" => "invalid_request"}
  end

  test "cancel_dispatch cancels only this session's dispatch, as the person's request", ctx do
    socket = join!(ctx)
    binding = %{session_id: ctx.session, repository: ctx.repo}

    {:ok, %{"dispatch_id" => id}} =
      Tools.call(
        "dispatch",
        %{
          "purpose" => "implement",
          "worker" => "codex:gpt-6-luna",
          "title" => "Make add return the sum",
          "brief" => @brief,
          "files" => ["calc.py"]
        },
        binding
      )

    ref = push(socket, "watch_dispatch", %{"dispatch_id" => id})

    assert_reply ref, :ok, %{
      "dispatch_id" => ^id,
      "lines" => lines,
      "steps" => steps,
      "terminal" => nil
    }

    assert Enum.any?(lines, &String.contains?(&1, "codex:gpt-6-luna"))
    assert is_list(steps["entries"])
    send(socket.channel_pid, :state)

    assert_push "state", %{
      "dispatches" => [
        %{"dispatch_id" => ^id, "reviewer" => nil, "elapsed_seconds" => elapsed, "run_id" => nil}
      ]
    }

    assert elapsed >= 0

    ref = push(socket, "cancel_dispatch", %{"dispatch_id" => id, "reason" => " "})
    assert_reply ref, :error, %{"reason" => "invalid_reason"}

    ref =
      push(socket, "cancel_dispatch", %{"dispatch_id" => Ecto.UUID.generate(), "reason" => "x"})

    assert_reply ref, :error, %{"reason" => "dispatch_not_found"}

    ref = push(socket, "cancel_dispatch", %{"dispatch_id" => id, "reason" => "not needed"})
    assert_reply ref, :ok

    dispatch = Shoestring.Dispatches.get(id)
    assert Shoestring.Dispatches.state(dispatch) == "cancelled"
    send(socket.channel_pid, :state)
    assert_push "dispatch", %{"dispatch_id" => ^id, "lines" => changed}
    assert "state: cancelled" in changed
    ref = push(socket, "unwatch_dispatch", %{})
    assert_reply ref, :ok
    _ = :sys.get_state(socket.channel_pid)
    assert :sys.get_state(socket.channel_pid).assigns.watched == nil
    {:ok, events} = Trajectory.replay(dispatch.goal_id)
    # The cancellation itself names the person, not the grant.
    assert [%{payload: %{"requested_by" => by}}] =
             Enum.filter(events, &Map.has_key?(&1.payload, "cancellation_id"))
             |> Enum.uniq_by(& &1.payload["cancellation_id"])
             |> Enum.take(1)

    assert by == Shoestring.CLI.WorkLoop.default_human()

    # Another session's socket cannot reach it.
    {:ok, _} = grant("chat-two", ctx.repo)
    {:ok, two} = open("chat-two", ctx.repo)

    start_supervised!(
      Supervisor.child_spec({Engine, {two, @engine_opts}}, restart: :temporary, id: :two)
    )

    {:ok, _, other} =
      subscribe_and_join(
        socket(ChatSocket, nil, %{session_id: "chat-two"}),
        ChatChannel,
        "conversation:chat-two",
        %{}
      )

    ref = push(other, "watch_dispatch", %{"dispatch_id" => id})
    assert_reply ref, :error, %{"reason" => "dispatch_not_found"}

    ref = push(other, "cancel_dispatch", %{"dispatch_id" => id, "reason" => "mine now"})
    assert_reply ref, :error, %{"reason" => "dispatch_not_found"}
  end

  test "the person starts a held dispatch from chat; no pre-approval is spent", ctx do
    {:ok, _, socket} =
      subscribe_and_join(ctx.socket, ChatChannel, "conversation:#{ctx.session}", %{})

    {:ok, %{"dispatch_id" => id}} =
      Tools.call(
        "dispatch",
        %{
          "purpose" => "explore",
          "worker" => "codex:gpt-6-luna",
          "title" => "Where is add",
          "brief" => "EXPLORE - where is add?\nContract: a report.\n"
        },
        %{session_id: ctx.session, repository: ctx.repo}
      )

    # No usage reading: the call is held for a confirmation.
    assert {:snooze, 30} = Shoestring.Dispatches.Calls.step(id)
    assert Shoestring.Dispatches.state(Shoestring.Dispatches.get(id)) == "held"

    ref = push(socket, "confirm_dispatch", %{"dispatch_id" => id})
    assert_reply ref, :ok, %{}, 5_000

    call = Shoestring.Dispatches.Calls.get(id)
    assert call.confirmed_by == Shoestring.CLI.WorkLoop.default_human()
    assert Shoestring.Dispatches.state(Shoestring.Dispatches.get(id)) == "queued"
    assert Grants.get(ctx.grant.id).unread_usage_used == 0

    ref = push(socket, "confirm_dispatch", %{"dispatch_id" => id})
    assert_reply ref, :error, %{"reason" => "not_held"}, 5_000

    ref = push(socket, "confirm_dispatch", %{"dispatch_id" => Ecto.UUID.generate()})
    assert_reply ref, :error, %{"reason" => "dispatch_not_found"}, 5_000
  end

  test "the state lists lessons approved since the grant; the person retires one from chat",
       ctx do
    {:ok, _, socket} =
      subscribe_and_join(ctx.socket, ChatChannel, "conversation:#{ctx.session}", %{})

    assert_push "state", %{"lessons" => [], "web_url" => "http" <> _}, 5_000
    binding = %{session_id: ctx.session, repository: ctx.repo}

    {:ok, %{"dispatch_id" => dispatch}} =
      Tools.call(
        "dispatch",
        %{
          "purpose" => "implement",
          "worker" => "codex:gpt-6-luna",
          "title" => "Sum",
          "brief" => @brief
        },
        binding
      )

    {:ok, %{"code" => old}} =
      Tools.call(
        "lessons_propose",
        %{"text" => "An older rule.", "dispatch" => dispatch},
        binding
      )

    # Approved before this session's grant: not news here.
    earlier = DateTime.add(ctx.grant.inserted_at, -60)

    Repo.update_all(from(l in Shoestring.Lessons.Lesson, where: l.code == ^old),
      set: [decided_at: earlier]
    )

    {:ok, %{"code" => code}} =
      Tools.call(
        "lessons_propose",
        %{"text" => "Run unittest with -B.", "dispatch" => dispatch},
        binding
      )

    send(socket.channel_pid, :state)

    assert_push "state",
                %{
                  "lessons" => [
                    %{
                      "code" => ^code,
                      "text" => "Run unittest with -B.",
                      "proposed_by" => "the coordinator",
                      "approved_by" => "the coordinator, its proposer"
                    }
                  ]
                },
                5_000

    ref = push(socket, "retire_lesson", %{"code" => code})
    assert_reply ref, :ok, %{}, 5_000
    assert %{state: "retired", retired_by: "human:" <> _} = Shoestring.Lessons.get(code)

    ref = push(socket, "retire_lesson", %{"code" => code})
    assert_reply ref, :error, %{"reason" => "lesson_not_approved"}, 5_000
    ref = push(socket, "retire_lesson", %{"code" => "L-NONE22"})
    assert_reply ref, :error, %{"reason" => "lesson_not_found"}, 5_000
  end

  test "a worker's ask is in the state; the person answers it from chat, for this session only",
       ctx do
    {:ok, _, socket} =
      subscribe_and_join(ctx.socket, ChatChannel, "conversation:#{ctx.session}", %{})

    assert_push "state", %{"asks" => []}, 5_000

    # The test process stands in for the worker session waiting on the asks.
    insert = fn session ->
      ask =
        Repo.insert!(%Shoestring.PermissionAsks.Ask{
          goal_id: Ecto.UUID.generate(),
          run_id: "run-1",
          session_id: session,
          agent: "builder",
          provider: "codex",
          command: "curl https://example.invalid",
          reason: "Fetch notes"
        })

      {:ok, _} = Registry.register(Shoestring.PermissionAsks.registry(), ask.id, nil)
      ask
    end

    mine = insert.(ctx.session)
    other = insert.("someone-else")

    assert_push "state",
                %{"asks" => [%{"ask_id" => id, "command" => "curl https://example.invalid"}]},
                5_000

    assert id == mine.id

    ref = push(socket, "decide_ask", %{"ask_id" => other.id, "decision" => "allow"})
    assert_reply ref, :error, %{"reason" => "ask_not_found"}, 5_000
    assert Repo.get(Shoestring.PermissionAsks.Ask, other.id).state == "pending"

    ref =
      push(socket, "decide_ask", %{
        "ask_id" => mine.id,
        "decision" => "deny",
        "note" => "Use the cache."
      })

    assert_reply ref, :ok, %{}, 5_000
    assert_receive {:permission_decision, ^id, :deny, "Use the cache."}

    assert %{state: "denied", decided_by: "human:" <> _} =
             Repo.get(Shoestring.PermissionAsks.Ask, mine.id)

    ref = push(socket, "decide_ask", %{"ask_id" => mine.id, "decision" => "allow"})
    assert_reply ref, :error, %{"reason" => "not_pending"}, 5_000
    assert_push "state", %{"asks" => []}, 5_000
  end

  test "allow for this agent is offered for one plain command and adds its rule", ctx do
    {:ok, _, socket} =
      subscribe_and_join(ctx.socket, ChatChannel, "conversation:#{ctx.session}", %{})

    assert_push "state", %{"asks" => []}, 5_000

    insert = fn agent, rule_key ->
      ask =
        Repo.insert!(%Shoestring.PermissionAsks.Ask{
          goal_id: Ecto.UUID.generate(),
          run_id: "run-1",
          session_id: ctx.session,
          agent: agent,
          provider: "codex",
          command: rule_key || "Change files under /data",
          rule_key: rule_key
        })

      {:ok, _} = Registry.register(Shoestring.PermissionAsks.registry(), ask.id, nil)
      ask
    end

    {:ok, _} =
      Shoestring.Agents.create(%{
        "name" => "Builder",
        "slug" => "builder",
        "kind" => "implementer",
        "provider" => "codex",
        "model" => "gpt-6-luna"
      })

    plain = insert.("builder", "/bin/zsh -lc 'npm test'")
    assert_push "state", %{"asks" => [%{"for_agent" => true}]}, 5_000
    change = insert.("builder", nil)
    gone = insert.("no-such-agent", "/bin/zsh -lc 'npm test'")

    assert_push "state",
                %{"asks" => [%{"for_agent" => true}, %{"for_agent" => false}, _]},
                5_000

    ref = push(socket, "decide_ask", %{"ask_id" => change.id, "decision" => "allow_agent"})
    assert_reply ref, :error, %{"reason" => "not_ruleable"}, 5_000
    ref = push(socket, "decide_ask", %{"ask_id" => gone.id, "decision" => "allow_agent"})
    assert_reply ref, :error, %{"reason" => "agent_gone"}, 5_000

    ref = push(socket, "decide_ask", %{"ask_id" => plain.id, "decision" => "allow_agent"})
    assert_reply ref, :ok, %{}, 5_000
    id = plain.id
    assert_receive {:permission_decision, ^id, :allow, nil}

    assert Shoestring.Agents.get_by_slug("builder").allowed_commands == [
             "/bin/zsh -lc 'npm test'"
           ]
  end

  test "a finished report reads as text in the detail, not as one line of JSON", ctx do
    {:ok, %{"dispatch_id" => id}} =
      Tools.call(
        "dispatch",
        %{
          "purpose" => "explore",
          "worker" => "codex:gpt-6-luna",
          "title" => "Parity audit",
          "brief" => "EXPLORE - compare the two apps\nContract: a report.\n"
        },
        %{session_id: ctx.session, repository: ctx.repo}
      )

    finish = fn report ->
      {1, _} =
        Repo.update_all(
          from(c in Shoestring.Dispatches.Call, where: c.dispatch_id == ^id),
          set: [state: "completed", report_json: Jason.encode!(report), output_tokens: 900]
        )

      ShoestringWeb.ChatDispatches.detail(Shoestring.Dispatches.get(id))["lines"]
    end

    lines =
      finish.(%{
        "summary" => "Settings differ.",
        "findings" => [
          %{
            "claim" => "Nutrition targets exist only on iOS",
            "supported" => true,
            "evidence" => [
              %{"path" => "ios/Cantino/SettingsView.swift", "line" => 151, "supported" => true},
              %{"path" => "mobile/lib/gone.dart", "line" => 9, "supported" => false}
            ]
          }
        ],
        "open_questions" => ["Is the Android scan retry intended?"],
        "supported_findings" => 1
      })

    assert "report:" in lines
    assert "  Summary: Settings differ." in lines
    assert "  Findings (1, 1 supported):" in lines
    assert "    • Nutrition targets exist only on iOS" in lines
    assert "      ios/Cantino/SettingsView.swift:151, mobile/lib/gone.dart:9 ✗" in lines
    assert "    ? Is the Android scan retry intended?" in lines
    refute Enum.any?(lines, &String.contains?(&1, ~s("evidence")))

    lines =
      finish.(%{
        "verdict" => "request_changes",
        "summary" => "One blocker.",
        "outcome" => "changes_requested",
        "blocking_count" => 1,
        "findings" => [
          %{
            "id" => "F1",
            "severity" => "blocking",
            "path" => "calc.py",
            "line" => 2,
            "claim" => "add still raises",
            "correction" => "return a + b",
            "reference" => "supported"
          }
        ]
      })

    assert "report: changes_requested (1 blocking)" in lines
    assert "    F1 [blocking] calc.py:2 add still raises" in lines
    assert "      fix: return a + b" in lines
    refute Enum.any?(lines, &String.contains?(&1, ~s("severity")))
  end

  test "dispatch logs keep the latest 500 lines, count omissions and freeze final rows", ctx do
    {:ok, %{"dispatch_id" => id}} =
      Tools.call(
        "dispatch",
        %{
          "purpose" => "implement",
          "worker" => "codex:gpt-6-luna",
          "title" => "Make add return the sum",
          "brief" => @brief,
          "files" => ["calc.py"]
        },
        %{session_id: ctx.session, repository: ctx.repo}
      )

    dispatch = Shoestring.Dispatches.get(id)
    {:ok, before} = Trajectory.replay(dispatch.goal_id)
    start = List.last(before).sequence
    now = DateTime.utc_now()
    # Canonical progress envelopes, no harness/provider is started.
    for n <- 1..510 do
      Repo.insert!(%Trajectory.TrajectoryEvent{
        goal_id: dispatch.goal_id,
        sequence: start + n,
        type: "cobbler.plan.gate.started",
        actor: "system",
        occurred_at: now,
        schema_version: 1,
        payload: %{"gate" => "check-#{n}"}
      })
    end

    steps = ShoestringWeb.ChatDispatches.steps(dispatch, start)
    assert length(steps["entries"]) == 500
    assert steps["omitted"] == 10
    assert hd(steps["entries"])["sequence"] == start + 11
    assert List.last(steps["entries"])["line"] =~ "check-510"
    assert steps["last_sequence"] == start + 510
    assert ShoestringWeb.ChatDispatches.steps(dispatch, start + 510)["entries"] == []

    {:ok, _} =
      Shoestring.Dispatches.cancel(dispatch, "not needed", requested_by: "human:operator")

    {rows, cache} = ShoestringWeb.ChatDispatches.rows(ctx.session, %{}, now)
    {same, _} = ShoestringWeb.ChatDispatches.rows(ctx.session, cache, DateTime.add(now, 60))
    assert rows == same
    {fresh, _} = ShoestringWeb.ChatDispatches.rows(ctx.session, %{}, DateTime.add(now, 60))
    assert fresh == rows
    assert hd(rows)["state"] == "cancelled"
  end

  test "a cancel names a person or the grant, nothing else", ctx do
    {:ok, %{"dispatch_id" => id}} =
      Tools.call(
        "dispatch",
        %{
          "purpose" => "implement",
          "worker" => "codex:gpt-6-luna",
          "title" => "Make add return the sum",
          "brief" => @brief,
          "files" => ["calc.py"]
        },
        %{session_id: ctx.session, repository: ctx.repo}
      )

    dispatch = Shoestring.Dispatches.get(id)

    assert {:error, :non_human_identity} =
             Shoestring.Dispatches.cancel(dispatch, "x", requested_by: "grant:" <> ctx.grant.id)

    assert Shoestring.Dispatches.state(dispatch) == "queued"
  end

  test "an event committed before the backlog is read is left to the backlog", ctx do
    socket = %Phoenix.Socket{
      assigns: %{conversation: ctx.conversation, last: 0, ready: false, snapshot: nil},
      transport_pid: self()
    }

    event = %Trajectory.TrajectoryEvent{sequence: 7, type: "conversation.message.human"}

    assert {:noreply, ^socket} =
             ChatChannel.handle_info({:trajectory_event_committed, event}, socket)

    refute_received %Phoenix.Socket.Message{}

    # Once the backlog is out, an event at or before the last pushed is not repeated.
    ready = %{socket | assigns: %{socket.assigns | ready: true, last: 7}}

    assert {:noreply, ^ready} =
             ChatChannel.handle_info({:trajectory_event_committed, event}, ready)
  end

  test "a client that stops reading is detached instead of queued without bound", ctx do
    socket = join!(ctx)
    events_until("conversation.opened")
    ref = Process.monitor(socket.channel_pid)
    Process.unlink(socket.channel_pid)

    # The test process is this channel's transport: fill its queue.
    for _ <- 1..1_001, do: send(self(), :unread)
    _ = say(socket, "SAY hello")

    assert_push "detached", %{"reason" => "slow_consumer"}, 5_000
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
  end

  test "a handoff moves the joined client to the successor; a client naming the old one rejoins from the start",
       ctx do
    Application.put_env(:shoestring, :conversation_engine_opts, @engine_opts)
    on_exit(fn -> Application.delete_env(:shoestring, :conversation_engine_opts) end)

    socket = join!(ctx)
    events_until("conversation.opened")
    ref = say(socket, "SAY before")
    assert_reply ref, :ok
    last = List.last(events_until("conversation.turn.ended"))["sequence"]

    ref = push(socket, "handoff", %{"note" => "yes"})
    assert_reply ref, :error, %{"reason" => "invalid_request"}
    ref = push(socket, "handoff", %{"note" => false})
    assert_reply ref, :ok

    # The old conversation's last events, then the successor's from its first.
    seen = events_until("conversation.handoff.received")

    assert Enum.map(seen, &{&1["type"], &1["sequence"]}) == [
             {"conversation.handoff.requested", last + 1},
             {"conversation.handoff.prepared", last + 2},
             {"conversation.handed_off", last + 3},
             {"conversation.opened", 1},
             {"conversation.handoff.received", 2}
           ]

    successor = Conversations.get(ctx.session)
    assert successor.predecessor_id == ctx.conversation.id
    # Cleanup for a failure before the end. The engine can already be gone:
    # its own stop below, or one a joined channel started again exiting with
    # the test (1 of 7 gate runs: GenServer.stop found no process).
    on_exit(fn ->
      if pid = Conversations.engine(successor) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _gone -> :ok
        end
      end
    end)

    # The person's next message reaches the successor, with the handoff.
    ref = say(socket, "SAY after")
    assert_reply ref, :ok
    seen = events_until("conversation.turn.ended")
    predecessor_id = ctx.conversation.id

    assert [%{"payload" => %{"message_ids" => [^predecessor_id, _after]}}] =
             Enum.filter(seen, &(&1["type"] == "conversation.turn.requested"))

    Process.unlink(socket.channel_pid)
    :ok = close(socket)

    {:ok, reply, rejoined} =
      subscribe_and_join(ctx.socket, ChatChannel, "conversation:#{ctx.session}", %{
        "after" => last + 3,
        "conversation_id" => ctx.conversation.id
      })

    assert reply["conversation_id"] == successor.id

    assert [%{"type" => "conversation.opened", "sequence" => 1} | _] =
             events_until("conversation.opened")

    # Leave first: a joined channel starts its conversation's engine again
    # when it finds none running.
    Process.unlink(rejoined.channel_pid)
    :ok = close(rejoined)
    engine = Conversations.engine(successor)
    ref = Process.monitor(engine)
    GenServer.stop(engine)
    assert_receive {:DOWN, ^ref, :process, ^engine, :normal}, 5_000
  end

  test "at boot, engines start for conversations whose session has a grant", ctx do
    {:ok, _} = open("chat-ungranted", ctx.repo)
    {:ok, granted} = open("chat-granted", ctx.repo)
    {:ok, _} = grant("chat-granted", ctx.repo)

    started = Resume.run(@engine_opts)
    # The setup's engine is among them, and ExUnit may have stopped it first.
    on_exit(fn ->
      for c <- started, pid = Conversations.engine(c) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _gone -> :ok
        end
      end
    end)

    sessions = Enum.map(started, & &1.session_id)
    assert "chat-granted" in sessions
    assert ctx.session in sessions
    refute "chat-ungranted" in sessions
    assert is_pid(Conversations.engine(granted))
    assert Repo.aggregate(Shoestring.Conversations.Conversation, :count) == 3
  end
end
