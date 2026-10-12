# Explicitly invoked live verification, never part of the hermetic test gate.
# Uses a disposable SHOESTRING_STATE_DIR and the reviewed receipt plan.
# No raw provider frames, account data, or reasoning are exported.

defmodule Iter6Receipt do
  import Ecto.Query
  alias Shoestring.{AgentProfiles, Cobbler, Repo, Worktrees}
  alias Shoestring.Cobbler.{ExecutionControl, PlanContract}
  alias Shoestring.Harness.{DispatchRecord, RunRecord}
  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

  @plan_file "plans/evidence/06-cobbler-planning/luna-evaluation/receipt/bound-plan.json"
  @digest "13ba4b39f66d01dd9d1e37a119803e73f85caebdb3792181d134843138d8decd"

  def local(name), do: Path.join(Shoestring.State.root(), name)

  def boot do
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :none)

    Application.put_env(:shoestring, :capacity_monitors,
      claude: [enabled: false],
      codex: [enabled: true, transport_opts: [args: ["--no-daemon", "app-server", "--stdio"]]]
    )

    Application.put_env(:shoestring, :elf_dispatch_opts,
      adapter_opts: %{
        live: true,
        ephemeral: true,
        transport_opts: [
          args: [
            "--no-daemon",
            "app-server",
            "--stdio",
            "-c",
            "model_reasoning_effort=\"medium\"",
            "-c",
            "model_reasoning_summary=\"none\"",
            "-c",
            "web_search=\"disabled\"",
            "-c",
            "project_doc_max_bytes=0",
            "-c",
            "mcp_servers={}",
            "--disable",
            "multi_agent",
            "--disable",
            "multi_agent_v2",
            "--disable",
            "hooks",
            "--disable",
            "plugins",
            "--disable",
            "apps"
          ]
        ]
      }
    )

    config = Application.fetch_env!(:shoestring, Oban)

    Application.put_env(
      :shoestring,
      Oban,
      config
      |> Keyword.put(:plugins, [])
      |> Keyword.put(:queues,
        dispatch: [limit: 5, paused: true],
        plan_execution: [limit: 1, paused: true],
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
          100 -> wait_loop(fun, deadline)
        end
    end
  end

  def capacity! do
    wait!(
      fn ->
        if CodexMonitor.last_observation(), do: {:ok, :ready}, else: :pending
      end,
      40
    )

    {:ok, snapshot} = CodexMonitor.read_capacity()

    %{
      monitor_status: CodexMonitor.status(),
      version: CodexMonitor.get_status().discovered_version,
      capacity_state: snapshot.capacity_state,
      compatibility_state: snapshot.compatibility_state,
      support_tier: snapshot.support_tier,
      scope: snapshot.scope,
      windows:
        Enum.map(snapshot.windows, &Map.take(&1, [:kind, :state, :used_percent, :reset_at])),
      window_minutes:
        Enum.reduce(~w(primary secondary), %{}, fn kind, acc ->
          state = :sys.get_state(CodexMonitor)
          payload = state.last_known_provider_state
          limits = get_in(payload, ["result", "rateLimits"]) || payload["rateLimits"] || %{}
          Map.put(acc, kind, get_in(limits, [kind, "windowDurationMins"]))
        end)
    }
  end

  def setup! do
    false = File.exists?(local("identity.json"))
    plan = @plan_file |> File.read!() |> Jason.decode!()
    {:ok, contract} = PlanContract.new(plan)
    true = contract.digest == @digest
    source = System.fetch_env!("ITER6_REPOSITORY")
    base = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
    "" = git!(source, ["status", "--porcelain"])
    # A new explicitly authorized evaluation gets its own goal/allowance. Only
    # the repository binding changes; the previous consumed attempt is retained.
    plan = put_in(plan, ["goal", "repository", "base_revision"], base)
    {:ok, contract} = PlanContract.new(plan)
    File.write!(local("bound-plan.json"), Jason.encode!(plan, pretty: true))

    {:ok, goal} =
      %Goal{}
      |> Goal.create_changeset(Ecto.UUID.generate(), %{
        title: "Live receipt model-plan execution",
        description: plan["goal"]["statement"]
      })
      |> Repo.insert()

    {:ok, %{revision: revision}} =
      Cobbler.propose_plan(goal.id, %{
        proposal_id: "live-receipt-import",
        authored_by: "human:user",
        plan: plan
      })

    true = revision.digest == contract.digest

    {:ok, _} =
      Cobbler.approve_plan(goal.id, %{
        decision_id: "live-receipt-user-authorized-run",
        decided_by: "human:user",
        revision_number: revision.revision_number,
        digest: revision.digest,
        note:
          "User authorized a new receipt evaluation after controlled commit access changes. One attempt per task, two total attempts, 300 seconds per task and 600 seconds per goal. Previous evaluation remains failed; no counters are reset. Only the fresh fixture base binding changes."
      })

    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{"codex_models" => "gpt-6-luna"})

    {:ok, agent} =
      AgentProfiles.create(%{
        "name" => "Receipt verification",
        "slug" => "receipt-verification",
        "purpose" => "Execute the approved Python receipt plan sequentially.",
        "instructions" =>
          "Implement only the current approved task in its assigned worktree. Read pantry.py and the named tests. Change only pantry.py, preserve signatures and unrelated functions, and never edit tests. Do not implement a dependent task before it is assigned. Run the named Python gate using python3 -B -m unittest. Commit task changes using the configured Git identity, with no authorship or contributor trailers; leave the worktree clean. Do not push, install packages, use network tools, create other agents, delete files or perform cleanup. Report the commit and gate result.",
        "roles" => [
          %{"name" => "Coordinator", "provider" => "codex", "model" => "gpt-6-luna"},
          %{"name" => "Worker", "provider" => "codex", "model" => "gpt-6-luna"}
        ]
      })

    {:ok, profile} = AgentProfiles.snapshot_by_id(agent.id)

    identity = %{
      goal_id: goal.id,
      revision: revision.revision_number,
      digest: contract.digest,
      source: source,
      base: base,
      profile: Map.put(Map.delete(profile, "configuration"), "role", "Worker")
    }

    File.write!(local("identity.json"), Jason.encode!(identity))

    record("setup", %{
      plan_digest: contract.digest,
      original_plan_digest: @digest,
      new_evaluation_allowance: true,
      base: base,
      task_order: contract.ordered_task_ids,
      task_attempt_limit: 1,
      goal_attempt_limit: 2,
      goal_seconds: 600,
      model: "gpt-6-luna",
      approval_attribution: "human:user",
      source_clean: true
    })
  end

  def identity!, do: local("identity.json") |> File.read!() |> Jason.decode!()

  def status!(goal_id) do
    {:ok, status} = Cobbler.plan_execution_status(goal_id)
    status
  end

  def runs(goal_id),
    do: Repo.all(from r in RunRecord, where: r.goal_id == ^goal_id, order_by: r.inserted_at)

  def first! do
    identity = identity!()
    # Re-delivery after admission refusal is permitted; a consumed task
    # attempt is never reset by this verification driver.
    true = Map.get(status!(identity["goal_id"]), :total_attempts, 0) == 0
    true = runs(identity["goal_id"]) == []
    capacity = capacity!()
    true = capacity.compatibility_state == :compatible
    record("capacity-first", capacity)

    {:ok, result} =
      ExecutionControl.start(identity["goal_id"], %{
        revision_number: identity["revision"],
        digest: identity["digest"],
        repository_path: identity["source"],
        requested_by: "human:user",
        agent_profile: identity["profile"]
      })

    :ok = Oban.resume_queue(queue: :plan_execution)

    first =
      wait!(
        fn ->
          case runs(identity["goal_id"]) do
            [run] -> {:ok, run}
            [] -> :pending
            _ -> raise "unexpected_run_count"
          end
        end,
        30
      )

    :ok = Oban.resume_queue(queue: :dispatch)

    wait!(
      fn ->
        case Repo.get_by!(DispatchRecord, run_id: first.id).status do
          "effect_completed" -> {:ok, :delivered}
          "effect_failed" -> raise "dispatch_effect_failed"
          _ -> :pending
        end
      end,
      35
    )

    :ok = Oban.pause_queue(queue: :dispatch)

    wait!(
      fn ->
        status = status!(identity["goal_id"])

        cond do
          status.needs_user? ->
            raise "plan_needs_user"

          status.accepted == ["implement-total"] and length(runs(identity["goal_id"])) == 2 ->
            {:ok, status}

          true ->
            :pending
        end
      end,
      330
    )

    [first, second] = runs(identity["goal_id"])
    true = is_nil(Shoestring.Elves.whereis(first.id))
    true = is_nil(Shoestring.Elves.whereis(second.id))
    before = snapshot!(identity["goal_id"])
    File.write!(local("before-restart.json"), Jason.encode!(before, pretty: true))

    record("first", %{
      accepted: before["status"]["accepted"],
      total_attempts: before["status"]["total_attempts"],
      run_count: 2,
      first_terminal: first.status,
      second_status: second.status,
      second_not_started:
        not Repo.exists?(
          from e in TrajectoryEvent,
            where:
              e.goal_id == ^identity["goal_id"] and e.run_id == ^second.id and
                e.type == "run.running"
        ),
      execution_id: result.execution.execution_id,
      first_commit: git_worktree!(first.id)["head"],
      restart_ready: true
    })
  end

  def second! do
    identity = identity!()
    before = local("before-restart.json") |> File.read!() |> Jason.decode!()
    after_boot = snapshot!(identity["goal_id"])
    true = before == after_boot

    record("restart", %{
      canonical_snapshot_equal: true,
      accepted: after_boot["status"]["accepted"],
      total_attempts: after_boot["status"]["total_attempts"],
      run_count: length(runs(identity["goal_id"])),
      planning_requests:
        Repo.aggregate(
          from(p in Shoestring.Cobbler.PlannerRequestRecord,
            where: p.goal_id == ^identity["goal_id"]
          ),
          :count
        )
    })

    capacity = capacity!()
    true = capacity.compatibility_state == :compatible
    record("capacity-second", capacity)
    :ok = Oban.resume_queue(queue: :dispatch)
    :ok = Oban.resume_queue(queue: :plan_execution)

    wait!(
      fn ->
        status = status!(identity["goal_id"])

        cond do
          status.completed? -> {:ok, status}
          status.needs_user? -> raise "plan_needs_user"
          true -> :pending
        end
      end,
      330
    )

    final = snapshot!(identity["goal_id"])
    File.write!(local("final.json"), Jason.encode!(final, pretty: true))
    [first, second] = runs(identity["goal_id"])
    first_git = git_worktree!(first.id)
    second_git = git_worktree!(second.id)
    "" = git!(identity["source"], ["status", "--porcelain"])
    true = git!(identity["source"], ["rev-parse", "HEAD"]) |> String.trim() == identity["base"]
    true = length(runs(identity["goal_id"])) == 2
    true = final["status"]["total_attempts"] == 2
    true = final["status"]["accepted"] == ["implement-total", "render-receipt"]

    record("result", %{
      completed: true,
      source_clean_and_unchanged: true,
      run_count: 2,
      first: first_git,
      second: second_git,
      plan_digest: identity["digest"],
      accepted: final["status"]["accepted"],
      total_attempts: 2
    })
  end

  def snapshot!(goal_id) do
    types =
      ~w(cobbler.plan.execution.requested cobbler.plan.task.dispatched cobbler.plan.task.accepted
      cobbler.plan.task.gate_failed cobbler.plan.execution.gate_failed cobbler.plan.execution.completed admission.decided)

    events =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type in ^types,
          order_by: e.sequence
      )

    %{
      status: status!(goal_id),
      events: Enum.map(events, &Map.take(&1, [:sequence, :type, :payload]))
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  def git_worktree!(run_id) do
    {:ok, worktree} = Worktrees.get(run_id)

    %{
      "head" => git!(worktree.path, ["rev-parse", "HEAD"]) |> String.trim(),
      "base" => worktree.base_commit,
      "dirty" => git!(worktree.path, ["status", "--porcelain"]) != "",
      "diff" => git!(worktree.path, ["diff", worktree.base_commit, "HEAD", "--", "pantry.py"]),
      "message" => git!(worktree.path, ["log", "-1", "--format=%B"])
    }
  end

  def failure_audit! do
    identity = identity!()
    goal_id = identity["goal_id"]
    before = snapshot!(goal_id)
    true = before["status"]["needs_user?"]
    true = before["status"]["total_attempts"] == 1
    [] = before["status"]["accepted"]
    [run] = runs(goal_id)
    "completed" = run.status
    true = is_nil(Shoestring.Elves.whereis(run.id))
    {:ok, worktree} = Worktrees.get(run.id)
    diff = git!(worktree.path, ["diff", "HEAD", "--", "pantry.py"])
    File.write!(local("unaccepted-total.patch"), diff)

    {:ok, %{output: test_output, exit_status: test_exit}} =
      Shoestring.Cobbler.GateProcess.run(
        ["python3", "-B", "-m", "unittest", "test/test_total.py"],
        worktree.path,
        30_000,
        65_536
      )

    File.write!(local("unaccepted-total-test.txt"), test_output)
    0 = test_exit
    File.write!(local("failed-before-restart.json"), Jason.encode!(before, pretty: true))
    pid = Process.whereis(Shoestring.Supervisor)
    ref = Process.monitor(pid)
    :ok = Application.stop(:shoestring)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      15_000 -> raise "application_stop_timeout"
    end

    {:ok, _} = Application.ensure_all_started(:shoestring)
    after_restart = snapshot!(goal_id)
    true = before == after_restart
    File.write!(local("failed-after-restart.json"), Jason.encode!(after_restart, pretty: true))

    {:ok, %{outcome: :needs_user, job_id: nil}} =
      ExecutionControl.continue(goal_id, before["status"]["execution"]["execution_id"])

    [same_run] = runs(goal_id)
    true = same_run.id == run.id
    true = is_nil(Shoestring.Elves.whereis(same_run.id))
    "" = git!(identity["source"], ["status", "--porcelain"])
    true = git!(identity["source"], ["rev-parse", "HEAD"]) |> String.trim() == identity["base"]

    record("failure-audit", %{
      completed: false,
      needs_user: true,
      accepted: [],
      total_attempts: 1,
      run_count: 1,
      provider_completed: true,
      task_gate_rejected_dirty_worktree: true,
      unaccepted_total_test_exit: test_exit,
      dependent_dispatched: false,
      restart_snapshot_equal: true,
      continue_outcome: "needs_user",
      continue_job: nil,
      active_elf: false,
      source_clean_and_unchanged: true,
      plan_digest: identity["digest"],
      worktree_head_unchanged:
        git!(worktree.path, ["rev-parse", "HEAD"]) |> String.trim() == identity["base"]
    })
  end

  def git!(path, argv) do
    {:ok, %{output: output, exit_status: 0}} =
      Shoestring.Cobbler.GateProcess.run(["git" | argv], path, 15_000, 65_536)

    output
  end

  # A verification deadline is evidence, not permission to cancel useful work.
  # Keep this disposable node alive until its owned Elf reaches terminal state.
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

Iter6Receipt.boot()

try do
  case System.argv() do
    ["preflight"] -> Iter6Receipt.record("preflight", Iter6Receipt.capacity!())
    ["setup"] -> Iter6Receipt.setup!()
    ["first"] -> Iter6Receipt.first!()
    ["second"] -> Iter6Receipt.second!()
    ["failure-audit"] -> Iter6Receipt.failure_audit!()
    _ -> raise "unsupported_phase"
  end
rescue
  error ->
    Iter6Receipt.await_owned_terminal!()

    Iter6Receipt.record("failure", %{
      error_type: inspect(error.__struct__),
      code: "verification_phase_failed"
    })

    reraise error, __STACKTRACE__
after
  :ok = Application.stop(:shoestring)
end
