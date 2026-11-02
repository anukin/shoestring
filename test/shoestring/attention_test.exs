defmodule Shoestring.AttentionTest do
  @moduledoc """
  What needs the person: asks and held dispatches as items with the chat
  screen's words and choices, answering an ask once (the first answer wins),
  starting a hold, the nav's count and its broadcast. The test process
  stands in for the worker session waiting on each ask.
  """
  use Shoestring.DataCase, async: false

  import Shoestring.SessionsFixtures

  alias Shoestring.{Agents, Attention, Grants, PermissionAsks, Repo}
  alias Shoestring.CLI.WorkLoop
  alias Shoestring.PermissionAsks.Ask

  @by "human:operator"

  setup do
    ctx = session()

    Map.put(
      ctx,
      :builder,
      dispatch_fixture(ctx, "implement", "builder", "Make add return the sum")
    )
  end

  defp builder_agent do
    {:ok, _} =
      Agents.create(%{
        "name" => "Builder",
        "slug" => "builder",
        "kind" => "implementer",
        "provider" => "codex",
        "model" => "gpt-6-luna"
      })
  end

  describe "items" do
    test "a plain command offers allow for this agent; a file change and a network ask do not",
         ctx do
      command = waiting_ask(ctx.builder)

      change =
        waiting_ask(ctx.builder, %{kind: "file_change", command: "Edit /etc/hosts", rule_key: nil})

      # Even with a rule key, a network ask is never a command rule.
      network =
        waiting_ask(ctx.builder, %{
          kind: "network",
          provider: "claude",
          command: "registry.npmjs.org",
          rule_key: "registry.npmjs.org"
        })

      items = Map.new(Attention.items(ctx.session), &{&1.ask.id, &1})

      assert Enum.map(items[command.id].choices, &elem(&1, 0)) ==
               ~w(allow allow_agent deny deny_reason)

      assert items[command.id].title == "A worker asks to run a command outside its sandbox"
      assert items[command.id].subject == "$ npm ci"
      assert items[command.id].note =~ "its network stays as the agent's settings allow."
      assert items[command.id].note =~ "nothing decides this on a timer"

      assert Enum.map(items[change.id].choices, &elem(&1, 0)) == ~w(allow deny deny_reason)

      assert items[network.id].choices == [{"allow", "Allow for this run"}, {"deny", "Deny"}]
      assert items[network.id].title == "A worker asks to reach a host not on its list"
      assert items[network.id].note =~ "for the rest of this run"
    end

    test "an ask leaves the list once answered, and one nobody waits on is not listed", ctx do
      ask = waiting_ask(ctx.builder)

      # No worker session waits on this one: it can't be answered, so it isn't listed.
      Repo.insert!(%Ask{
        goal_id: ctx.builder.goal_id,
        run_id: "run-2",
        session_id: ctx.session,
        dispatch_id: ctx.builder.id,
        agent: "builder",
        provider: "codex",
        command: "make"
      })

      assert [%{kind: :ask, id: id}] = Attention.items(ctx.session)
      assert id == "ask-" <> ask.id

      assert {:ok, _} = Attention.answer(ctx.session, ask.id, "allow", @by)
      assert Attention.items(ctx.session) == []
    end

    test "a held dispatch is an item until the person starts it", ctx do
      held = held_fixture(ctx)

      assert [%{kind: :held, dispatch_id: id, title: "Start this held dispatch?"} = item] =
               Attention.items(ctx.session)

      assert id == held.id
      assert item.choices == [{"start", "Start it"}]
      assert item.note =~ "none of the grant's pre-approvals is spent"

      assert Attention.start_held(ctx.session, held.id, @by) == :confirmed
      assert Shoestring.Dispatches.Calls.get(held.id).confirmed_by == @by
      assert Grants.get(ctx.grant.id).unread_usage_used == 0
      assert Attention.items(ctx.session) == []

      assert Attention.start_held(ctx.session, held.id, @by) == :none
      assert Attention.start_held("someone-else", held.id, @by) == {:error, :dispatch_not_found}
    end
  end

  describe "answer" do
    test "the first answer wins: a second is refused and the worker hears only one", ctx do
      ask = waiting_ask(ctx.builder)
      id = ask.id

      assert {:ok, %Ask{state: "denied", note: "Use the cache."}} =
               Attention.answer(ctx.session, id, "deny", @by, "  Use the cache.  ")

      assert_receive {:permission_decision, ^id, :deny, "Use the cache."}

      assert Attention.answer(ctx.session, id, "allow", @by) == {:error, :not_pending}
      assert Attention.answer(ctx.session, id, "allow_agent", @by) == {:error, :not_pending}
      refute_receive {:permission_decision, ^id, _, _}, 100
      assert Repo.get(Ask, id).state == "denied"
    end

    test "an ask of another session, a blank reason, and a non-human answer", ctx do
      ask = waiting_ask(ctx.builder)
      id = ask.id

      assert Attention.answer("someone-else", id, "allow", @by) == {:error, :ask_not_found}
      assert Attention.answer(ctx.session, "no-such", "allow", @by) == {:error, :ask_not_found}

      assert Attention.answer(ctx.session, id, "allow", "grant:x") ==
               {:error, :non_human_identity}

      assert Repo.get(Ask, id).state == "pending"

      assert {:ok, %Ask{note: nil}} = Attention.answer(ctx.session, id, "deny", @by, "   ")
      assert_receive {:permission_decision, ^id, :deny, nil}
    end

    test "allow for this agent writes the rule; on a network ask it is refused and adds none",
         ctx do
      builder_agent()
      plain = waiting_ask(ctx.builder)

      network =
        waiting_ask(ctx.builder, %{kind: "network", command: "example.test", rule_key: "npm ci"})

      assert Attention.answer(ctx.session, network.id, "allow_agent", @by) ==
               {:error, :not_ruleable}

      assert Repo.get(Ask, network.id).state == "pending"
      assert Agents.get_by_slug("builder").allowed_commands == []

      assert {:ok, %Ask{state: "allowed"}} =
               Attention.answer(ctx.session, plain.id, "allow_agent", @by)

      plain_id = plain.id
      assert_receive {:permission_decision, ^plain_id, :allow, nil}
      assert Agents.get_by_slug("builder").allowed_commands == ["npm ci"]
    end

    test "the chat screen answers through the same function", ctx do
      # Its identity is the one the chat channel uses.
      ask = waiting_ask(ctx.builder)

      assert {:ok, %Ask{decided_by: by}} =
               Attention.answer(ctx.session, ask.id, "allow", WorkLoop.default_human())

      assert by == WorkLoop.default_human()
    end
  end

  describe "stopped dispatches" do
    # A dispatch whose execution waits for the person; its status is fixed
    # here, as `Shoestring.Dispatches.state/2`'s own tests fix it.
    defp stopped(ctx, status) do
      Attention.items(ctx.session, %{ctx.builder.id => "needs_you"},
        status: fn _goal -> {:ok, status} end
      )
    end

    test "a stopped merge says where it conflicts and that Shoestring never resolves it", ctx do
      execution_id = Ecto.UUID.generate()
      commits = [String.duplicate("1", 40), String.duplicate("2", 40)]

      status = %{
        execution: %{execution_id: execution_id},
        integration: nil,
        accepted_evidence: Enum.map(commits, &%{commit: &1}),
        reviews: []
      }

      {:ok, _} =
        Shoestring.Trajectory.append(ctx.builder.goal_id, %{
          "type" => "cobbler.plan.merge.blocked",
          "schema_version" => 1,
          "actor" => "cobbler",
          "occurred_at" => DateTime.utc_now(),
          "idempotency_key" =>
            "plan-merge-blocked:#{execution_id}:" <>
              Base.encode16(:crypto.hash(:sha256, Enum.join(commits, ",")), case: :lower),
          "payload" => %{
            "execution_id" => execution_id,
            "revision_number" => 1,
            "plan_digest" => String.duplicate("a", 64),
            "accepted_commits" => commits,
            "reason" => "conflict",
            "plan_task_id" => "dispatch-2",
            "files" => ["calc.py"],
            "merged_task_ids" => ["dispatch-1"]
          }
        })

      assert [%{kind: :stopped, reason: :merge} = item] = stopped(ctx, status)
      assert item.id == "stopped-" <> ctx.builder.id
      assert item.title == "Shoestring's merge stopped"
      assert item.note =~ "merging dispatch-2 conflicts in calc.py"
      assert item.note =~ "Shoestring never resolves a conflict"
      assert item.choices == []
    end

    test "a blocked review lists its blocking findings and the commands that decide it", ctx do
      goal = ctx.builder.goal_id

      review = %{
        needs_user?: true,
        state: "escalated",
        plan_task_id: "dispatch-1",
        reason: nil,
        unavailable: nil,
        findings: [
          %{
            "id" => "F1",
            "severity" => "blocking",
            "reference" => "supported",
            "path" => "calc.py",
            "line" => 2,
            "claim" => "add() still raises"
          },
          %{"id" => "F2", "severity" => "minor", "reference" => "supported", "claim" => "naming"}
        ]
      }

      assert [%{reason: :review} = item] = stopped(ctx, %{reviews: [review]})
      assert item.title == "A review needs your decision"
      assert item.note =~ "still asks for changes after the last repair round"
      assert item.lines == ["F1 calc.py:2 add() still raises"]

      assert item.commands == [
               ~s(shoestring review accept #{goal} dispatch-1 --reason "REASON"),
               ~s(shoestring review reject #{goal} dispatch-1 --reason "REASON")
             ]

      # A review that failed may be called once more.
      failed = %{review | state: "failed", reason: "transport", findings: []}
      assert [%{reason: :review} = item] = stopped(ctx, %{reviews: [failed]})
      assert item.note =~ "could not finish (transport)"
      assert List.last(item.commands) =~ "shoestring review retry #{goal} dispatch-1"

      # A review that doesn't wait for the person is not why it stopped.
      settled = %{review | needs_user?: false}
      assert [%{reason: :other}] = stopped(ctx, %{reviews: [settled]})
    end

    test "a worker Shoestring lost says so and how to cancel it", ctx do
      run =
        Repo.insert!(%Shoestring.Harness.RunRecord{
          id: Ecto.UUID.generate(),
          dispatch_id: Ecto.UUID.generate(),
          goal_id: ctx.builder.goal_id,
          provider_id: Shoestring.Harness.Fake.identity().adapter_id,
          workspace_ref: "fixture",
          request_version: 1,
          prompt: "fixture",
          policy: %{},
          requested_capabilities: %{},
          extensions: %{},
          status: "failed"
        })

      # Failed some other way: not lost.
      assert [%{reason: :other, run_id: run_id}] = stopped(ctx, %{})
      assert run_id == run.id

      {:ok, _} =
        Shoestring.Trajectory.append(ctx.builder.goal_id, %{
          "type" => "run.failed",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => DateTime.utc_now(),
          "payload" => %{
            "run_id" => run.id,
            "error_category" => "transport",
            "error_code" => "supervisor_crash"
          }
        })

      assert [%{reason: :lost} = item] = stopped(ctx, %{})
      assert item.title == "Shoestring lost this worker"
      assert item.note =~ "during a service stop or crash"
      assert item.commands == [~s(shoestring runs cancel #{ctx.builder.id} --reason "REASON")]
    end

    test "any other stop gives its last step and how to follow it", ctx do
      assert [%{reason: :other} = item] = stopped(ctx, %{})
      assert item.title == "This dispatch stopped and needs your decision"
      assert item.commands == ["shoestring follow #{ctx.builder.goal_id}"]
      assert [_last_step] = item.lines
    end

    test "only a dispatch waiting for the person is listed", ctx do
      assert Attention.items(ctx.session, %{ctx.builder.id => "running"},
               status: fn _ -> {:ok, %{}} end
             ) ==
               []
    end
  end

  describe "count and broadcast" do
    test "counts every waiting ask and the listed sessions' holds", ctx do
      other = session()
      other_builder = dispatch_fixture(other, "implement", "builder", "Other work")

      assert Attention.count() == 0
      waiting_ask(ctx.builder)
      waiting_ask(other_builder)
      held_fixture(ctx)
      assert Attention.count() == 3
    end

    test "an ask recorded or settled and a hold started tell every screen", ctx do
      Phoenix.PubSub.subscribe(Shoestring.PubSub, Attention.topic())
      session = ctx.session

      {:ok, ask} =
        PermissionAsks.ask(%{
          goal_id: ctx.builder.goal_id,
          run_id: Ecto.UUID.generate(),
          provider: "codex",
          command: "npm ci"
        })

      assert_receive {:attention_changed, ^session}

      {:ok, _} = Attention.answer(ctx.session, ask.id, "deny", @by)
      assert_receive {:attention_changed, ^session}

      held = held_fixture(ctx)
      :confirmed = Attention.start_held(ctx.session, held.id, @by)
      assert_receive {:attention_changed, ^session}
    end
  end
end
