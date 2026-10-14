defmodule Shoestring.Test.PlanFanoutHelpers do
  @moduledoc "Hermetic local Git and Fake admission fixtures for sibling coordination."
  import ExUnit.Assertions
  alias Shoestring.Cobbler.PlanExecutor
  alias Shoestring.Harness.Fake
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers, PlanFixtures, PlanHandoffClock}
  alias Shoestring.Test.Fixtures.FakeHelpers

  def fixture(overrides \\ []) do
    root = Path.join(System.tmp_dir!(), "shoestring-fanout-#{Ecto.UUID.generate()}")
    source = Path.join(root, "source")
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, ".formatter.exs"), "[inputs: [\"lib/**/*.ex\"]]\n")

    for name <- ~w(north south join) do
      File.write!(
        Path.join(source, "lib/#{name}.ex"),
        "defmodule #{String.capitalize(name)} do\nend\n"
      )
    end

    git!(source, ["init"])
    git!(source, ["config", "user.name", "Fixture"])
    git!(source, ["config", "user.email", "fixture@example.invalid"])
    git!(source, ["add", "."])
    git!(source, ["commit", "-m", "Fan-out fixture base"])
    base = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
    gate = %{"gate" => "mix_format_check"}
    seconds = Keyword.get(overrides, :task_seconds, 600)

    tasks =
      for {name, deps} <- [{"north", []}, {"south", []}, {"join", ["north", "south"]}] do
        PlanFixtures.task(name, "Implement #{name}", deps, %{
          "gates" => [gate],
          "hints" => %{"files" => ["lib/#{name}.ex"], "symbols" => []},
          "execution" => %{"max_attempts" => 2, "max_duration_seconds" => seconds}
        })
      end

    tasks = if Keyword.get(overrides, :independent_only), do: Enum.take(tasks, 2), else: tasks
    tasks = Keyword.get(overrides, :transform_tasks, &Function.identity/1).(tasks)

    plan =
      PlanExecutorHelpers.chain_plan(%{
        "goal" =>
          PlanFixtures.goal(%{
            "repository" => %{"base_revision" => base},
            "acceptance" => %{"gates" => [gate], "evidence" => ["Format passes."]}
          }),
        "budget" => %{
          "max_total_attempts" => 6,
          "max_total_duration_seconds" => Keyword.get(overrides, :goal_seconds, 3600)
        },
        "tasks" => tasks
      })

    goal = CobblerHelpers.create_goal!()
    revision = PlanExecutorHelpers.propose_and_approve!(goal, plan)
    admission = admission!(goal)

    opts = [
      now: PlanExecutorHelpers.now(),
      clock: PlanHandoffClock,
      repository_path: source,
      worktrees_dir: Keyword.get(overrides, :worktrees_dir, Path.join(root, "worktrees")),
      fanout_enabled: true,
      reservation_policy: %{
        global_limit: 2,
        provider_account_limit: 2,
        goal_limit: 2,
        account_units: 2
      },
      admission_fun: fn _, _, _, _ -> {:ok, admission!(goal).id} end
    ]

    assert {:ok, %{execution: execution}} =
             PlanExecutor.request_execution(
               goal.id,
               Map.put(revision, :admission_event_id, admission.id),
               opts
             )

    %{
      goal: goal,
      revision: revision,
      execution: execution,
      root: root,
      source: source,
      base: base,
      plan: plan,
      opts: opts
    }
  end

  def admission!(goal, changes \\ %{}) do
    now = PlanExecutorHelpers.now()
    snapshot = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot)

    payload =
      CobblerHelpers.admission_payload(
        provider_id: "fake",
        adapter_id: Fake.identity().adapter_id
      )
      |> Map.merge(%{
        "evaluated_at" => DateTime.to_iso8601(now),
        "observation" => %{
          "snapshot_id" => snapshot,
          "confidence" => "high",
          "freshness" => "fresh"
        },
        "proposed_bounds" => %{
          "response_budget" => 10,
          "tool_budget" => 25,
          "checkpoint_cadence" => 1,
          "reserves" => %{"response" => 1, "tool" => 1},
          "deadline" => DateTime.to_iso8601(DateTime.add(now, 300))
        }
      })
      |> Map.merge(changes)

    CobblerHelpers.append_admission_event!(goal.id, payload)
  end

  def git!(path, args) do
    {output, status} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
