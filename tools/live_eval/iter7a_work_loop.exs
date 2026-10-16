# Explicitly invoked verification of the iteration 7A CLI work loop, never part
# of the hermetic test gate. One boot runs the whole loop through the same
# modules `shoestring do`, `follow` and `result` use, inside a node that also
# runs the service's queues.
#
#   ITER7A_EVALUATION  disposable root; also SHOESTRING_STATE_DIR. The fixture
#                      lives in $ITER7A_EVALUATION/repos/source.
#   ITER7A_MODE        "rehearsal": fixture planner and Fake Elves, no provider
#                      call; "live": the agent's Claude Coordinator plans and
#                      sandboxed Claude Elves work (needs an authorized budget).
#
#     mix run --no-start tools/live_eval/iter7a_work_loop.exs run < /dev/null
#
# The terminal is a scripted shell that records the transcript. It confirms a
# held planning call and held task attempts, and approves a plan only when
# every task names only the fixture's files and the plan's budget is at most
# two attempts; otherwise it declines and nothing runs. The service check is
# not exercised (the service runs in this node). No raw provider frames,
# session/message identifiers, credentials or reasoning are exported.

defmodule Iter7aShell do
  @moduledoc false
  @allowed_files ["calc.py", "test/test_calc.py", "test/__init__.py"]
  @max_attempts 2

  def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def transcript, do: Agent.get(__MODULE__, &Enum.reverse/1)

  def info(line) do
    Agent.update(__MODULE__, &[{:info, line} | &1])
    IO.puts(line)
  end

  def error(line), do: info(line)

  def prompt(question) do
    answer = answer(question)
    Agent.update(__MODULE__, &[{:prompt, question, answer} | &1])
    IO.puts(question <> answer)
    answer
  end

  defp answer(question) do
    cond do
      question =~ "planning call" -> "y"
      question =~ "repair it once" -> "y"
      question =~ "Confirm capacity" -> "y"
      question =~ "Approve this plan" -> if acceptable_plan?(), do: "y", else: "n"
      true -> "q"
    end
  end

  # The plan printed most recently: every Files line within the fixture, and
  # a budget of at most two attempts.
  defp acceptable_plan? do
    lines =
      transcript()
      |> Enum.flat_map(fn
        {:info, line} -> [line]
        _ -> []
      end)
      |> Enum.reverse()
      |> Enum.take_while(&(not String.starts_with?(&1, "Plan revision")))

    files =
      for line <- lines,
          String.starts_with?(String.trim(line), "Files:"),
          file <-
            line |> String.trim() |> String.replace_prefix("Files: ", "") |> String.split(", "),
          do: file

    budget =
      Enum.find_value(lines, fn line ->
        case Regex.run(~r/Budget: (\d+) attempts/, line) do
          [_, n] -> String.to_integer(n)
          _ -> nil
        end
      end)

    Enum.all?(files, &(&1 in @allowed_files)) and is_integer(budget) and budget <= @max_attempts
  end
end

