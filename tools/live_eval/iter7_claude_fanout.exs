# Explicitly invoked live verification, never part of the hermetic test gate.
#
# Runs one approved three-task plan (north and south independent, join after
# both) through the production plan worker with fan-out enabled only in this
# disposable node. Every phase is a separate boot of the same state directory.
#
#   ITER7_EVALUATION  disposable root; also SHOESTRING_STATE_DIR. Worktrees
#                     live in $ITER7_EVALUATION/worktrees, the fixture in
#                     $ITER7_EVALUATION/repos/source.
#   ITER7_MODE        "rehearsal" (Fake adapter, no provider call) or "live"
#                     (Claude Code through the reviewed fixture launcher).
#   ITER6_REPOSITORY  the fixture source; the shared launcher denies writes to it.
#
# Phases: preflight, setup, fanout, integrate, join, export. No raw provider
# frames, session/message identifiers, credentials or reasoning are exported.

defmodule Iter7ClaudeFanout do
  import Ecto.Query
  alias Shoestring.{AgentProfiles, Cobbler, Repo, Worktrees}
  alias Shoestring.Cobbler.{ExecutionControl, PlanContract, Reservations}
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Harness.Capacity.ClaudeMonitor
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

  @policy %{
    global_limit: 2,
    provider_account_limit: 2,
    goal_limit: 2,
    account_units: 2,
    task_units: 1
  }
  @task_seconds 300
  @goal_seconds 1500
  @phase_seconds 420

  def mode, do: System.fetch_env!("ITER7_MODE")
  def live?, do: mode() == "live"
  def root, do: System.fetch_env!("ITER7_EVALUATION") |> Path.expand()
  def source, do: Path.join(root(), "repos/source")
  def local(name), do: Path.join([root(), "evidence", name])

  def boot do
    true = mode() in ["rehearsal", "live"]
    true = Path.expand(System.fetch_env!("SHOESTRING_STATE_DIR")) == root()
    true = Path.expand(System.fetch_env!("ITER6_REPOSITORY")) == source()
    File.mkdir_p!(Path.join(root(), "evidence"))
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :none)

    Application.put_env(:shoestring, :capacity_monitors,
      claude: [enabled: true, auto_ingest_initial: true],
      codex: [enabled: false]
    )

    Application.put_env(:shoestring, :plan_fanout, enabled: true)
    Application.put_env(:shoestring, :plan_reservation_policy, @policy)

    elf =
      if live?() do
        [
          adapter_opts: %{
            live: true,
            permission_bypass: false,
            tools: "Bash",
            command: Path.expand("tools/live_eval/claude_fixture_launcher.py"),
            env: [{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}]
          }
        ]
      else
        [
          adapter: Shoestring.Harness.Fake,
          process_owner: :runner,
          adapter_opts: %{
            scenario: Shoestring.Harness.Fake.Scenario.normal_completion(now: DateTime.utc_now())
          },
          command: ["sleep", "30"]
        ]
      end

    Application.put_env(:shoestring, :elf_dispatch_opts, elf)

    config = Application.fetch_env!(:shoestring, Oban)

    Application.put_env(
      :shoestring,
      Oban,
      config
      |> Keyword.put(:plugins, [])
      |> Keyword.put(:queues,
        dispatch: [limit: 5, paused: true],
        plan_execution: [limit: 1, paused: true],
        plan_child_inbox: [limit: 2, paused: true],
        reservation_control: [limit: 1, paused: true],
        plan_cancellation: [limit: 1, paused: true],
        wakeup: [limit: 5, paused: true],
        handoff: [limit: 5, paused: true]
      )
    )

    Shoestring.CLI.Repository.with_repo(fn _ -> :ok end)
    {:ok, _} = Application.ensure_all_started(:shoestring)
  end

  def record(name, value) do
    path =
      Stream.iterate(1, &(&1 + 1))
      |> Enum.find_value(fn index ->
        suffix = if index == 1, do: "", else: "-#{index}"
        path = local(name <> suffix <> ".json")
        if not File.exists?(path), do: path
      end)

    File.write!(path, Jason.encode!(value, pretty: true))
    IO.puts(Jason.encode!(%{phase: name, result: value}))
  end

  def wait!(fun, seconds) do
    deadline = System.monotonic_time(:millisecond) + seconds * 1000
    wait_loop(fun, deadline)
  end

  defp wait_loop(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :pending ->
        if System.monotonic_time(:millisecond) >= deadline, do: raise("verification_deadline")

        receive do
        after
          200 -> wait_loop(fun, deadline)
        end
    end
  end

  def capacity! do
    wait!(
      fn ->
        state = ClaudeMonitor.status()
        if state.version && state.sink_status == :ok, do: {:ok, :ready}, else: :pending
      end,
      40
    )

    {:ok, snapshot} =
      Shoestring.Cobbler.WakeupObserve.observe(%{provider_id: "claude", scope: "subscription"})

    %{
      version: ClaudeMonitor.status().version,
      capacity_state: snapshot.capacity_state,
      compatibility_state: snapshot.compatibility_state,
      support_tier: snapshot.support_tier,
      confidence: snapshot.confidence,
      scope: snapshot.scope,
      windows:
        Enum.map(snapshot.windows, &Map.take(&1, [:kind, :state, :used_percent, :reset_at]))
    }
  end

  def confirm!(identity, execution_id, task_id) do
    {:ok, event} =
      ExecutionControl.confirm_capacity(identity["goal_id"], %{
        execution_id: execution_id,
        task_id: task_id,
        attempt: 1,
        scope: "subscription",
        command_id: Ecto.UUID.generate(),
        requested_by: "human:user"
      })

    record("capacity-confirmation-#{task_id}", %{event_id: event.id, payload: event.payload})
  end

  ## Fixture and plan

  @fixture %{
    "north.py" => """
    def north_total(items):
        \"\"\"Return the total quantity across items.\"\"\"
        raise NotImplementedError
    """,
    "south.py" => """
    def south_label(name):
        \"\"\"Return the display label for an item name.\"\"\"
        raise NotImplementedError
    """,
    "join.py" => """
    from north import north_total
    from south import south_label


    def summary(name, items):
        \"\"\"Return the one-line order summary.\"\"\"
        raise NotImplementedError
    """,
    "test/__init__.py" => "",
    "test/test_north.py" => """
    import unittest

    from north import north_total


    class NorthTest(unittest.TestCase):
        def test_empty(self):
            self.assertEqual(north_total([]), 0)

        def test_sums_quantities(self):
            items = [{"quantity": 2}, {"quantity": 3}, {"quantity": 0}]
            self.assertEqual(north_total(items), 5)


    if __name__ == "__main__":
        unittest.main()
    """,
    "test/test_south.py" => """
    import unittest

    from south import south_label


    class SouthTest(unittest.TestCase):
        def test_trims_and_upper_cases(self):
            self.assertEqual(south_label("  oat milk "), "Item: OAT MILK")

        def test_empty_name(self):
            self.assertEqual(south_label("   "), "Item: (unnamed)")


    if __name__ == "__main__":
        unittest.main()
    """,
    "test/test_join.py" => """
    import unittest

    from join import summary


    class JoinTest(unittest.TestCase):
        def test_summary(self):
            items = [{"quantity": 2}, {"quantity": 1}]
            self.assertEqual(summary(" tea ", items), "Item: TEA x3")

        def test_empty_order(self):
            self.assertEqual(summary("", []), "Item: (unnamed) x0")


    if __name__ == "__main__":
        unittest.main()
    """
  }

  # The rehearsal starts from passing implementations because the Fake
  # adapter changes no files; the live fixture starts from failing stubs.
  @rehearsal %{
    "north.py" => """
    def north_total(items):
        \"\"\"Return the total quantity across items.\"\"\"
        return sum(item["quantity"] for item in items)
    """,
    "south.py" => """
    def south_label(name):
        \"\"\"Return the display label for an item name.\"\"\"
        name = name.strip().upper()
        return "Item: " + (name or "(unnamed)")
    """,
    "join.py" => """
    from north import north_total
    from south import south_label


    def summary(name, items):
        \"\"\"Return the one-line order summary.\"\"\"
        return f"{south_label(name)} x{north_total(items)}"
    """
  }

  def fixture! do
    false = File.exists?(source())
    File.mkdir_p!(Path.join(source(), "test"))
    files = if live?(), do: @fixture, else: Map.merge(@fixture, @rehearsal)

    for {path, content} <- files, do: File.write!(Path.join(source(), path), content)

    git!(source(), ["init", "-q", "-b", "main"])
    git!(source(), ["config", "user.name", "Fixture"])
    git!(source(), ["config", "user.email", "fixture@example.invalid"])
    git!(source(), ["add", "."])
    git!(source(), ["commit", "-q", "-m", "Fan-out fixture base"])
    git!(source(), ["rev-parse", "HEAD"]) |> String.trim()
  end

  def task(id, title, deps, files, symbols, test, outcome, criteria) do
    %{
      "id" => id,
      "title" => title,
      "outcome" => outcome,
      "depends_on" => deps,
      "inputs" => ["#{hd(files)} currently raises NotImplementedError.", "#{test} specifies it."],
      "acceptance_criteria" => criteria,
      "expected_artifacts" => ["Updated #{hd(files)}."],
      "checkpoint" => %{
        "condition" => "#{test} passes.",
        "evidence" => ["#{test} passes."]
      },
      "risks" => ["Changing other files would break the declared independent scope."],
      "hints" => %{"files" => files, "symbols" => symbols},
      "gates" => [%{"gate" => "python_unittest", "test_paths" => [test]}],
      "execution" => %{"max_attempts" => 1, "max_duration_seconds" => @task_seconds}
    }
  end

  def plan(base) do
    %{
      "version" => 1,
      "goal" => %{
        "statement" =>
          "Implement north_total and south_label independently, then summary from both.",
        "repository" => %{"base_revision" => base},
        "constraints" => [
          "Each task changes only its own module; never edit tests.",
          "Use only the Python standard library; no network or packages."
        ],
        "non_goals" => ["Persistence, UI, packaging and changes to other modules."],
        "acceptance" => %{
          "gates" => [
            %{
              "gate" => "python_unittest",
              "test_paths" => ["test/test_north.py", "test/test_south.py", "test/test_join.py"]
            }
          ],
          "evidence" => ["All three named test files pass at the integrated commit."]
        }
      },
      "budget" => %{"max_total_attempts" => 3, "max_total_duration_seconds" => @goal_seconds},
      "tasks" => [
        task(
          "north",
          "Total item quantities",
          [],
          ["north.py", "test/test_north.py"],
          ["north_total"],
          "test/test_north.py",
          "north_total(items) returns the sum of each item's quantity, 0 when empty.",
          ["Preserve the north_total(items) signature.", "Change only north.py."]
        ),
        task(
          "south",
          "Render item labels",
          [],
          ["south.py", "test/test_south.py"],
          ["south_label"],
          "test/test_south.py",
          "south_label(name) returns Item: plus the trimmed upper-case name, or (unnamed).",
          ["Preserve the south_label(name) signature.", "Change only south.py."]
        ),
        task(
          "join",
          "Summarize an order",
          ["north", "south"],
          ["join.py", "test/test_join.py"],
          ["summary"],
          "test/test_join.py",
          "summary(name, items) returns south_label(name) followed by x and north_total(items).",
          [
            "Preserve the summary(name, items) signature.",
            "Use north_total and south_label.",
            "Change only join.py."
          ]
        )
      ]
    }
  end

  def setup! do
    false = File.exists?(local("identity.json"))
    base = fixture!()
    plan = plan(base)
    {:ok, contract} = PlanContract.new(plan)
    File.write!(local("bound-plan.json"), Jason.encode!(plan, pretty: true))

    {:ok, goal} =
      %Goal{}
      |> Goal.create_changeset(Ecto.UUID.generate(), %{
        title: "Iteration 7 #{mode()} fan-out",
        description: plan["goal"]["statement"]
      })
      |> Repo.insert()

    {:ok, %{revision: revision}} =
      Cobbler.propose_plan(goal.id, %{
        proposal_id: "iter7-fanout-#{mode()}",
        authored_by: "human:user",
        plan: plan
      })

    true = revision.digest == contract.digest

    {:ok, _} =
      Cobbler.approve_plan(goal.id, %{
        decision_id: "iter7-fanout-#{mode()}-approval",
        decided_by: "human:user",
        revision_number: revision.revision_number,
        digest: revision.digest,
        note:
          "User authorized the iteration 7 live fan-out verification. Registered bound: one attempt per task, three attempts and #{@goal_seconds} seconds per goal, #{@task_seconds} seconds per task, no replacement."
      })

    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{"claude_models" => "opus"})

    {:ok, agent} =
      AgentProfiles.create(%{
        "name" => "Fan-out verification",
        "slug" => "fanout-verification-#{mode()}",
        "purpose" => "Execute one approved plan task in its own private worktree.",
        "instructions" =>
          "Implement only the current approved task in its assigned worktree. Read the task's module and its named test. Change only the module the task names, preserve signatures, and never edit tests. Do not implement other tasks. Run the named Python gate using python3 -B -m unittest. Commit the change using the configured Git identity, with no authorship or contributor trailers; leave the worktree clean. Do not push, install packages, use network tools, create other agents, delete files or perform cleanup. Report the commit and gate result.",
        "roles" => [
          %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
          %{"name" => "Worker", "provider" => "claude", "model" => "opus"}
        ]
      })

    {:ok, profile} = AgentProfiles.snapshot_by_id(agent.id)

    identity = %{
      goal_id: goal.id,
      revision: revision.revision_number,
      digest: contract.digest,
      base: base,
      profile: Map.put(Map.delete(profile, "configuration"), "role", "Worker")
    }

    File.write!(local("identity.json"), Jason.encode!(identity))

    record("setup", %{
      mode: mode(),
      plan_digest: contract.digest,
      base: base,
      task_order: contract.ordered_task_ids,
      task_attempt_limit: 1,
      goal_attempt_limit: 3,
      task_seconds: @task_seconds,
      goal_seconds: @goal_seconds,
      reservation_policy: @policy,
      model: "opus",
      approval_attribution: "human:user",
      source_tests: baseline_tests()
    })
  end

  def baseline_tests do
    for test <- ~w(test/test_north.py test/test_south.py test/test_join.py) do
      {:ok, %{exit_status: status}} =
        Shoestring.Cobbler.GateProcess.run(
          ["python3", "-B", "-m", "unittest", test],
          source(),
          30_000,
          65_536
        )

      %{test: test, exit_status: status}
    end
  end

  def identity!, do: local("identity.json") |> File.read!() |> Jason.decode!()

  def status!(goal_id) do
    {:ok, status} = Cobbler.plan_execution_status(goal_id)
    status
  end

  def runs(goal_id),
    do: Repo.all(from r in RunRecord, where: r.goal_id == ^goal_id, order_by: r.inserted_at)

  ## Phases

  def fanout! do
    identity = identity!()
    goal_id = identity["goal_id"]
    [] = runs(goal_id)
    capacity = capacity!()
    true = capacity.support_tier == :conservative_partial
    record("capacity-fanout", capacity)
    head = git!(source(), ["rev-parse", "HEAD"]) |> String.trim()
    true = head == identity["base"]

    {:ok, result} =
      ExecutionControl.start(goal_id, %{
        revision_number: identity["revision"],
        digest: identity["digest"],
        repository_path: source(),
        requested_by: "human:user",
        agent_profile: identity["profile"]
      })

    execution_id = result.execution.execution_id
    confirm!(identity, execution_id, "north")
    confirm!(identity, execution_id, "south")

    for queue <- [:dispatch, :plan_child_inbox, :reservation_control, :plan_execution],
        do: :ok = Oban.resume_queue(queue: queue)

    sample = %{max_live_elves: 0, max_outstanding: 0, max_goal_outstanding: 0, samples: 0}

    {_status, sample} =
      wait!(
        fn -> fanout_progress(goal_id, Process.get(:sample, sample)) end,
        @phase_seconds
      )

    quiesce!(goal_id)
    status = status!(goal_id)

    record("fanout", %{
      execution_id: execution_id,
      dispatch_mode: status.dispatch_mode,
      accepted: status.accepted,
      children: Enum.map(status.children, &child_view/1),
      concurrency: sample,
      intervals: intervals(goal_id),
      runs: length(runs(goal_id)),
      reservations_outstanding: length(Reservations.outstanding()),
      integration: status.integration,
      needs_user: status.needs_user?,
      source_head_unchanged: git!(source(), ["rev-parse", "HEAD"]) |> String.trim() == head,
      source_clean: git!(source(), ["status", "--porcelain"]) == "",
      worker_jobs: jobs()
    })
  end

  defp fanout_progress(goal_id, sample) do
    status = status!(goal_id)
    rows = runs(goal_id)
    live = Enum.count(rows, &Shoestring.Elves.whereis(&1.id))
    outstanding = Reservations.outstanding()
    goal_outstanding = Enum.count(outstanding, &(&1.goal_id == goal_id))

    sample = %{
      sample
      | max_live_elves: max(sample.max_live_elves, live),
        max_outstanding: max(sample.max_outstanding, length(outstanding)),
        max_goal_outstanding: max(sample.max_goal_outstanding, goal_outstanding),
        samples: sample.samples + 1
    }

    Process.put(:sample, sample)

    cond do
      "north" in status.accepted and "south" in status.accepted and live == 0 ->
        {:ok, {status, sample}}

      status.needs_user? ->
        record("fanout-needs-user", %{
          accepted: status.accepted,
          children: Enum.map(status.children, &child_view/1),
          scope_blockers: status.scope_blockers
        })

        raise "plan_needs_user"

      true ->
        :pending
    end
  end

  def integrate! do
    identity = identity!()
    goal_id = identity["goal_id"]
    status = status!(goal_id)
    true = Enum.sort(status.accepted) == ["north", "south"]
    true = git!(source(), ["rev-parse", "HEAD"]) |> String.trim() == identity["base"]
    "" = git!(source(), ["status", "--porcelain"])

    # The user's role: merge each retained private branch in their own
    # repository. Shoestring itself never merges.
    merged =
      for evidence <- Enum.sort_by(status.accepted_evidence, & &1.plan_task_id) do
        {:ok, tree} = Worktrees.get(evidence.run_id)
        git!(source(), ["fetch", "-q", tree.repo_path, tree.branch])
        fetched = git!(source(), ["rev-parse", "FETCH_HEAD"]) |> String.trim()

        git!(source(), [
          "merge",
          "-q",
          "--no-ff",
          "--no-edit",
          "-m",
          "Merge accepted #{evidence.plan_task_id}",
          "FETCH_HEAD"
        ])

        %{task: evidence.plan_task_id, commit: fetched}
      end

    commit = git!(source(), ["rev-parse", "HEAD"]) |> String.trim()

    {:ok, event} =
      ExecutionControl.integrate(goal_id, %{
        execution_id: status.execution.execution_id,
        commit: commit,
        reason: "Merged the accepted north and south branches with no conflicts.",
        command_id: Ecto.UUID.generate(),
        requested_by: "human:user"
      })

    after_status = status!(goal_id)

    record("integration", %{
      merged: merged,
      commit: commit,
      event_id: event.id,
      payload: event.payload,
      integration: after_status.integration,
      tests_at_integration: baseline_tests()
    })
  end

  def join! do
    identity = identity!()
    goal_id = identity["goal_id"]
    status = status!(goal_id)
    execution_id = status.execution.execution_id
    capacity = capacity!()
    record("capacity-join", capacity)
    confirm!(identity, execution_id, "join")
    {:ok, continued} = ExecutionControl.continue(goal_id, execution_id)
    record("continue", continued)

    for queue <- [:dispatch, :plan_child_inbox, :reservation_control, :plan_execution],
        do: :ok = Oban.resume_queue(queue: queue)

    wait!(
      fn ->
        status = status!(goal_id)

        cond do
          status.completed? -> {:ok, status}
          status.needs_user? -> raise "plan_needs_user"
          true -> :pending
        end
      end,
      @phase_seconds
    )

    quiesce!(goal_id)
    status = status!(goal_id)
    rows = runs(goal_id)
    true = length(rows) == 3
    true = Enum.sort(status.accepted) == ["join", "north", "south"]

    record("result", %{
      completed: status.completed?,
      accepted: status.accepted,
      total_attempts: status.total_attempts,
      run_count: length(rows),
      dispatch_mode: status.dispatch_mode,
      integration: status.integration,
      goal_row_status: Repo.get!(Goal, goal_id).status,
      charged: %{
        total_duration_ms: status.total_duration_ms,
        total_run_duration_ms: status.total_run_duration_ms,
        total_gate_duration_ms: status.total_gate_duration_ms,
        total_verification_overhead_ms: status.total_verification_overhead_ms
      },
      reservations_outstanding: length(Reservations.outstanding()),
      worktrees: Map.new(rows, &{task_of(&1), git_worktree!(&1.id)}),
      worker_jobs: jobs()
    })
  end

  defp quiesce!(goal_id) do
    for queue <- [:plan_execution, :dispatch], do: :ok = Oban.pause_queue(queue: queue)

    wait!(
      fn ->
        busy =
          Repo.exists?(
            from j in Oban.Job,
              where:
                j.queue in ["plan_execution", "plan_child_inbox", "dispatch"] and
                  j.state == "executing"
          )

        live = Enum.any?(runs(goal_id), &Shoestring.Elves.whereis(&1.id))
        if busy or live, do: :pending, else: {:ok, :idle}
      end,
      60
    )
  end

  defp jobs do
    Repo.all(
      from j in Oban.Job,
        where: j.queue in ["plan_execution", "plan_child_inbox", "dispatch", "plan_cancellation"],
        order_by: j.id,
        select: %{queue: j.queue, worker: j.worker, state: j.state, attempt: j.attempt}
    )
  end

  defp child_view(child) do
    child
    |> Map.take([:plan_task_id, :attempt, :run_id, :stop_class, :status, :state])
  end

  defp task_of(run) do
    get_in(run.extensions, [Shoestring.Cobbler.PlanBinding.key(), "plan_task_id"]) || run.id
  end

  def intervals(goal_id) do
    for run <- runs(goal_id) do
      events =
        Repo.all(
          from e in TrajectoryEvent,
            where:
              e.goal_id == ^goal_id and e.run_id == ^run.id and
                e.type in [
                  "run.running",
                  "run.completed",
                  "run.failed",
                  "run.cancelled",
                  "run.interrupted"
                ],
            order_by: e.sequence,
            select: {e.type, e.occurred_at}
        )

      running = Enum.find_value(events, fn {t, at} -> if t == "run.running", do: at end)
      ended = Enum.find_value(events, fn {t, at} -> if t != "run.running", do: {t, at} end)

      %{
        task: task_of(run),
        run_id: run.id,
        status: run.status,
        running_at: running,
        terminal: ended && elem(ended, 0),
        ended_at: ended && elem(ended, 1)
      }
    end
  end

  def git_worktree!(run_id) do
    {:ok, worktree} = Worktrees.get(run_id)

    %{
      "head" => git!(worktree.path, ["rev-parse", "HEAD"]) |> String.trim(),
      "base" => worktree.base_commit,
      "dirty" => git!(worktree.path, ["status", "--porcelain"]) != "",
      "changed" =>
        git!(worktree.path, ["diff", "--name-only", worktree.base_commit, "HEAD"])
        |> String.split("\n", trim: true),
      "diff" => git!(worktree.path, ["diff", worktree.base_commit, "HEAD"]),
      "message" => git!(worktree.path, ["log", "-1", "--format=%B"])
    }
  end

  def git!(path, argv) do
    {:ok, %{output: output, exit_status: 0}} =
      Shoestring.Cobbler.GateProcess.run(["git" | argv], path, 15_000, 262_144)

    output
  end

  ## Export: selected canonical facts only, with path substitution.

  @domain ~w(cobbler.plan.revision.created cobbler.plan.approved cobbler.plan.execution.requested
    cobbler.plan.capacity.confirmed admission.decided cobbler.plan.independence.evaluated
    cobbler.plan.workspace.prepared cobbler.plan.task.dispatched cobbler.plan.task.accepted
    cobbler.plan.task.gate_failed cobbler.plan.task.scope_blocked cobbler.plan.integration.recorded
    cobbler.plan.execution.gate_failed cobbler.plan.execution.completed dispatch.effect_unknown
    lease.expired lease.revoked run.running run.completed run.failed run.cancelled run.interrupted)

  def export! do
    identity = identity!()
    goal_id = identity["goal_id"]

    events =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type in ^@domain,
          order_by: e.sequence,
          select: %{
            sequence: e.sequence,
            type: e.type,
            run_id: e.run_id,
            occurred_at: e.occurred_at,
            payload: e.payload
          }
      )
      |> Enum.map(fn event ->
        if String.starts_with?(event.type, "run."),
          do: Map.put(event, :payload, Map.take(event.payload, ["run_id", "reason", "error"])),
          else: event
      end)

    harness =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type == "harness.event_recorded",
          order_by: e.sequence,
          select: %{run_id: e.run_id, payload: e.payload}
      )

    runtime =
      for %{run_id: run_id, payload: p} <- harness,
          ext = p["extensions"] || %{},
          ext["claude-headless:subtype"] == "init" do
        %{
          task: task_of(Repo.get!(RunRecord, run_id)),
          model: ext["claude-headless:model"],
          cli_version: ext["claude-headless:claude_code_version"],
          permission_mode: ext["claude-headless:permission_mode"],
          tools: ext["claude-headless:tools"]
        }
      end

    commands =
      for %{run_id: run_id, payload: p} <- harness,
          ext = p["extensions"] || %{},
          ext["claude-headless:boundary"] in ["start", "end"] do
        %{
          task: task_of(Repo.get!(RunRecord, run_id)),
          ordinal: p["ordinal"],
          boundary: ext["claude-headless:boundary"],
          command: ext["claude-headless:command"],
          status: ext["claude-headless:status"],
          is_error: ext["claude-headless:is_error"]
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
      end

    outputs =
      for %{run_id: run_id, payload: p} <- harness,
          ext = p["extensions"] || %{},
          text = ext["claude-headless:output_text"],
          is_binary(text) do
        %{task: task_of(Repo.get!(RunRecord, run_id)), ordinal: p["ordinal"], text: text}
      end

    usage_keys =
      ~w(five_hour_utilization seven_day_utilization rate_limit_status rate_limit_type total_cost_usd duration_ms num_turns terminal_reason)

    usage =
      for %{run_id: run_id, payload: p} <- harness,
          ext = p["extensions"] || %{},
          values =
            Map.new(usage_keys, &{&1, ext["claude-headless:" <> &1]})
            |> Map.reject(fn {_k, v} -> is_nil(v) end),
          values != %{} do
        Map.merge(%{task: task_of(Repo.get!(RunRecord, run_id)), ordinal: p["ordinal"]}, values)
      end

    kinds =
      harness
      |> Enum.frequencies_by(& &1.payload["kind"])

    write_export("domain-events.json", events)
    write_export("runtime.json", runtime)
    write_export("commands.json", commands)
    write_export("public-agent-messages.json", outputs)
    write_export("provider-usage.json", usage)
    write_export("event-counts.json", %{normalized: length(harness), by_kind: kinds})
    write_export("final-status.json", status!(goal_id))
    record("export", %{events: length(events), normalized: length(harness)})
  end

  defp write_export(name, value) do
    json = Jason.encode!(value, pretty: true)
    File.write!(local(name), redact(json))
  end

  def redact(text) do
    text
    |> String.replace(root(), "$EVALUATION")
    |> String.replace(Path.expand("~"), "$USER_HOME")
    |> String.replace(~r/pgid:\d+/, "pgid:$PGID")
  end

  # A verification deadline is evidence, not permission to cancel useful work.
  def await_owned_terminal! do
    if File.exists?(local("identity.json")) do
      for run <- runs(identity!()["goal_id"]) do
        if pid = Shoestring.Elves.whereis(run.id) do
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          end
        end
      end
    end
  end
end

Iter7ClaudeFanout.boot()

try do
  case System.argv() do
    ["preflight"] -> Iter7ClaudeFanout.record("preflight", Iter7ClaudeFanout.capacity!())
    ["setup"] -> Iter7ClaudeFanout.setup!()
    ["fanout"] -> Iter7ClaudeFanout.fanout!()
    ["integrate"] -> Iter7ClaudeFanout.integrate!()
    ["join"] -> Iter7ClaudeFanout.join!()
    ["export"] -> Iter7ClaudeFanout.export!()
    _ -> raise "unsupported_phase"
  end
rescue
  error ->
    Iter7ClaudeFanout.await_owned_terminal!()

    Iter7ClaudeFanout.record("failure", %{
      error_type: inspect(error.__struct__),
      message: Iter7ClaudeFanout.redact(Exception.message(error)) |> String.slice(0, 2000),
      code: "verification_phase_failed"
    })

    reraise error, __STACKTRACE__
after
  :ok = Application.stop(:shoestring)
end
