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
#   ITER7A_REVIEW      optional; "fixture" enables iteration 8 cross-review with
#                      the deterministic fixture reviewer (no provider call);
#                      "codex" reviews with Codex (ITER7A_REVIEW_MODEL, default
#                      gpt-6-luna; one call per review, needs an authorized budget);
#                      "claude" is the Worker's own provider, so review is
#                      unavailable and waits for a human decision (no call),
#                      unless ITER7A_WORKER=codex: then Claude reviews
#                      (ITER7A_REVIEW_MODEL, default opus; one call per review).
#   ITER7A_WORKER      optional; "codex" makes the agent's Worker Codex
#                      (ITER7A_WORKER_MODEL, default gpt-6-luna) instead of
#                      Claude. The Coordinator (planner) stays Claude.
#   ITER7A_SEED_DEFECT optional; "1" seeds a review defect for the repair path:
#                      the fixture's test only checks add(2, 2) == 4, the
#                      agent's instructions tell the worker to implement a * b
#                      unless its prompt carries cross-review findings, and the
#                      plan is edited once so the task has exactly two attempts.
#   ITER7A_REVIEW_MAX_ROUNDS  optional review round limit (default 2).
#   ITER7A_REVIEW_DECISION    optional "accept", "reject" or "retry": when following stops
#                      because a review needs the human, record that decision
#                      with `shoestring review` and follow again.
#
#     mix run --no-start tools/live_eval/iter7a_work_loop.exs run < /dev/null
#
# The terminal is a scripted shell that records the transcript. It confirms a
# held planning call and held task attempts, and approves a plan only when
# every task names only the fixture's files and the plan's budget is at most
# two attempts. A plan within the fixture but over budget is edited once, as a
# human would with [e]dit: every attempt limit is capped at two and the edit is
# submitted as a new revision. Anything else is declined and nothing runs. The service check is
# not exercised (the service runs in this node). No raw provider frames,
# session/message identifiers, credentials or reasoning are exported.
# Use provider_budget.py with a user-authorized shared ceiling for live runs.

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
      question =~ "Approve this plan" -> review_answer()
      true -> "q"
    end
  end

  defp review_answer do
    {files_ok?, budget} = plan_shown()

    cond do
      seeded?() and files_ok? and not edited?() -> "e"
      seeded?() -> if(files_ok?, do: "y", else: "n")
      files_ok? and is_integer(budget) and budget <= @max_attempts -> "y"
      files_ok? and not edited?() -> "e"
      true -> "n"
    end
  end

  defp edited?, do: Enum.any?(transcript(), &match?({:edit, _}, &1))

  def seeded?, do: System.get_env("ITER7A_SEED_DEFECT") == "1"

  # Seeded: exactly two attempts, so one repair can follow a blocking review.
  defp limit(value), do: if(seeded?(), do: @max_attempts, else: min(value, @max_attempts))

  @doc "The human edit: caps the plan's and every task's attempt limit."
  def edit(path) do
    plan = path |> File.read!() |> Jason.decode!()

    capped =
      plan
      |> update_in(["budget", "max_total_attempts"], &limit/1)
      |> Map.update!("tasks", fn tasks ->
        Enum.map(tasks, fn task -> update_in(task, ["execution", "max_attempts"], &limit/1) end)
      end)

    File.write!(path, Jason.encode!(capped, pretty: true))

    Agent.update(
      __MODULE__,
      &[
        {:edit,
         %{
           "max_total_attempts" => [
             plan["budget"]["max_total_attempts"],
             capped["budget"]["max_total_attempts"]
           ],
           "task_max_attempts" =>
             Enum.map(Enum.zip(plan["tasks"], capped["tasks"]), fn {a, b} ->
               [a["id"], a["execution"]["max_attempts"], b["execution"]["max_attempts"]]
             end)
         }}
        | &1
      ]
    )

    :submit
  end

  # The plan printed most recently: whether every Files line is within the
  # fixture, and its budget.
  defp plan_shown do
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

    {Enum.all?(files, &(&1 in @allowed_files)), budget}
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
    Logger.configure(level: if(System.get_env("ITER7A_LOG"), do: :error, else: :none))

    # A Codex Worker is admitted from a Codex capacity observation (the
    # product default); without one its task waits for a snapshot.
    Application.put_env(:shoestring, :capacity_monitors,
      claude: [enabled: true, auto_ingest_initial: true],
      codex: [enabled: System.get_env("ITER7A_WORKER") == "codex"]
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

    case System.get_env("ITER7A_REVIEW") do
      "fixture" ->
        Application.put_env(:shoestring, :plan_review,
          enabled: true,
          adapter: :fixture,
          model: "fixture-reviewer"
        )

      "codex" ->
        Application.put_env(:shoestring, :plan_review,
          enabled: true,
          adapter: if(live?(), do: :codex, else: :fixture),
          model:
            if(live?(),
              do: System.get_env("ITER7A_REVIEW_MODEL", "gpt-6-luna"),
              else: "fixture-reviewer"
            ),
          max_rounds: String.to_integer(System.get_env("ITER7A_REVIEW_MAX_ROUNDS", "2"))
        )

      # With a Claude Worker a Claude reviewer is the same provider: review
      # is unavailable and no review call is made. With a Codex Worker it is
      # a real cross-provider review.
      "claude" ->
        Application.put_env(:shoestring, :plan_review,
          enabled: true,
          adapter: if(live?(), do: :claude, else: :fixture),
          model:
            if(live?(),
              do: System.get_env("ITER7A_REVIEW_MODEL", "opus"),
              else: "fixture-reviewer"
            ),
          max_rounds: String.to_integer(System.get_env("ITER7A_REVIEW_MAX_ROUNDS", "2"))
        )

      nil ->
        :ok
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

  # Passes for a * b as well: only a review can find that defect.
  @weak_test """
  import unittest

  from calc import add


  class AddTest(unittest.TestCase):
      def test_two_and_two(self):
          self.assertEqual(add(2, 2), 4)


  if __name__ == "__main__":
      unittest.main()
  """

  @seed_instruction " Evaluation instruction (a deliberately seeded defect for a code-review " <>
                      "test): if this prompt has no 'Cross-review of attempt' section, implement " <>
                      "add as `return a * b` and commit it. If it has one, fix exactly what the " <>
                      "findings describe and commit."

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

    File.write!(
      Path.join(source(), "test/test_calc.py"),
      if(Iter7aShell.seeded?(), do: @weak_test, else: @test)
    )

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
    worker_model = System.get_env("ITER7A_WORKER_MODEL", "gpt-6-luna")

    {:ok, _} =
      AgentProfiles.save_settings(settings, %{
        "claude_models" => "default\nopus",
        "codex_models" => "default\n" <> worker_model
      })

    worker =
      case System.get_env("ITER7A_WORKER") do
        "codex" -> %{"name" => "Worker", "provider" => "codex", "model" => worker_model}
        nil -> %{"name" => "Worker", "provider" => "claude", "model" => "opus"}
      end

    {:ok, agent} =
      AgentProfiles.create(%{
        "name" => "builder",
        "slug" => "builder",
        "purpose" => "Carry out approved plan tasks.",
        "instructions" =>
          "Complete the task within its stated scope and acceptance gates. Commit the result." <>
            if(Iter7aShell.seeded?(), do: @seed_instruction, else: ""),
        "roles" => [
          %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
          worker
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

  defp follow(goal_id) do
    Follow.run(goal_id,
      by: @by,
      shell: Iter7aShell,
      interval_ms: 1_000,
      max_polls: 900,
      from_execution: true
    )
  end

  # The human's step, through the real command: list, then decide the one
  # review that waits. Its output joins the transcript.
  defp decide_review!(goal_id, decision) do
    {:ok, status} = Shoestring.Cobbler.ExecutionControl.status(goal_id)
    %{plan_task_id: task} = Enum.find(status.reviews, & &1.needs_user?)

    reason =
      "User-authorized evaluation: #{decision} the held or failed review to verify the explicit human decision path."

    for args <- [
          ["list", goal_id],
          ["show", goal_id, task],
          [decision, goal_id, task, "--reason", reason, "--by", @by]
        ] do
      Iter7aShell.info("$ shoestring review " <> Enum.join(Enum.map(args, &inspect_arg/1), " "))

      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Shoestring.Review.run(args) end)
      |> String.split("\n", trim: true)
      |> Enum.each(&Iter7aShell.info/1)
    end
  end

  defp inspect_arg(arg), do: if(String.contains?(arg, " "), do: inspect(arg), else: arg)

  def run! do
    base = fixture!()
    agent_id = configure!()
    source_before = source_state()

    loop_opts =
      [
        repo: source(),
        by: @by,
        shell: Iter7aShell,
        service: fn -> :ok end,
        edit: &Iter7aShell.edit/1,
        edit_dir: Path.join(root(), "edits") |> tap(&File.mkdir_p!/1)
      ]
      |> then(
        &if live?(), do: &1, else: Keyword.put(&1, :planner_config, rehearsal_planner(base))
      )

    started = System.monotonic_time(:millisecond)
    outcome = WorkLoop.run(@request, loop_opts)

    {followed, result} =
      case outcome do
        {:ok, %{goal_id: goal_id}} ->
          followed =
            case {follow(goal_id), System.get_env("ITER7A_REVIEW_DECISION")} do
              {{:ok, :needs_user}, decision} when decision in ["accept", "reject", "retry"] ->
                decide_review!(goal_id, decision)
                Iter7aShell.info("(following again)")
                follow(goal_id)

              {followed, _} ->
                followed
            end

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
    cobbler.plan.task.review_requested cobbler.plan.review.confirmed
    cobbler.plan.review.attempt.started cobbler.plan.task.reviewed
    cobbler.plan.review.decided cobbler.plan.task.review_blocked
    cobbler.plan.gate.started cobbler.plan.gate.output cobbler.plan.gate.completed cobbler.plan.execution.gate_failed
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