defmodule Iter7aWorkLoop do
  @moduledoc false
  import Ecto.Query

  alias Shoestring.{AgentProfiles, Repo}
  alias Shoestring.CLI.{Follow, Result, WorkLoop}
  alias Shoestring.Cobbler.{ExecutionControl, Intake}
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Trajectory.TrajectoryEvent

  @request "Make add(a, b) in calc.py return the sum of its arguments."
  @by "human:user"

  def mode, do: System.fetch_env!("ITER7A_MODE")
  def live?, do: mode() == "live"
  def root, do: System.fetch_env!("ITER7A_EVALUATION") |> Path.expand()
  def source, do: Path.join(root(), "repos/source")
  def local(name), do: Path.join([root(), "evidence", name])

  def boot do
    true = mode() in ["rehearsal", "live"]
    true = Path.expand(System.fetch_env!("SHOESTRING_STATE_DIR")) == root()
    false = File.exists?(local("result.json"))
    File.mkdir_p!(Path.join(root(), "evidence"))
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :none)

    Application.put_env(:shoestring, :capacity_monitors,
      claude: [enabled: true, auto_ingest_initial: true],
      codex: [enabled: false]
    )

    # Live Elves use the product default (sandboxed plan runs); the rehearsal
    # replaces the adapter with Fake, which changes no files.
    unless live?() do
      Application.put_env(:shoestring, :elf_dispatch_opts,
        adapter: Shoestring.Harness.Fake,
        process_owner: :runner,
        adapter_opts: %{
          scenario: Shoestring.Harness.Fake.Scenario.normal_completion(now: DateTime.utc_now())
        },
        command: ["sleep", "30"]
      )
    end

    config = Application.fetch_env!(:shoestring, Oban)

    Application.put_env(
      :shoestring,
      Oban,
      config
      |> Keyword.put(:plugins, [])
      |> Keyword.put(:queues,
        dispatch: [limit: 2],
        plan_execution: [limit: 1],
        plan_child_inbox: [limit: 2],
        reservation_control: [limit: 1],
        plan_cancellation: [limit: 1],
        wakeup: [limit: 2],
        handoff: [limit: 2]
      )
    )

    Shoestring.CLI.Repository.with_repo(fn _ -> :ok end)
    {:ok, _} = Application.ensure_all_started(:shoestring)
    {:ok, _} = Iter7aShell.start()
  end

  def record(name, value) do
    File.write!(local(name <> ".json"), redact(Jason.encode!(value, pretty: true)))
  end

  def redact(text) do
    text
    |> String.replace(root(), "$EVALUATION")
    |> String.replace(Path.expand("~"), "$USER_HOME")
  end

  # -- Fixture ---------------------------------------------------------------

  @test """
  import unittest

  from calc import add


  class AddTest(unittest.TestCase):
      def test_small(self):
          self.assertEqual(add(2, 3), 5)

      def test_negative(self):
          self.assertEqual(add(-4, 1), -3)


  if __name__ == "__main__":
      unittest.main()
  """

  def fixture! do
    false = File.exists?(source())
    File.mkdir_p!(Path.join(source(), "test"))

    # The rehearsal starts from a passing implementation (Fake changes nothing).
    body = if live?(), do: "    raise NotImplementedError\n", else: "    return a + b\n"

    File.write!(
      Path.join(source(), "calc.py"),
      "def add(a, b):\n    \"\"\"Return a + b.\"\"\"\n" <> body
    )

    File.write!(Path.join(source(), "test/__init__.py"), "")
    File.write!(Path.join(source(), "test/test_calc.py"), @test)

    git!(source(), ["init", "-q", "-b", "main"])
    git!(source(), ["config", "user.name", "Fixture"])
    git!(source(), ["config", "user.email", "fixture@example.test"])
    git!(source(), ["add", "."])
    git!(source(), ["-c", "commit.gpgsign=false", "commit", "-qm", "Fixture base"])
    String.trim(git!(source(), ["rev-parse", "HEAD"]))
  end

  def git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    output
  end

  # -- Configuration (what `shoestring models add` and `agents create` do) ---

  def configure! do
    settings = AgentProfiles.settings()
    {:ok, _} = AgentProfiles.save_settings(settings, %{"claude_models" => "default\nopus"})

    {:ok, agent} =
      AgentProfiles.create(%{
        "name" => "builder",
        "slug" => "builder",
        "purpose" => "Carry out approved plan tasks.",
        "instructions" =>
          "Complete the task within its stated scope and acceptance gates. Commit the result.",
        "roles" => [
          %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
          %{"name" => "Worker", "provider" => "claude", "model" => "opus"}
        ]
      })

    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{"default_agent_id" => agent.id})

    agent.id
  end

  defp rehearsal_planner(base) do
    {:ok, facts} = Intake.repository(source())
    {:ok, gates} = Intake.gates(facts)
    {:ok, contract} = Intake.goal_contract(@request, facts, gates)
    true = contract["repository"]["base_revision"] == base

    plan = %{
      "version" => 1,
      "goal" => contract,
      "budget" => %{"max_total_attempts" => 2, "max_total_duration_seconds" => 900},
      "tasks" => [
        %{
          "id" => "add",
          "title" => "Implement add",
          "outcome" => "add(a, b) returns a + b.",
          "depends_on" => [],
          "inputs" => ["calc.py raises NotImplementedError.", "test/test_calc.py specifies it."],
          "expected_artifacts" => ["Updated calc.py."],
          "hints" => %{"files" => ["calc.py"], "symbols" => ["add"]},
          "acceptance_criteria" => ["Change only calc.py.", "Preserve the add(a, b) signature."],
          "gates" => gates,
          "checkpoint" => %{
            "condition" => "test/test_calc.py passes.",
            "evidence" => ["test/test_calc.py passes."]
          },
          "risks" => ["Editing the test would hide a wrong implementation."],
          "execution" => %{"max_attempts" => 1, "max_duration_seconds" => 300}
        }
      ]
    }

    [adapter: :fixture, model: "fixture-v1", responses: [{:ok, Jason.encode!(plan), 120}]]
  end

  # -- The loop --------------------------------------------------------------

  def run! do
    base = fixture!()
    agent_id = configure!()
    source_before = source_state()

    loop_opts =
      [repo: source(), by: @by, shell: Iter7aShell, service: fn -> :ok end]
      |> then(
        &if live?(), do: &1, else: Keyword.put(&1, :planner_config, rehearsal_planner(base))
      )

    started = System.monotonic_time(:millisecond)
    outcome = WorkLoop.run(@request, loop_opts)

    {followed, result} =
      case outcome do
        {:ok, %{goal_id: goal_id}} ->
          followed =
            Follow.run(goal_id,
              by: @by,
              shell: Iter7aShell,
              interval_ms: 1_000,
              max_polls: 900,
              from_execution: true
            )

          result =
            case followed do
              {:ok, :completed} -> Result.show(goal_id, shell: Iter7aShell)
              other -> other
            end

          {followed, result}

        other ->
          {other, nil}
      end

    elapsed = System.monotonic_time(:millisecond) - started
    goal_id = goal_id(outcome)
    source_after = source_state()

    merge =
      case result do
        {:ok, %{commit: commit, worktree: worktree}} -> merge_in_clone!(worktree, commit)
        _ -> nil
      end

    summary = %{
      mode: mode(),
      base: base,
      agent_id: agent_id,
      outcome: inspect(outcome),
      followed: inspect(followed),
      result: if(match?({:ok, _}, result), do: elem(result, 1), else: inspect(result)),
      source_unchanged: source_before == source_after,
      merge_in_clone: merge,
      elapsed_ms: elapsed,
      runs: if(goal_id, do: run_count(goal_id), else: 0),
      planner_attempts: if(goal_id, do: planner_attempts(goal_id), else: 0),
      final_status: if(goal_id, do: final_status(goal_id))
    }

    record("transcript", Iter7aShell.transcript() |> Enum.map(&Tuple.to_list/1))
    if goal_id, do: export!(goal_id)
    record("result", summary)

    IO.puts(
      redact(Jason.encode!(%{phase: "result", summary: Map.drop(summary, [:final_status])}))
    )
  end

  defp goal_id({:ok, %{goal_id: id}}), do: id
  defp goal_id({:declined, id}), do: id

  defp goal_id(_) do
    Repo.one(
      from g in Shoestring.Trajectory.Goal.user_goals(),
        order_by: [desc: g.inserted_at],
        limit: 1,
        select: g.id
    )
  end

  defp source_state do
    %{
      head: String.trim(git!(source(), ["rev-parse", "HEAD"])),
      status: git!(source(), ["status", "--porcelain"])
    }
  end

  # The human step `result` prints, done in a disposable clone of the fixture.
  defp merge_in_clone!(worktree, commit) do
    clone = Path.join(root(), "repos/taken")
    {_, 0} = System.cmd("git", ["clone", "-q", source(), clone], stderr_to_stdout: true)
    git!(clone, ["config", "user.name", "Fixture"])
    git!(clone, ["config", "user.email", "fixture@example.test"])
    git!(clone, ["fetch", "-q", worktree, commit])
    git!(clone, ["-c", "commit.gpgsign=false", "merge", "-q", "--no-edit", "FETCH_HEAD"])

    {output, status} =
      System.cmd("python3", ["-B", "-m", "unittest", "test/test_calc.py"],
        cd: clone,
        stderr_to_stdout: true
      )

    %{
      head: String.trim(git!(clone, ["rev-parse", "HEAD"])),
      tests_exit: status,
      tests_tail: output |> String.split("\n", trim: true) |> List.last()
    }
  end

  defp run_count(goal_id),
    do: Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal_id), :count)

  defp planner_attempts(goal_id) do
    case Shoestring.Cobbler.Planner.get(goal_id) do
      nil -> 0
      row -> row.attempts
    end
  end

  defp final_status(goal_id) do
    {:ok, status} = ExecutionControl.status(goal_id)

    Map.take(status, [:completed?, :accepted, :total_attempts, :needs_user?, :cancelled?])
  end

  # -- Export (selected canonical facts only) --------------------------------

  @domain ~w(
    cobbler.planner.requested cobbler.planner.blocked cobbler.planner.attempt.started
    cobbler.planner.attempt.finished cobbler.plan.revision.created cobbler.plan.approved
    cobbler.plan.execution.requested cobbler.plan.capacity.confirmed admission.decided
    cobbler.plan.task.dispatched cobbler.plan.task.accepted cobbler.plan.task.gate_failed
    cobbler.plan.task.scope_blocked cobbler.plan.execution.completed
    run.running run.completed run.failed run.cancelled run.interrupted
  )

  def export!(goal_id) do
    events =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type in ^@domain,
          order_by: e.sequence,
          select: %{
            sequence: e.sequence,
            type: e.type,
            occurred_at: e.occurred_at,
            payload: e.payload
          }
      )
      |> Enum.map(fn event ->
        if String.starts_with?(event.type, "run."),
          do:
            Map.put(
              event,
              :payload,
              Map.take(event.payload, ["run_id", "error_category", "error_code"])
            ),
          else: event
      end)

    harness =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type == "harness.event_recorded",
          order_by: e.sequence,
          select: e.payload
      )

    extensions = Enum.map(harness, &(&1["extensions"] || %{}))

    runtime =
      for ext <- extensions, ext["claude-headless:subtype"] == "init" do
        %{
          model: ext["claude-headless:model"],
          cli_version: ext["claude-headless:claude_code_version"],
          permission_mode: ext["claude-headless:permission_mode"],
          tools: ext["claude-headless:tools"]
        }
      end

    commands =
      for ext <- extensions, ext["claude-headless:boundary"] in ["start", "end"] do
        %{
          boundary: ext["claude-headless:boundary"],
          command: ext["claude-headless:command"],
          status: ext["claude-headless:status"],
          is_error: ext["claude-headless:is_error"]
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
      end

    outputs =
      for ext <- extensions, text = ext["claude-headless:output_text"], is_binary(text), do: text

    usage_keys =
      ~w(five_hour_utilization seven_day_utilization rate_limit_status total_cost_usd duration_ms num_turns terminal_reason)

    usage =
      for ext <- extensions,
          values =
            Map.new(usage_keys, &{&1, ext["claude-headless:" <> &1]})
            |> Map.reject(fn {_k, v} -> is_nil(v) end),
          values != %{},
          do: values

    record("domain-events", events)
    record("runtime", runtime)
    record("commands", commands)
    record("public-agent-messages", outputs)
    record("provider-usage", usage)
  end
end

Iter7aWorkLoop.boot()

case System.argv() do
  ["run"] -> Iter7aWorkLoop.run!()
  _ -> raise "usage: iter7a_work_loop.exs run"
end
