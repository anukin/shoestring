defmodule Shoestring.LessonsTest do
  @moduledoc """
  Lessons (iteration 16 B): agents propose them with a source Shoestring can
  find; the coordinator approves (its own at once, a worker's when it
  decides); the person has the last word; a worker sees one only when a
  dispatch cites it. A real temporary Git repository, Oban in manual testing
  mode, no provider or network.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{
    AgentProfiles,
    Agents,
    Conversations,
    Dispatches,
    Grants,
    Lessons,
    ModelCatalog,
    Repo,
    Trajectory
  }

  alias Shoestring.CLI.Commands.Lessons, as: Command
  alias Shoestring.Coordinator.Tools
  alias Shoestring.Dispatches.{Calls, Explore}
  alias Shoestring.Lessons.Harvest
  alias Shoestring.Test.ExploreStandIn

  import Shoestring.ConfigurationFixtures

  @brief "IMPLEMENT - make add() return the sum\nContract: test/test_calc.py passes.\n"
  @said "Remember: never edit the generated files under priv/gen, regenerate them instead."

  setup do
    repo = new_repo!("one")
    {:ok, facts} = Shoestring.Cobbler.Intake.repository(repo)

    for {provider, model} <- [{"codex", "gpt-6-luna"}, {"claude", "opus"}],
        do: {:ok, _} = ModelCatalog.add(provider, model)

    {:ok, team} =
      AgentProfiles.create(
        agent_attrs(%{
          "roles" => [
            %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
            %{"name" => "Explorer", "provider" => "claude", "model" => "opus"},
            %{"name" => "Worker", "provider" => "codex", "model" => "gpt-6-luna"}
          ]
        })
      )

    {:ok, grant} =
      Grants.create(
        Map.put(grant_attrs("s1", facts.root), :team, Agents.snapshot(team)),
        "human:operator"
      )

    {:ok, other} = Grants.create(grant_attrs("s2", facts.root), "human:operator")

    {:ok, dispatch, :recorded} = Dispatches.create(implement(repo, "d1"))

    # The person's words in session s1's chat.
    {:ok, conversation} =
      Conversations.open(%{
        session_id: "s1",
        provider: "claude",
        model: "opus",
        effort: nil,
        repository_root: facts.root
      })

    message_id = Ecto.UUID.generate()

    {:ok, _} =
      Trajectory.append(conversation.id, %{
        "type" => "conversation.message.human",
        "schema_version" => 1,
        "actor" => "human",
        "idempotency_key" => "message:#{message_id}",
        "payload" => %{"message_id" => message_id, "text" => @said}
      })

    agent = fn kind ->
      Agents.get(Enum.find(team.roles, &(Agents.kind_of(&1.name) == kind)).agent_id)
    end

    %{
      repo: repo,
      root: facts.root,
      grant: grant,
      other: other,
      dispatch: dispatch,
      message_id: message_id,
      explorer: agent.("explorer"),
      implementer: agent.("implementer"),
      coordinator: agent.("coordinator")
    }
  end

  defp new_repo!(name) do
    repo = Path.join(System.tmp_dir!(), "shoestring-lessons-#{name}-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    on_exit(fn -> File.rm_rf!(repo) end)
    repo
  end

  defp grant_attrs(session, root),
    do: %{
      session_id: session,
      repository_root: root,
      models: ["codex:gpt-6-luna", "claude:opus"],
      purposes: ["implement", "explore"],
      max_dispatches: 8,
      max_parallel: 4,
      max_total_seconds: 14_400,
      max_dispatch_seconds: 1_800,
      unread_usage: 2
    }

  defp implement(repo, request_id, overrides \\ %{}),
    do:
      Map.merge(
        %{
          session_id: "s1",
          request_id: request_id,
          purpose: "implement",
          provider: "codex",
          model: "gpt-6-luna",
          title: "Sum #{request_id}",
          brief: @brief,
          repository: repo
        },
        overrides
      )

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  @coordinator %{session_id: "s1", role: "coordinator"}

  defp propose(attrs, proposer \\ @coordinator), do: Lessons.propose(attrs, proposer)

  defp worker(ctx, role \\ "implementer", n \\ 1),
    do: %{
      session_id: "s1",
      role: role,
      dispatch_id: ctx.dispatch.id,
      origin_key: "test:#{role}:#{n}"
    }

  test "a proposal names a source Shoestring can find, in the proposing session", ctx do
    assert {:error, :lesson_source_required} = propose(%{"text" => "Run the tests twice."})

    assert {:error, :lesson_source_not_found} =
             propose(%{"text" => "Run it.", "dispatch" => Ecto.UUID.generate()})

    # Another session's dispatch, or the person's words from another session.
    s2 = %{session_id: "s2", role: "coordinator"}

    assert {:error, :lesson_source_not_found} =
             propose(%{"text" => "Run it.", "dispatch" => ctx.dispatch.id}, s2)

    assert {:error, :lesson_source_not_found} =
             propose(
               %{"text" => "No edits to priv/gen.", "quote" => "never edit the generated"},
               s2
             )

    # Words the person never wrote.
    assert {:error, :lesson_source_not_found} =
             propose(%{"text" => "Edit priv/gen freely.", "quote" => "always edit the generated"})

    assert {:error, {:lesson_quote_too_short, 12}} =
             propose(%{"text" => "Do not edit priv/gen.", "quote" => "never"})

    assert {:error, :lesson_one_source} =
             propose(%{"text" => "x", "dispatch" => ctx.dispatch.id, "quote" => "never edit"})

    assert {:ok, from_dispatch} =
             propose(%{
               "text" => "Run python3 -B -m unittest; the bare runner finds no tests.",
               "dispatch" => ctx.dispatch.id,
               "why" => "The first check found nothing to run."
             })

    assert from_dispatch.code =~ ~r/\AL-[2-9A-HJKMNP-TV-Z]{6}\z/
    assert {from_dispatch.source_kind, from_dispatch.source_ref} == {"dispatch", ctx.dispatch.id}
    assert from_dispatch.proposed_by == "grant:" <> ctx.grant.id

    assert {from_dispatch.proposer_role, from_dispatch.repository_root} ==
             {"coordinator", ctx.root}

    # Quoted with other spacing and case, it is still the person's words.
    assert {:ok, from_person} =
             propose(%{
               "text" => "Never edit files under priv/gen; regenerate them.",
               "quote" => "NEVER edit the  generated files"
             })

    assert {from_person.source_kind, from_person.source_ref} == {"person", ctx.message_id}
  end

  test "the coordinator's own proposal is approved when it passes; one much like an approved one waits",
       ctx do
    source = %{"dispatch" => ctx.dispatch.id}

    assert {:ok, first} =
             propose(
               Map.put(source, "text", "Run the migration check before the full test suite.")
             )

    assert {first.state, first.decided_by} == {"approved", "grant:" <> ctx.grant.id}
    assert Lessons.self_approved?(first)

    # An exact repeat, in other case and spacing, is refused.
    assert {:error, {:lesson_duplicate, code}} =
             propose(
               Map.put(source, "text", "run the  migration check before the full test suite.")
             )

    assert code == first.code

    # Much the same words: it waits for a decision, marked similar.
    {:ok, near} =
      propose(Map.put(source, "text", "Run the migration check before running the test suite."))

    assert {near.state, near.similar_to} == {"proposed", [first.code]}

    # Replacing: the new wording approved, the older lesson retired.
    by = "grant:" <> ctx.grant.id
    assert {:ok, replaced} = Lessons.decide(near.code, "replace", by, replaces: first.code)
    assert replaced.state == "approved"
    older = Lessons.get(first.code)
    assert {older.state, older.decision_note} == {"retired", "Replaced by #{near.code}."}
  end

  test "what is kept is bounded and has secrets removed", ctx do
    source = %{"dispatch" => ctx.dispatch.id}

    assert {:error, {:lesson_too_long, 1024}} =
             propose(Map.put(source, "text", String.duplicate("a", 1025)))

    assert {:error, :lesson_empty} = propose(Map.put(source, "text", "   "))

    assert {:ok, lesson} =
             propose(Map.put(source, "text", "Use api_key=sk-live-abcdef0123456789 for staging."))

    assert lesson.text =~ "[REDACTED]"
    refute lesson.text =~ "abcdef0123456789"
    assert lesson.text =~ "for staging."
  end

  test "each agent may propose as its switch says; the explorer may not by default", ctx do
    assert ctx.explorer.may_propose_lessons == false
    assert ctx.implementer.may_propose_lessons == true
    text = %{"text" => "Run unittest with -B."}

    assert {:error, {:may_not_propose, "explorer"}} =
             propose(text, worker(ctx, "explorer") |> Map.put(:agent, ctx.explorer.slug))

    assert {:ok, %{state: "proposed", proposer_role: "implementer"}} =
             propose(text, worker(ctx) |> Map.put(:agent, ctx.implementer.slug))

    # The switch applies at once.
    {:ok, _} = Agents.update(ctx.explorer, %{"may_propose_lessons" => "true"})
    {:ok, _} = Agents.update(ctx.coordinator, %{"may_propose_lessons" => "false"})

    assert {:ok, %{proposer_role: "explorer"}} =
             propose(%{"text" => "Read calc.py first."}, worker(ctx, "explorer", 2))

    assert {:error, {:may_not_propose, "coordinator"}} =
             propose(%{"text" => "Keep commits small.", "dispatch" => ctx.dispatch.id})

    # A worker's own dispatch is its source; reading the same origin again adds nothing.
    assert {:error, :origin_taken} =
             propose(%{"text" => "Something else."}, worker(ctx, "explorer", 2))
  end

  test "the coordinator decides a worker's proposal in its repository; the person decides any",
       ctx do
    {:ok, a} = propose(%{"text" => "Run unittest with -B."}, worker(ctx, "implementer", 1))
    {:ok, b} = propose(%{"text" => "Prefer small commits."}, worker(ctx, "implementer", 2))
    {:ok, c} = propose(%{"text" => "Never touch vendor/."}, worker(ctx, "implementer", 3))

    # A grant of another repository decides nothing here.
    elsewhere = new_repo!("two")
    {:ok, facts} = Shoestring.Cobbler.Intake.repository(elsewhere)
    {:ok, far} = Grants.create(grant_attrs("s3", facts.root), "human:operator")
    assert {:error, :not_allowed} = Lessons.decide(a.code, "approve", "grant:" <> far.id)
    assert {:error, :not_allowed} = Lessons.decide(a.code, "approve", "someone")

    by = "grant:" <> ctx.grant.id

    assert {:ok, %{state: "approved", text: "Run unittest with -B, always."}} =
             Lessons.decide(a.code, "approve", by, text: "Run unittest with -B, always.")

    assert {:ok, %{state: "rejected", decision_note: "Advice."}} =
             Lessons.decide(b.code, "reject", by, note: "Advice.")

    assert {:error, {:lesson_not_proposed, "approved"}} = Lessons.decide(a.code, "reject", by)

    # The person's last word: deciding, rewording, retiring. An agent cannot reword or retire.
    assert {:ok, %{state: "approved"}} = Lessons.decide(c.code, "approve", "human:operator")
    assert {:error, :non_human_identity} = Lessons.retire(c.code, by)
    assert {:error, :non_human_identity} = Lessons.edit(c.code, "x", by)

    assert {:ok, %{text: "Never edit vendor/."}} =
             Lessons.edit(c.code, "Never edit vendor/.", "human:operator")

    assert {:ok, %{state: "retired"}} = Lessons.retire(c.code, "human:operator", "Gone.")

    # A revoked grant decides nothing more.
    {:ok, d} = propose(%{"text" => "Run the linter."}, worker(ctx, "implementer", 4))
    {:ok, _} = Grants.revoke(ctx.grant, "human:operator")
    assert {:error, :not_allowed} = Lessons.decide(d.code, "approve", by)
  end

  test "the CLI decisions refuse without a terminal", ctx do
    {:ok, lesson} = propose(%{"text" => "Run unittest with -B."}, worker(ctx))

    context = %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end,
      cwd: ctx.repo,
      interactive?: fn -> false end
    }

    for argv <- [
          ["approve", lesson.code],
          ["reject", lesson.code],
          ["edit", lesson.code, "--text", "x"],
          ["retire", lesson.code]
        ] do
      error = assert_raise Shoestring.CLI.Refusal, fn -> Command.run(argv, context) end
      assert error.message =~ "a person's decision"
      assert Lessons.get(lesson.code).state == "proposed"
    end

    Command.run(["approve", lesson.code], %{context | interactive?: fn -> true end})
    assert Lessons.get(lesson.code).state == "approved"
    assert Lessons.get(lesson.code).decided_by =~ "human:"
  end

  test "a worker gets a lesson only when its dispatch cites it; the citation is counted", ctx do
    {:ok, lesson} = propose(%{"text" => "Run unittest with -B."}, worker(ctx))

    # Not yet approved: refused, nothing recorded.
    assert {:error, {:lesson_not_approved, code}} =
             Dispatches.create(implement(ctx.repo, "cited", %{lessons: [lesson.code]}))

    assert code == lesson.code
    {:ok, _} = Lessons.decide(lesson.code, "approve", "grant:" <> ctx.grant.id)

    assert {:ok, dispatch, :recorded} =
             Dispatches.create(
               implement(ctx.repo, "cited", %{lessons: [String.downcase(lesson.code)]})
             )

    assert dispatch.lesson_codes == [lesson.code]
    assert dispatch.brief =~ @brief
    assert dispatch.brief =~ "- #{lesson.code}: Run unittest with -B."
    assert Lessons.get(lesson.code).cite_count == 1

    # The worker's instructions are the dispatch's brief.
    assert {:ok, binding} = Dispatches.binding(dispatch.id, "Worker", Repo)
    assert binding["instructions"] =~ "Run unittest with -B."

    # A retry is the same dispatch and counts nothing; other lessons are another request.
    assert {:ok, same, :replayed} =
             Dispatches.create(implement(ctx.repo, "cited", %{lessons: [lesson.code]}))

    assert same.id == dispatch.id
    assert Lessons.get(lesson.code).cite_count == 1
    assert {:error, :request_id_conflict} = Dispatches.create(implement(ctx.repo, "cited"))

    # Without a citation the worker sees no lesson.
    {:ok, plain, :recorded} = Dispatches.create(implement(ctx.repo, "plain"))
    refute plain.brief =~ lesson.code

    # Retired, it can no longer be cited.
    {:ok, _} = Lessons.retire(lesson.code, "human:operator")

    assert {:error, {:lesson_not_approved, _}} =
             Dispatches.create(implement(ctx.repo, "late", %{lessons: [lesson.code]}))

    assert {:error, {:too_many_lessons, 5}} =
             Dispatches.create(implement(ctx.repo, "many", %{lessons: ~w(A B C D E F)}))
  end

  test "a worker is told how to propose only when its agent may", ctx do
    # The implementer may: its brief says where to write them.
    assert ctx.dispatch.brief =~ Lessons.lessons_file()

    # The explorer may not: its call is as before, with no lessons asked for.
    explore = %{implement(ctx.repo, "e1") | purpose: "explore", provider: "claude", model: "opus"}
    {:ok, plain, :recorded} = Dispatches.create(Map.put(explore, :agent, "explorer"))
    refute plain.brief =~ "lessons"
    refute Map.has_key?(plain.plan, "lessons")
    assert plain.plan["schema"] == Explore.schema()

    {:ok, _} = Agents.update(ctx.explorer, %{"may_propose_lessons" => "true"})

    {:ok, asked, :recorded} =
      Dispatches.create(explore |> Map.merge(%{request_id: "e2", agent: "explorer"}))

    assert asked.plan["lessons"] == true
    assert "lessons" in asked.plan["schema"]["required"]
    assert asked.brief =~ "put it in `lessons`"
  end

  test "an explorer's proposed lessons are read from its report once it completes", ctx do
    {:ok, _} = Agents.update(ctx.explorer, %{"may_propose_lessons" => "true"})

    explore = %{
      implement(ctx.repo, "e1")
      | purpose: "explore",
        provider: "claude",
        model: "opus"
    }

    {:ok, dispatch, :recorded} = Dispatches.create(Map.put(explore, :agent, "explorer"))
    assert Harvest.dispatch(dispatch) == []

    step = fn ->
      Calls.step(dispatch.id,
        adapters: %{{"explore", "claude"} => ExploreStandIn},
        adapter_opts: [scenario: {:lessons, ["Read calc.py before test/.", "  "]}]
      )
    end

    assert {:snooze, 30} = step.()
    assert Dispatches.advance(dispatch) == :confirmed
    assert :done = step.()
    assert Dispatches.state(dispatch) == "completed"

    # A screen's refresh and the detail read nothing: proposals are read when
    # the dispatch settles (the engine's inbox) or the coordinator asks.
    _ = ShoestringWeb.ChatDispatches.rows("s1", %{}, DateTime.utc_now())
    assert Shoestring.CLI.Commands.Runs.detail(dispatch)["lessons_proposed"] == []
    assert Lessons.list(source_ref: dispatch.id) == []

    assert [%{text: "Read calc.py before test/.", state: "proposed"} = lesson] =
             Harvest.dispatch(dispatch)

    assert {lesson.proposer_role, lesson.source_ref} == {"explorer", dispatch.id}
    # Read again, nothing is added.
    assert Harvest.dispatch(dispatch) == []
    assert [%{"code" => code}] = Shoestring.CLI.Commands.Runs.detail(dispatch)["lessons_proposed"]
    assert code == lesson.code
  end

  test "the coordinator proposes, searches and decides through its tools", ctx do
    binding = %{session_id: "s1", repository: ctx.repo}

    assert {:ok, %{"code" => code, "state" => "approved"}} =
             Tools.call(
               "lessons_propose",
               %{
                 "text" => "Regenerate priv/gen; never edit it.",
                 "quote" => "never edit the generated"
               },
               binding
             )

    assert {:ok, [%{"code" => ^code}]} =
             Tools.call("lessons_search", %{"query" => "priv/gen regenerate"}, binding)

    {:ok, waiting} = propose(%{"text" => "Keep commits small."}, worker(ctx))

    assert {:ok, %{"state" => "approved"}} =
             Tools.call(
               "lessons_decide",
               %{"code" => waiting.code, "decision" => "approve"},
               binding
             )

    assert {:ok, [_, _]} = Tools.call("lessons_search", %{}, binding)
    assert {:error, message} = Tools.call("lessons_propose", %{"text" => "No source."}, binding)
    assert message =~ "Name the lesson's source"

    # The coordinator's instructions list the approved ones, not proposals.
    {:ok, _} = propose(%{"text" => "Unapproved idea here."}, worker(ctx, "implementer", 9))
    text = Lessons.instructions(ctx.root)
    assert text =~ "`#{code}`: Regenerate priv/gen; never edit it."
    assert text =~ "Keep commits small."
    refute text =~ "Unapproved idea"
  end

  test "space counts lessons and bytes; past the limit nothing more is proposed", ctx do
    {:ok, _} = propose(%{"text" => "12345", "dispatch" => ctx.dispatch.id, "why" => "abc"})
    {:ok, _} = propose(%{"text" => "Never edit priv/gen.", "quote" => "never edit the generated"})

    assert %{count: 2, bytes: bytes, repositories: [repository], limit_bytes: limit} =
             Lessons.space()

    assert limit == 200 * 1024 * 1024
    assert repository.repository == ctx.root
    assert repository.counts == %{"approved" => 2}

    assert bytes ==
             5 + 3 + byte_size("Never edit priv/gen.") + byte_size("never edit the generated")

    # A 1 MB limit, already all but used: the next proposal is refused.
    settings = AgentProfiles.settings()
    {:ok, _} = AgentProfiles.save_settings(settings, %{"lessons_space_mb" => "1"})
    filler = String.duplicate("z", 1000)

    now = DateTime.utc_now()

    rows =
      for n <- 1..1049,
          do: %{
            id: Ecto.UUID.generate(),
            code: "L-F#{n}",
            repository_root: ctx.root,
            text: filler,
            state: "retired",
            source_kind: "dispatch",
            source_ref: ctx.dispatch.id,
            proposed_by: "human:operator",
            proposer_role: "coordinator",
            cite_count: 0,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(Shoestring.Lessons.Lesson, rows)

    assert {:error, {:lessons_space_full, 1}} =
             propose(%{"text" => "One more rule here.", "dispatch" => ctx.dispatch.id})

    assert Command.message({:lessons_space_full, 1}) =~ "1 MB limit"
  end

  test "the person moves a repository's lessons explicitly; codes, state and provenance survive",
       ctx do
    {:ok, approved} = propose(%{"text" => "Run unittest with -B.", "dispatch" => ctx.dispatch.id})
    {:ok, proposed} = propose(%{"text" => "Keep changes confined to the task."}, worker(ctx))
    destination = new_repo!("moved")
    {:ok, facts} = Shoestring.Cobbler.Intake.repository(destination)

    context = %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end,
      cwd: ctx.repo,
      interactive?: fn -> true end
    }

    args = ["move", "--from", ctx.root, "--repo", destination]

    assert_raise Shoestring.CLI.Refusal, ~r/a person's decision/, fn ->
      Command.run(args, %{context | interactive?: fn -> false end})
    end

    send(self(), {:mix_shell_input, :prompt, "n"})

    assert_raise Shoestring.CLI.Refusal, "Lessons not moved.", fn ->
      Command.run(args, context)
    end

    assert Lessons.get(approved.code).repository_root == ctx.root

    send(self(), {:mix_shell_input, :prompt, "y"})
    Command.run(args, context)
    assert Lessons.list(repository: ctx.root) == []
    assert {:ok, [moved]} = Lessons.for_brief(facts.root, [approved.code])

    assert Map.drop(Map.from_struct(moved), [:repository_root, :updated_at]) ==
             Map.drop(Map.from_struct(approved), [:repository_root, :updated_at])

    assert Lessons.get(proposed.code).state == "proposed"
    assert Lessons.space(facts.root).count == 2
    assert {:error, {:lesson_not_approved, _}} = Lessons.for_brief(ctx.root, [approved.code])

    assert {:error, :non_human_identity} =
             Lessons.move_repository(facts.root, ctx.root, "grant:fixture")

    assert {:error, :invalid_repository_move} =
             Lessons.move_repository(facts.root, facts.root, "human:operator")

    assert {:error, :lessons_destination_not_empty} =
             Lessons.move_repository(ctx.root, facts.root, "human:operator")

    assert {:error, :lessons_source_empty} =
             Lessons.move_repository(ctx.root, destination <> "-other", "human:operator")
  end
end
