defmodule Shoestring.CLI.WorkLoopTest do
  @moduledoc """
  `shoestring do` up to queued execution, with the fixture planner, a real
  temporary Git repository and `Mix.Shell.Process` answering the prompts. No
  provider, network or service: the service check is injected. Scratch
  repositories are kept.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.AgentProfiles
  alias Shoestring.CLI.WorkLoop
  alias Shoestring.Cobbler.{Intake, Plans}
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Trajectory.Goal
  import Shoestring.Test.PlanFixtures, only: [task: 4]

  @now ~U[2026-10-15 12:00:00.000000Z]
  @request "Make add return the sum of its arguments."

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)

    repo = Path.join(System.tmp_dir!(), "shoestring-do-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])

    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{"claude_models" => "default\nopus"})

    {:ok, agent} =
      AgentProfiles.create(%{
        "name" => "Builder",
        "slug" => "builder",
        "purpose" => "Carry out approved plan tasks.",
        "instructions" => "Stay in scope.",
        "roles" => [
          %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
          %{"name" => "Worker", "provider" => "claude", "model" => "opus"}
        ]
      })

    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{"default_agent_id" => agent.id})

    %{repo: repo, agent: agent, edit_dir: (repo <> "-edits") |> tap(&File.mkdir_p!/1)}
  end

  defp git!(dir, args) do
    {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    :ok
  end

  # The fixture planner returns a plan that keeps the exact contract `do` built.
  defp plan_json(ctx) do
    {:ok, facts} = Intake.repository(ctx.repo)
    {:ok, gates} = Intake.gates(facts)
    {:ok, contract} = Intake.goal_contract(@request, facts, gates)

    Jason.encode!(%{
      "version" => 1,
      "goal" => contract,
      "budget" => %{"max_total_attempts" => 2, "max_total_duration_seconds" => 1_200},
      "tasks" => [
        task("add", "Implement add", [], %{
          "gates" => gates,
          "hints" => %{"files" => ["calc.py"], "symbols" => ["add"]},
          "expected_artifacts" => ["calc.py"],
          "execution" => %{"max_attempts" => 1, "max_duration_seconds" => 600}
        })
      ]
    })
  end

  defp run(ctx, extra \\ []) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    opts =
      [
        repo: ctx.repo,
        by: "human:operator",
        shell: Mix.Shell.Process,
        service: fn -> :ok end,
        edit_dir: ctx.edit_dir,
        planner_config: [
          adapter: :fixture,
          model: "fixture-v1",
          responses: Keyword.get_lazy(extra, :responses, fn -> [{:ok, plan_json(ctx), 30}] end)
        ],
        planner_opts: [
          now: @now,
          snapshot: Keyword.get(extra, :snapshot, snapshot()),
          task_supervisor: supervisor
        ]
      ]
      |> Keyword.merge(Keyword.drop(extra, [:responses, :snapshot]))

    WorkLoop.run(@request, opts)
  end

  defp snapshot do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :observed,
          windows: [
            %{
              kind: "five_hour",
              state: :observed,
              used_percent: 10,
              reset_at: DateTime.add(@now, 3600)
            },
            %{
              kind: "weekly",
              state: :observed,
              used_percent: 10,
              reset_at: DateTime.add(@now, 86_400)
            }
          ],
          observed_at: @now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "planner.fixture",
            provider_id: "fixture",
            invocation_mode: "structured-planning",
            event: :explicit_read
          },
          scope: "planner:fixture",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: @now
      )

    snapshot
  end

  defp answer(text), do: send(self(), {:mix_shell_input, :prompt, text})

  # The loop's conversation goes to stderr (`error`).
  defp stderr_lines do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, :error, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  defp jobs, do: Repo.all(Oban.Job)

  test "approving the shown plan queues exactly that revision for the service", ctx do
    answer("y")
    assert {:ok, %{goal_id: goal_id, revision: 1, execution_id: execution_id}} = run(ctx)

    lines = stderr_lines()
    assert "Goal #{goal_id}" in lines
    assert Enum.any?(lines, &String.starts_with?(&1, "Plan revision 1"))
    assert "  1. add: Implement add" in lines
    assert "     Checks: python_unittest test/test_calc.py" in lines
    assert Enum.any?(lines, &String.contains?(&1, "queued for the service"))

    [revision] = Plans.list_revisions(goal_id)
    assert revision.status == "approved"
    assert revision.content["goal"]["statement"] == @request
    assert %Goal{status: "active", description: @request} = Repo.get!(Goal, goal_id)

    assert [%Oban.Job{worker: "Shoestring.Cobbler.PlanExecutionWorker", args: args}] = jobs()
    assert args["execution_id"] == execution_id
  end

  test "declining leaves the goal and draft recorded and queues nothing", ctx do
    answer("n")
    assert {:declined, goal_id} = run(ctx)
    assert [%{status: "proposed"}] = Plans.list_revisions(goal_id)
    assert jobs() == []
  end

  test "an edited plan becomes a new revision, and approval binds its digest", ctx do
    edit = fn path ->
      plan = path |> File.read!() |> Jason.decode!()
      [task] = plan["tasks"]

      File.write!(
        path,
        Jason.encode!(%{plan | "tasks" => [%{task | "title" => "Implement add simply"}]})
      )

      :submit
    end

    answer("e")
    answer("y")
    assert {:ok, %{goal_id: goal_id, revision: 2}} = run(ctx, edit: edit)

    [first, second] = Enum.sort_by(Plans.list_revisions(goal_id), & &1.revision_number)
    assert first.status == "proposed"
    assert second.status == "approved"
    assert second.parent_revision_number == 1
    assert hd(second.content["tasks"])["title"] == "Implement add simply"
    assert "  1. add: Implement add simply" in stderr_lines()
  end

  test "a held planning call runs only after the human confirms it", ctx do
    answer("n")
    assert {:error, :planning_not_confirmed} = run(ctx, snapshot: nil)
    refute_received {:planner_input, _}

    answer("y")
    answer("y")
    assert {:ok, %{revision: 1}} = run(ctx, snapshot: nil)
    assert Enum.any?(stderr_lines(), &String.starts_with?(&1, "Planning is held:"))
  end

  test "preflight refusals create no goal and queue nothing", ctx do
    File.write!(Path.join(ctx.repo, "calc.py"), "dirty\n")
    assert {:error, {:dirty_worktree, ["calc.py"]}} = run(ctx, responses: [])
    git!(ctx.repo, ["checkout", "--", "calc.py"])

    assert {:error, :service_unreachable} =
             run(ctx, service: fn -> {:error, :service_unreachable} end)

    assert {:error, :agent_not_found} = run(ctx, agent: "missing")

    bare = Path.join(System.tmp_dir!(), "shoestring-do-bare-#{Ecto.UUID.generate()}")
    File.mkdir_p!(bare)
    File.write!(Path.join(bare, "README.md"), "x\n")
    git!(bare, ["init", "-q", "-b", "main"])
    git!(bare, ["add", "."])
    git!(bare, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    assert {:error, :no_gate_detected} = run(ctx, repo: bare, responses: [])

    roles = fn coordinator, worker ->
      %{
        "roles" => [
          %{"name" => "Coordinator", "provider" => "claude", "model" => coordinator},
          %{"name" => "Worker", "provider" => "claude", "model" => worker}
        ]
      }
    end

    # No explicit planner and a Coordinator without an explicit Claude model.
    {:ok, agent} = AgentProfiles.update(ctx.agent, roles.("default", "opus"))
    assert {:error, :planner_not_configured} = run(ctx, planner_config: nil)

    # A Coordinator whose harness has no planner is named. Base (9a0f1af):
    # the generic `:planner_not_configured`.
    {:ok, agent} =
      AgentProfiles.update(agent, %{
        "roles" => [
          %{"name" => "Coordinator", "provider" => "codex", "model" => "default"},
          %{"name" => "Worker", "provider" => "claude", "model" => "opus"}
        ]
      })

    assert {:error, {:coordinator_cannot_plan, "codex"}} = run(ctx, planner_config: nil)

    {:ok, _} = AgentProfiles.update(agent, roles.("default", "default"))
    assert {:error, :worker_model_required} = run(ctx)
    assert Repo.aggregate(Goal.user_goals(), :count) == 0
    assert jobs() == []
  end

  test "the service check queues only into the database the running service uses" do
    check = fn status, body ->
      WorkLoop.check_service("http://service.test/health",
        plug: fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body) end
      )
    end

    same = Shoestring.Health.instance()
    assert :ok = check.(200, %{"ready" => true, "instance" => same})

    assert {:error, :service_uses_another_database} =
             check.(200, %{"ready" => true, "instance" => "0000000000000000"})

    assert {:error, {:service_not_ready, 503}} =
             check.(503, %{"ready" => false, "instance" => same})

    assert {:error, :service_too_old} = check.(200, %{"ready" => true})

    assert {:error, :service_unreachable} =
             WorkLoop.check_service("http://127.0.0.1:1/health")
  end
end
