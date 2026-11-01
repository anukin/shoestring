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

  test "a batch neither follows another nor is reviewed as one; --tasks is for IMPLEMENT", ctx do
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

    assert {:error, :batch_after} = batch(ctx, @two, %{after_dispatch: first.id})

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
end
