defmodule Shoestring.DispatchBatchTest do
  @moduledoc """
  Batch IMPLEMENT dispatches (iteration 16 C2) up to their start: each task
  declares its files; a batch whose tasks could not run side by side is
  refused before anything is recorded; a batch takes one parallel place per
  task and reserves its tasks' time plus fan-out verification. A real
  temporary Git repository, Oban in manual testing mode, no provider. Running
  a batch in parallel is covered end to end in `Shoestring.DispatchIntegrationTest`.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{AgentProfiles, Dispatches, Grants, ModelCatalog}
  alias Shoestring.CLI.Commands.{Dispatch, Runs}
  alias Shoestring.Cobbler.Parallelism

  @brief "IMPLEMENT - two small changes\nContract: test/test_calc.py passes.\n"

  setup do
    repo = Path.join(System.tmp_dir!(), "shoestring-batch-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    File.mkdir_p!(Path.join(repo, "config"))
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    return a + b\n")
    File.write!(Path.join(repo, "strings.py"), "def shout(text):\n    return text\n")
    File.write!(Path.join(repo, "config/app.toml"), "x = 1\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    File.ln_s!("calc.py", Path.join(repo, "alias.py"))
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, facts} = Shoestring.Cobbler.Intake.repository(repo)
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")

    {:ok, grant} =
      Grants.create(
        %{
          session_id: "s1",
          repository_root: facts.root,
          models: ["codex:gpt-6-luna"],
          purposes: ["implement", "review"],
          max_dispatches: 10,
          max_parallel: 2,
          max_total_seconds: 4 * 3600,
          max_dispatch_seconds: 1_800,
          unread_usage: 0
        },
        "human:operator"
      )

    %{repo: repo, grant: grant}
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  # Another goal's task holding one of the places Settings allows.
  defp hold_place!(n) do
    goal = Shoestring.Test.CobblerHelpers.create_goal!()
    admission = Shoestring.Test.PlanExecutorHelpers.admit!(goal)
    {:ok, policy} = Shoestring.Cobbler.ReservationPolicy.new(Parallelism.policy(n))

    {:ok, reservation} =
      Shoestring.Cobbler.Reservations.hold(
        %{
          id: Ecto.UUID.generate(),
          goal_id: goal.id,
          execution_id: Ecto.UUID.generate(),
          plan_task_id: "elsewhere",
          attempt: 1,
          run_id: Ecto.UUID.generate(),
          admission_event_id: admission.id
        },
        policy,
        now: Shoestring.Test.PlanExecutorHelpers.now()
      )

    reservation
  end

  defp held(dispatch, changes) do
    {:ok, status} = Shoestring.Cobbler.ExecutionControl.status(dispatch.goal_id)

    held =
      Map.merge(
        %{
          status
          | last_admission: %{
              "result" => "require_confirmation",
              "decision_id" => Ecto.UUID.generate(),
              "candidate" => %{"provider_id" => "codex"},
              "scope" => "account:codex"
            }
        },
        changes
      )

    fn _ -> {:ok, held} end
  end

  defp batch(ctx, tasks, overrides \\ %{}) do
    Dispatches.create(
      Map.merge(
        %{
          session_id: "s1",
          request_id: "b-#{System.unique_integer([:positive])}",
          purpose: "implement",
          provider: "codex",
          model: "gpt-6-luna",
          title: "Two small changes",
          brief: @brief,
          repository: ctx.repo,
          tasks: tasks,
          seconds: 600
        },
        overrides
      )
    )
  end

  @two [
    %{"title" => "Mark calc", "brief" => "Append a comment to calc.py.", "files" => ["calc.py"]},
    %{"title" => "Mark strings", "files" => ["strings.py"]}
  ]

  test "a batch is one plan with a task per declared scope, sharing the brief", ctx do
    # Three tasks need three parallel places; the grant has two.
    assert {:error, {:outside_grant, :parallel}} =
             batch(ctx, @two ++ [%{"title" => "Third", "files" => ["test/test_calc.py"]}])

    assert {:ok, dispatch, :recorded} = batch(ctx, @two)
    assert dispatch.task_count == 2

    assert [
             %{
               "id" => "dispatch-1",
               "title" => "Mark calc",
               "outcome" => "Append a comment to calc.py.",
               "hints" => %{"files" => ["calc.py"]},
               "depends_on" => []
             },
             %{
               "id" => "dispatch-2",
               "title" => "Mark strings",
               "outcome" => "Mark strings",
               "hints" => %{"files" => ["strings.py"]},
               "depends_on" => []
             }
           ] = dispatch.plan["tasks"]

    # Its tasks' time, plus the verification a fan-out reserves for two.
    verification = 120 + 2 * div(Shoestring.Cobbler.ScopeEvidence.final_scope_bound_ms(2), 1000)

    assert dispatch.plan["budget"] == %{
             "max_total_attempts" => 2,
             "max_total_duration_seconds" => 1_200 + verification
           }

    assert {dispatch.max_attempts, dispatch.max_duration_seconds} == {2, 1_200 + verification}

    # One parallel place per task: the grant allows two, so nothing else fits.
    assert Dispatches.usage(ctx.grant).running == 2
    assert {:error, {:outside_grant, :parallel}} = batch(ctx, @two)

    assert Runs.detail(dispatch)["tasks"] == 2

    assert [%{"task" => "dispatch-1", "state" => "waiting"}, %{"task" => "dispatch-2"}] =
             Runs.detail(dispatch)["batch"]["tasks"]
  end

  test "tasks that could not run side by side are refused before anything is recorded", ctx do
    refused = fn tasks ->
      assert {:error, {:batch_scopes, blockers}} = batch(ctx, tasks)
      Enum.map(blockers, & &1["reason"])
    end

    assert refused.([
             %{"title" => "A", "files" => ["calc.py"]},
             %{"title" => "B", "files" => ["calc.py"]}
           ]) ==
             ["scope_overlap"]

    # A directory overlaps what it holds.
    assert "scope_overlap" in refused.([
             %{"title" => "A", "files" => ["test"]},
             %{"title" => "B", "files" => ["test/test_calc.py"]}
           ])

    assert "shared_surface" in refused.([
             %{"title" => "A", "files" => ["config/app.toml"]},
             %{"title" => "B", "files" => ["calc.py"]}
           ])

    assert "symlink_scope" in refused.([
             %{"title" => "A", "files" => ["alias.py"]},
             %{"title" => "B", "files" => ["strings.py"]}
           ])

    assert {:error, {:batch_task_files, 2}} =
             batch(ctx, [
               %{"title" => "A", "files" => ["calc.py"]},
               %{"title" => "B", "files" => []}
             ])

    assert {:error, {:batch_task_files, 1}} =
             batch(ctx, [
               %{"title" => "A", "files" => ["/etc/passwd"]},
               %{"title" => "B", "files" => ["x"]}
             ])

    assert {:error, {:batch_too_large, 8}} =
             batch(ctx, for(n <- 1..9, do: %{"title" => "T#{n}", "files" => ["f#{n}.py"]}))

    assert {:error, {:invalid_dispatch, :tasks}} = batch(ctx, [hd(@two)])
    assert Repo.aggregate(Shoestring.Dispatches.Dispatch, :count) == 0

    assert Dispatch.message(
             {:batch_scopes,
              [
                %{
                  "reason" => "scope_overlap",
                  "task_ids" => ["dispatch-1", "dispatch-2"],
                  "paths" => ["calc.py", "calc.py"]
                }
              ]},
             %{}
           ) =~
             "tasks dispatch-1 and dispatch-2 both change calc.py"
  end

  test "a batch can wait for a predecessor; --tasks is for IMPLEMENT", ctx do
    {:ok, first, :recorded} =
      Dispatches.create(%{
        session_id: "s1",
        request_id: "one",
        purpose: "implement",
        provider: "codex",
        model: "gpt-6-luna",
        title: "One",
        brief: @brief,
        repository: ctx.repo
      })

    # Waiting is allowed, but a batch wider than the entire grant could
    # never start. Refuse it before reserving attempts or time.
    assert {:error, {:outside_grant, :parallel}} =
             batch(ctx, @two ++ [%{"title" => "Third", "files" => ["test/test_calc.py"]}], %{
               after_dispatch: first.id
             })

    {:ok, _} = Shoestring.Grants.extend(ctx.grant, %{max_parallel: 3}, "human:operator")

    assert {:ok, dependent, :recorded} = batch(ctx, @two, %{after_dispatch: first.id})
    assert dependent.after_dispatch_id == first.id
    assert dependent.state == "chained"
    assert dependent.task_count == 2

    fields = %{
      session_id: "s1",
      repository: ctx.repo,
      purpose: "explore",
      worker: "codex:gpt-6-luna",
      title: "T",
      brief: @brief,
      tasks: @two
    }

    assert {:error, "--tasks is only for --purpose implement"} = Dispatch.build_request(fields)
    assert {:ok, %{tasks: [_, _]}} = Dispatch.build_request(%{fields | purpose: "implement"})
  end

  test "an accepted batch is merged by Shoestring: it waits for the person only when that stopped",
       ctx do
    {:ok, dispatch, :recorded} = batch(ctx, @two)
    execution_id = Ecto.UUID.generate()
    commits = for n <- 1..2, do: String.duplicate(Integer.to_string(n), 40)

    status = %{
      execution: %{execution_id: execution_id},
      dispatch_mode: :fanout_v1,
      active_run_ids: [],
      integration: nil,
      accepted_count: 2,
      total_tasks: 2,
      accepted_evidence: Enum.map(commits, &%{commit: &1})
    }

    # Merging (or about to): Shoestring is at work, nothing waits for the person.
    assert Dispatches.state(dispatch, fn _ -> {:ok, status} end) == "running"

    # A stop recorded for other commits (a task accepted since) does not count.
    block = fn accepted ->
      {:ok, _} =
        Shoestring.Trajectory.append(dispatch.goal_id, %{
          "type" => "cobbler.plan.merge.blocked",
          "schema_version" => 1,
          "actor" => "cobbler",
          "occurred_at" => DateTime.utc_now(),
          "idempotency_key" =>
            "plan-merge-blocked:#{execution_id}:" <>
              Base.encode16(:crypto.hash(:sha256, Enum.join(accepted, ",")), case: :lower),
          "payload" => %{
            "execution_id" => execution_id,
            "revision_number" => 1,
            "plan_digest" => String.duplicate("a", 64),
            "accepted_commits" => accepted,
            "reason" => "conflict",
            "plan_task_id" => "dispatch-2",
            "files" => ["calc.py"],
            "merged_task_ids" => ["dispatch-1"]
          }
        })
    end

    block.([hd(commits)])
    assert Dispatches.state(dispatch, fn _ -> {:ok, status} end) == "running"

    block.(commits)
    assert Dispatches.state(dispatch, fn _ -> {:ok, status} end) == "needs_you"

    assert %{"plan_task_id" => "dispatch-2"} =
             Shoestring.Cobbler.PlanMerge.blocked(dispatch.goal_id, status)

    # Once integrated (by Shoestring or by hand), the stop no longer applies.
    integrated = %{status | integration: %{commit: hd(commits), covers?: true}}
    assert Shoestring.Cobbler.PlanMerge.blocked(dispatch.goal_id, integrated) == nil
    refute Dispatches.state(dispatch, fn _ -> {:ok, integrated} end) == "needs_you"
  end

  test "the person's setting turns into iteration 7's policy; 1 keeps everything sequential" do
    assert Parallelism.tasks() == 1
    assert Parallelism.policy(1) == nil
    assert Parallelism.policy() == nil
    refute Parallelism.fanout?()

    {:ok, _} = AgentProfiles.save_settings(AgentProfiles.settings(), %{"parallel_tasks" => "3"})

    assert Parallelism.policy() == %{
             "version" => 1,
             "global_limit" => 3,
             "provider_account_limit" => 3,
             "goal_limit" => 3,
             "account_units" => 3,
             "task_units" => 1
           }

    assert Parallelism.fanout?()
    assert {:ok, _} = Shoestring.Cobbler.ReservationPolicy.new(Parallelism.policy())

    assert {:error, changeset} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{"parallel_tasks" => "9"})

    assert changeset.errors[:parallel_tasks]
  end

  test "a full batch does not spend or record a hold confirmation until a place is free", ctx do
    {:ok, grant} =
      Shoestring.Grants.extend(
        ctx.grant,
        %{max_parallel: 3, add_unread_usage: 2},
        "human:operator"
      )

    {:ok, _} = AgentProfiles.save_settings(AgentProfiles.settings(), %{"parallel_tasks" => "2"})

    {:ok, dispatch, :recorded} =
      batch(ctx, @two ++ [%{"title" => "Third", "files" => ["test/test_calc.py"]}])

    {:ok, status} = Shoestring.Cobbler.ExecutionControl.status(dispatch.goal_id)

    held = %{
      status
      | active_children: [%{plan_task_id: "dispatch-1"}, %{plan_task_id: "dispatch-2"}],
        last_admission: %{
          "result" => "require_confirmation",
          "decision_id" => Ecto.UUID.generate()
        }
    }

    full = fn _ -> {:ok, held} end
    assert Dispatches.advance(dispatch, full) == :none
    assert Dispatches.confirm_hold(dispatch, "human:operator", full) == :none
    assert Shoestring.Grants.get(grant.id).unread_usage_used == 0

    free = fn _ ->
      {:ok, %{held | active_children: [%{plan_task_id: "dispatch-1"}], accepted: ["dispatch-2"]}}
    end

    assert Dispatches.advance(dispatch, free) == :confirmed
    assert Shoestring.Grants.get(grant.id).unread_usage_used == 1

    confirmation =
      Shoestring.Cobbler.PlanCapacityConfirmation.available(
        dispatch.goal_id,
        status.execution,
        %{"id" => "dispatch-3"},
        1,
        "subscription"
      )

    assert confirmation.payload["plan_task_id"] == "dispatch-3"
    assert Dispatches.advance(dispatch, free) == :none
    assert Shoestring.Grants.get(grant.id).unread_usage_used == 1
  end

  test "a held single task spends no confirmation while every place is taken", ctx do
    {:ok, grant} =
      Shoestring.Grants.extend(ctx.grant, %{add_unread_usage: 2}, "human:operator")

    {:ok, _} = AgentProfiles.save_settings(AgentProfiles.settings(), %{"parallel_tasks" => "2"})
    {:ok, single, :recorded} = batch(ctx, [], %{files: ["calc.py"]})
    assert single.task_count in [nil, 1]

    # Two other dispatches hold both places: the confirmation would buy nothing.
    for _ <- 1..2, do: hold_place!(2)
    full = held(single, %{active_run_id: nil})
    assert Dispatches.advance(single, full) == :none
    assert Dispatches.confirm_hold(single, "human:operator", full) == :none
    assert Shoestring.Grants.get(grant.id).unread_usage_used == 0
  end

  test "a held single task at parallel tasks 2 spends its confirmation while a place is free",
       ctx do
    {:ok, grant} =
      Shoestring.Grants.extend(ctx.grant, %{add_unread_usage: 2}, "human:operator")

    {:ok, _} = AgentProfiles.save_settings(AgentProfiles.settings(), %{"parallel_tasks" => "2"})
    {:ok, single, :recorded} = batch(ctx, [], %{files: ["calc.py"]})
    hold_place!(2)
    assert Dispatches.advance(single, held(single, %{active_run_id: nil})) == :confirmed
    assert Shoestring.Grants.get(grant.id).unread_usage_used == 1
  end

  test "a batch counts every dispatch's places, not just its own, at 2 and at 3", ctx do
    {:ok, grant} =
      Shoestring.Grants.extend(
        ctx.grant,
        %{max_parallel: 3, add_unread_usage: 2},
        "human:operator"
      )

    {:ok, _} = AgentProfiles.save_settings(AgentProfiles.settings(), %{"parallel_tasks" => "2"})
    {:ok, dispatch, :recorded} = batch(ctx, @two)

    # Nothing of this batch runs, but two single dispatches hold both places.
    places = for _ <- 1..2, do: hold_place!(2)
    full = held(dispatch, %{active_children: []})
    assert Dispatches.advance(dispatch, full) == :none
    assert Shoestring.Grants.get(grant.id).unread_usage_used == 0

    # At 3 the same two leave a place free (the setting changes only once
    # nothing holds one).
    for place <- places,
        do:
          assert(
            {:ok, _} =
              Shoestring.Cobbler.Reservations.reconcile(place.id,
                now: Shoestring.Test.PlanExecutorHelpers.now()
              )
          )

    assert Shoestring.Cobbler.Reservations.outstanding() == []
    {:ok, _} = AgentProfiles.save_settings(AgentProfiles.settings(), %{"parallel_tasks" => "3"})
    for _ <- 1..2, do: hold_place!(3)
    assert Dispatches.advance(dispatch, held(dispatch, %{active_children: []})) == :confirmed
    assert Shoestring.Grants.get(grant.id).unread_usage_used == 1
  end
end
