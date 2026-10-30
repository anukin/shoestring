defmodule Shoestring.DispatchesTest do
  @moduledoc """
  Coordinator dispatches under a grant (iteration 14 packages D and E), up to
  queued execution: a real temporary Git repository, Oban in manual testing
  mode and no service, provider or network. Scratch repositories are kept.
  """
  use Shoestring.DataCase, async: false
  import Ecto.Query

  alias Shoestring.{Authority, Dispatches, Grants, ModelCatalog, Repo}
  alias Shoestring.Cobbler.{ExecutionControl, ExecutionProfile, Plans}
  alias Shoestring.Dispatches.Dispatch

  @brief """
  IMPLEMENT - make add() return the sum of its arguments
  Stay out of: test/
  Contract: test/test_calc.py passes.
  """

  setup do
    repo = Path.join(System.tmp_dir!(), "shoestring-dispatch-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    {:ok, facts} = Shoestring.Cobbler.Intake.repository(repo)

    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
    {:ok, _} = ModelCatalog.add("claude", "opus")
    {:ok, grant} = Grants.create(grant_attrs(facts.root), "human:operator")

    %{repo: repo, root: facts.root, grant: grant}
  end

  defp grant_attrs(root, overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "s1",
        repository_root: root,
        models: ["codex:gpt-6-luna"],
        purposes: ["implement", "review"],
        max_dispatches: 3,
        max_parallel: 2,
        max_total_seconds: 7_200,
        max_dispatch_seconds: 3_600,
        unread_usage: 0
      },
      overrides
    )
  end

  defp request(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "s1",
        request_id: "r1",
        purpose: "implement",
        provider: "codex",
        model: "gpt-6-luna",
        title: "Make add return the sum of its arguments",
        brief: @brief,
        repository: ctx.repo,
        files: ["calc.py"],
        stay_out: ["test/"]
      },
      overrides
    )
  end

  defp git!(dir, args) do
    {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
  end

  defp jobs, do: Repo.all(Oban.Job)

  test "an implement dispatch becomes a grant-authored, grant-approved plan queued for the service",
       ctx do
    assert {:ok, %Dispatch{state: "started"} = dispatch, :recorded} =
             Dispatches.create(request(ctx))

    identity = Authority.grant_identity(ctx.grant.id)

    assert %{revision: revision} = Plans.authority(dispatch.goal_id)
    assert revision.authored_by == identity
    assert revision.author_kind == "grant"
    assert revision.digest == dispatch.plan_digest

    assert [%{"id" => "dispatch", "hints" => %{"files" => ["calc.py"]}}] =
             revision.content["tasks"]

    assert "Do not change test/." in revision.content["goal"]["constraints"]

    assert {:ok, %{execution: execution}} = ExecutionControl.status(dispatch.goal_id)
    assert execution.execution_id == dispatch.execution_id
    binding = execution.agent_profile
    assert binding["dispatch_id"] == dispatch.id
    assert binding["model"] == "gpt-6-luna"
    assert binding["instructions"] == @brief
    assert ExecutionProfile.validate(binding, Repo) == :ok
    assert ExecutionProfile.identity(binding).provider == "codex"
    assert [_job] = jobs()

    assert Dispatches.state(dispatch) == "queued"
    assert {:ok, ^dispatch, :replayed} = Dispatches.create(request(ctx))
    assert [_job] = jobs()

    assert Dispatches.create(request(ctx, %{brief: "something else"})) ==
             {:error, :request_id_conflict}

    assert {:ok, %{consistent?: true, divergences: []}} = Plans.rebuild(dispatch.goal_id)
  end

  test "every grant limit refuses before anything is recorded", ctx do
    refusals = [
      {%{model: "opus", provider: "claude"}, {:error, {:outside_grant, :model}}},
      {%{purpose: "review"}, {:error, {:invalid_dispatch, :target}}},
      {%{attempts: 4}, {:error, {:outside_grant, :dispatches}}},
      {%{seconds: 3_601}, {:error, {:outside_grant, :dispatch_duration}}},
      {%{session_id: "nobody"}, {:error, :no_grant}}
    ]

    for {overrides, expected} <- refusals do
      assert Dispatches.create(request(ctx, overrides)) == expected, inspect(overrides)
    end

    other = Path.join(System.tmp_dir!(), "shoestring-dispatch-other-#{Ecto.UUID.generate()}")
    File.mkdir_p!(other)
    File.write!(Path.join(other, "x_test.exs"), "")
    git!(other, ["init", "-q", "-b", "main"])
    git!(other, ["add", "."])
    git!(other, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])

    assert Dispatches.create(request(ctx, %{repository: other, gates: ["mix_test"]})) ==
             {:error, {:outside_grant, :repository}}

    assert Repo.all(Dispatch) == []
    assert jobs() == []

    # Two may run at once; the third waits for room, and the attempts run out.
    assert {:ok, _, :recorded} = Dispatches.create(request(ctx, %{request_id: "a"}))
    assert {:ok, _, :recorded} = Dispatches.create(request(ctx, %{request_id: "b"}))

    assert Dispatches.create(request(ctx, %{request_id: "c"})) ==
             {:error, {:outside_grant, :parallel}}

    {:ok, _} = Grants.extend(ctx.grant, %{max_parallel: 3}, "human:operator")
    assert {:ok, _, :recorded} = Dispatches.create(request(ctx, %{request_id: "c"}))

    assert Dispatches.create(request(ctx, %{request_id: "d"})) ==
             {:error, {:outside_grant, :dispatches}}

    {:ok, revoked} = Grants.revoke(Grants.get(ctx.grant.id), "human:operator")
    assert revoked.revoked_at
    assert Dispatches.create(request(ctx, %{request_id: "e"})) == {:error, :no_grant}
    assert length(Repo.all(Dispatch)) == 3
  end

  test "a grant identity used outside its dispatch decides nothing", ctx do
    {:ok, dispatch, :recorded} = Dispatches.create(request(ctx))
    identity = Authority.grant_identity(ctx.grant.id)
    %{revision: revision} = Plans.authority(dispatch.goal_id)

    other = Shoestring.Test.CobblerHelpers.create_goal!()
    plan = Shoestring.Test.PlanFixtures.plan()

    assert {:error, {:grant_does_not_cover, _}} =
             Plans.propose(other.id, %{proposal_id: "p", plan: plan, authored_by: identity})

    assert {:error, {:grant_does_not_cover, _}} =
             Plans.propose(other.id, %{proposal_id: "p", plan: plan, authored_by: identity},
               dispatch: dispatch
             )

    # Another revision of the dispatch's own goal is not the plan it authored.
    assert {:error, {:grant_does_not_cover, _}} =
             Plans.propose(
               dispatch.goal_id,
               %{
                 proposal_id: "bigger",
                 plan: put_in(revision.content, ["budget", "max_total_attempts"], 20),
                 authored_by: identity,
                 parent_revision_number: 1
               },
               dispatch: dispatch
             )

    assert {:error, {:non_human_identity, _}} =
             Plans.reject(
               dispatch.goal_id,
               %{
                 decision_id: "no",
                 revision_number: 1,
                 digest: revision.digest,
                 decided_by: identity,
                 reason: "no"
               },
               dispatch: dispatch
             )

    assert {:error, :human_execution_identity_required} =
             ExecutionControl.start(dispatch.goal_id, %{
               revision_number: 1,
               digest: revision.digest,
               repository_path: ctx.root,
               requested_by: identity
             })
  end

  test "a dry run checks the grant and records nothing", ctx do
    assert {:ok, %{"would_dispatch" => true, "grant_check" => "ok", "grant" => room}} =
             Dispatches.dry_run(request(ctx))

    assert room["attempts"] == %{"used" => 0, "limit" => 3}

    assert {:ok, %{"advice" => advice}} = Dispatches.dry_run(request(ctx))
    assert advice["note"] == "no estimate yet (0 of 10 runs)"

    assert advice["kind"] == %{
             "harness" => "codex",
             "model" => "gpt-6-luna",
             "effort" => nil,
             "purpose" => "implement",
             "task_class" => "gates:python_unittest"
           }

    assert {:ok, %{"would_dispatch" => false, "grant_check" => "outside_grant:dispatches"}} =
             Dispatches.dry_run(request(ctx, %{attempts: 4}))

    assert Repo.all(Dispatch) == []
  end

  test "a declared batch takes only its size, and keeps it", ctx do
    {:ok, _} = Grants.extend(ctx.grant, %{add_dispatches: 3, max_parallel: 4}, "human:operator")

    batch = fn id, size ->
      request(ctx, %{request_id: id, batch_label: "try", batch_size: size})
    end

    assert {:ok, _, :recorded} = Dispatches.create(batch.("t1", 2))
    assert Dispatches.create(batch.("t2", 3)) == {:error, {:batch_size_changed, "try"}}
    assert {:ok, _, :recorded} = Dispatches.create(batch.("t2", 2))
    assert Dispatches.create(batch.("t3", 2)) == {:error, {:batch_full, "try"}}
  end

  test "a dispatch's state follows its execution, including a usage hold", ctx do
    {:ok, dispatch, :recorded} = Dispatches.create(request(ctx))

    status = fn overrides ->
      fn _goal_id ->
        {:ok,
         Map.merge(
           %{
             cancelled?: false,
             completed?: false,
             needs_user?: false,
             active_run_id: nil,
             last_admission: nil
           },
           overrides
         )}
      end
    end

    assert Dispatches.state(dispatch, status.(%{})) == "queued"

    assert Dispatches.state(dispatch, status.(%{active_run_id: Ecto.UUID.generate()})) ==
             "running"

    held = %{last_admission: %{"result" => "require_confirmation"}}
    assert Dispatches.state(dispatch, status.(held)) == "held"

    deferred = fn until ->
      %{
        last_admission: %{
          "result" => "defer_until",
          "reason_code" => "reserve_breach_five_hour",
          "defer_until" => until |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }
      }
    end

    later = DateTime.add(DateTime.utc_now(), 3_600)
    assert Dispatches.state(dispatch, status.(deferred.(later))) == "waiting"
    refute Dispatches.settled?("waiting")
    # Once the reset has passed, admission decides again.
    earlier = DateTime.add(DateTime.utc_now(), -60)
    assert Dispatches.state(dispatch, status.(deferred.(earlier))) == "queued"
    assert Dispatches.settled?("held")
    assert Dispatches.state(dispatch, status.(%{needs_user?: true})) == "needs_you"
    assert Dispatches.state(dispatch, status.(%{completed?: true})) == "completed"

    assert Dispatches.state(dispatch, status.(%{cancelled?: true, completed?: true})) ==
             "cancelled"

    refute Dispatches.settled?("queued")
  end

  test "a reviewer must be another vendor's model the grant allows", ctx do
    claude = %{reviewer_provider: "claude", reviewer_model: "opus"}

    assert Dispatches.create(
             request(ctx, %{reviewer_provider: "codex", reviewer_model: "gpt-6-luna"})
           ) ==
             {:error, {:reviewer_same_vendor, "codex:gpt-6-luna"}}

    assert Dispatches.create(request(ctx, claude)) == {:error, {:outside_grant, :model}}

    {:ok, _} = Grants.revoke(ctx.grant, "human:operator")

    {:ok, _} =
      Grants.create(
        grant_attrs(ctx.root, %{
          models: ["codex:gpt-6-luna", "claude:opus"],
          purposes: ["implement"]
        }),
        "human:operator"
      )

    assert Dispatches.create(request(ctx, claude)) == {:error, {:outside_grant, :purpose}}
    assert Repo.all(Dispatch) == []
  end

  test "a dispatch with a reviewer is cross-reviewed whatever :plan_review says; one without is not",
       ctx do
    {:ok, _} = Grants.revoke(ctx.grant, "human:operator")

    {:ok, _} =
      Grants.create(
        grant_attrs(ctx.root, %{models: ["codex:gpt-6-luna", "claude:opus"]}),
        "human:operator"
      )

    {:ok, reviewed, :recorded} =
      Dispatches.create(request(ctx, %{reviewer_provider: "claude", reviewer_model: "opus"}))

    {:ok, plain, :recorded} = Dispatches.create(request(ctx, %{request_id: "plain"}))

    execution = fn dispatch ->
      {:ok, %{execution: execution}} = ExecutionControl.status(dispatch.goal_id)
      execution
    end

    alias Shoestring.Cobbler.Review.Configuration

    assert {:ok, {:required, %{public: public}}} =
             Configuration.load(execution.(reviewed), review_config: [enabled: false])

    assert %{"provider_id" => "claude", "model" => "opus", "implementer_provider" => "codex"} =
             public

    # The dispatch's reviewer wins over a configured adapter.
    assert {:ok, {:required, %{public: %{"provider_id" => "claude"}}}} =
             Configuration.load(execution.(reviewed),
               review_config: [enabled: true, adapter: :codex, model: "gpt-review"]
             )

    assert {:ok, :not_required} =
             Configuration.load(execution.(plain), review_config: [enabled: true])

    held = fn _goal_id ->
      {:ok,
       %{
         cancelled?: false,
         completed?: false,
         needs_user?: false,
         active_run_id: nil,
         last_admission: nil,
         reviews: [%{state: "held"}]
       }}
    end

    assert Dispatches.state(reviewed, held) == "held"
  end

  test "a usage hold spends one pre-approved unread-usage dispatch, once; then waits for a person",
       ctx do
    {:ok, _} = ModelCatalog.add("opencode", "opencode/fixture-free")
    {:ok, _} = Grants.revoke(ctx.grant, "human:operator")

    {:ok, grant} =
      Grants.create(
        grant_attrs(ctx.root, %{models: ["opencode:opencode/fixture-free"], unread_usage: 1}),
        "human:operator"
      )

    opencode = %{provider: "opencode", model: "opencode/fixture-free"}
    {:ok, first, :recorded} = Dispatches.create(request(ctx, opencode))

    {:ok, second, :recorded} =
      Dispatches.create(request(ctx, Map.put(opencode, :request_id, "r2")))

    # opencode's remaining usage is never readable, so admission asks.
    hold! = fn dispatch ->
      {:ok, %{execution: execution}} = ExecutionControl.status(dispatch.goal_id)
      task = %{"id" => "dispatch", "execution" => %{"max_duration_seconds" => 1800}}

      assert {:error, {:execution_admission_blocked, _}} =
               Shoestring.Cobbler.ExecutionAdmission.admit(dispatch.goal_id, execution, task, 1)
    end

    hold!.(first)
    assert Dispatches.state(first) == "held"

    assert Dispatches.advance(first) == :confirmed
    assert Grants.get(grant.id).unread_usage_used == 1
    # Confirmed, it waits for the next admission, not for a person.
    assert Dispatches.state(first) == "queued"

    confirmation =
      Repo.one!(
        from e in Shoestring.Trajectory.TrajectoryEvent,
          where: e.goal_id == ^first.goal_id and e.type == "cobbler.plan.capacity.confirmed"
      )

    assert confirmation.actor == "grant"
    assert confirmation.payload["confirmed_by"] == Authority.grant_identity(grant.id)

    # The same hold again replays the same confirmation and spends nothing.
    assert Dispatches.advance(first) == :confirmed
    assert Grants.get(grant.id).unread_usage_used == 1
    assert [_] = Enum.filter(Grants.events(grant.id), &(&1.kind == "unread_usage_used"))

    # None left: the second hold waits for a person.
    hold!.(second)
    assert Dispatches.advance(second) == :none
    assert Dispatches.state(second) == "held"
    assert Grants.get(grant.id).unread_usage_used == 1
  end

  test "a dispatch is cancelled under its grant", ctx do
    {:ok, dispatch, :recorded} = Dispatches.create(request(ctx))
    assert {:ok, _} = Dispatches.cancel(dispatch, "Superseded by a smaller change.")

    assert [%{requested_by: by}] =
             Shoestring.Cobbler.PlanCancellation.summary(
               Repo,
               dispatch.goal_id,
               dispatch.execution_id
             )

    assert by == Authority.grant_identity(ctx.grant.id)
  end

  test "cancelling one dispatch leaves its sibling queued and uncancelled", ctx do
    {:ok, first, :recorded} = Dispatches.create(request(ctx, %{request_id: "a"}))
    {:ok, sibling, :recorded} = Dispatches.create(request(ctx, %{request_id: "b"}))
    assert {:ok, _} = Dispatches.cancel(first, "Superseded.")

    summary = &Shoestring.Cobbler.PlanCancellation.summary(Repo, &1.goal_id, &1.execution_id)
    assert [_] = summary.(first)
    assert [] = summary.(sibling)
    assert Dispatches.state(sibling) == "queued"
  end

  test "a dispatch interrupted before recording its start resumes into the same execution",
       ctx do
    {:ok, dispatch, :recorded} = Dispatches.create(request(ctx))
    # As if the process stopped after starting the execution, before
    # recording that it had.
    dispatch |> Ecto.Changeset.change(state: "creating", execution_id: nil) |> Repo.update!()
    assert Dispatches.state(Dispatches.get(dispatch.id)) == "starting"

    assert {:ok, resumed, :replayed} = Dispatches.create(request(ctx))
    assert resumed.id == dispatch.id
    assert resumed.state == "started"
    assert resumed.execution_id == dispatch.execution_id
    assert [_job] = jobs()
    assert {:ok, %{consistent?: true, divergences: []}} = Plans.rebuild(dispatch.goal_id)
  end

  # Regression: the store refuses secrets, so a title or brief with one
  # failed the dispatch (on 74190b7 this test fails at the first assertion:
  # the goal statement "must not contain secrets"; a brief alone failed at
  # `cobbler.plan.execution.requested`).
  test "secret-looking text in the title, brief or cancel reason is redacted; the rest is kept",
       ctx do
    brief =
      "IMPLEMENT - make add() return the sum\n" <>
        "The fixture uses api_key=sk-test-abcdef1234567890; send authorization: Bearer abc.def\n" <>
        "Contract: test/test_calc.py passes.\n"

    title = "Make add return the sum, token: hunter2"
    secret_request = request(ctx, %{brief: brief, title: title})

    assert {:ok, %Dispatch{state: "started"} = dispatch, :recorded} =
             Dispatches.create(secret_request)

    for text <- [dispatch.brief, dispatch.title] do
      refute Shoestring.Harness.Security.secret_value?(text)
      refute text =~ "sk-test-abcdef"
      refute text =~ "abc.def"
      refute text =~ "hunter2"
    end

    assert dispatch.brief =~ "IMPLEMENT - make add() return the sum\nThe fixture uses "
    assert dispatch.brief =~ "\nContract: test/test_calc.py passes.\n"
    assert dispatch.title =~ "Make add return the sum, "

    # The worker reads the redacted brief, and a retry replays the dispatch.
    assert {:ok, %{execution: execution}} = ExecutionControl.status(dispatch.goal_id)
    assert execution.agent_profile["instructions"] == dispatch.brief
    assert {:ok, ^dispatch, :replayed} = Dispatches.create(secret_request)

    assert {:ok, _} = Dispatches.cancel(dispatch, "Superseded; password=hunter2 was wrong.")

    assert [reason] =
             Repo.all(
               from e in Shoestring.Trajectory.TrajectoryEvent,
                 where:
                   e.goal_id == ^dispatch.goal_id and
                     e.type == "cobbler.plan.cancellation.requested",
                 select: fragment("json_extract(?, '$.reason')", e.payload)
             )

    assert reason =~ "Superseded; "
    refute reason =~ "hunter2"
  end

  test "creating, extending and revoking a grant needs a person and records each change", ctx do
    assert Grants.create(
             grant_attrs(ctx.root, %{session_id: "s2"}),
             "grant:" <> Ecto.UUID.generate()
           ) ==
             {:error, :non_human_identity}

    assert {:error, {:invalid_grant, {:model, "codex:not-enabled"}}} =
             Grants.create(
               grant_attrs(ctx.root, %{session_id: "s2", models: ["codex:not-enabled"]}),
               "human:operator"
             )

    assert {:error, {:invalid_grant, :limits}} =
             Grants.create(
               grant_attrs(ctx.root, %{session_id: "s2", max_parallel: 4}),
               "human:operator"
             )

    {:ok, grant} = Grants.extend(ctx.grant, %{add_dispatches: 2}, "human:operator")
    assert grant.max_dispatches == 5
    assert grant.limits_revision == 2

    {:ok, _} = Grants.revoke(grant, "human:operator")
    assert Enum.map(Grants.events(grant.id), & &1.kind) == ["created", "extended", "revoked"]

    assert Grants.extend(Grants.get(grant.id), %{add_dispatches: 1}, "human:operator") ==
             {:error, :grant_revoked}
  end
end
