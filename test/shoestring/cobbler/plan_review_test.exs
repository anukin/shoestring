defmodule Shoestring.Cobbler.PlanReviewTest do
  @moduledoc """
  Cross-review between passing gates and acceptance (iteration 8), through the
  executor facade with Fake-grade admission and an injected gate runner, over
  a real private worktree so packets, diffs and freshness checks are real.
  The reviewer is `Review.Fixture`; no provider CLI, no network.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.{GateProcess, PlanReview}
  alias Shoestring.Cobbler.Review.{Fixture, Record}
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Trajectory.TrajectoryEvent
  alias Shoestring.Worktrees

  import Shoestring.Test.PlanExecutorHelpers,
    only: [
      admit!: 1,
      complete_run!: 2,
      exec_opts: 1,
      gate_opts: 0,
      propose_and_approve!: 1,
      run_count: 1
    ]

  @moduletag :tmp_dir
  @review [enabled: true, adapter: :fixture, model: "fixture-reviewer"]
  @human "human:reviewer-test"

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    git!(source, ["init", "-b", "main"])
    git!(source, ["config", "user.name", "Fixture"])
    git!(source, ["config", "user.email", "fixture@example.invalid"])
    git!(source, ["add", "."])
    git!(source, ["-c", "commit.gpgsign=false", "commit", "-m", "Base"])

    %{
      goal: CobblerHelpers.create_goal!(),
      source: source,
      worktrees_dir: Path.join(dir, "worktrees")
    }
  end

  test "an approving review accepts only after its confirmed call, with the review recorded", c do
    {first, opts} = start!(c, "    return a + b\n")

    # Held: the call needs a human confirmation; nothing is accepted yet.
    assert {:ok, %{disposition: :review_pending, reason: :review_held}} = complete(c, first, opts)
    record = record!(first)
    assert record.state == "held"
    assert record.calls == 0

    assert {:ok, %{needs_user?: false, reviews: [%{state: "held"}]}} =
             Cobbler.plan_execution_status(c.goal.id)

    # Held again without a confirmation: no new admission decision.
    decisions = count("admission.decided", c.goal.id)
    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    assert count("admission.decided", c.goal.id) == decisions

    confirm!(c, record)
    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)

    record = record!(first)
    assert record.state == "approved"
    assert record.calls == 1
    accepted = event!(c.goal.id, "cobbler.plan.task.accepted")
    assert accepted.payload["review"]["review_id"] == record.id
    assert accepted.payload["review"]["reviewer"] == "fixture:fixture-reviewer"
    assert accepted.payload["review"]["blocking_count"] == 0
    assert event!(c.goal.id, "cobbler.plan.task.reviewed").payload["outcome"] == "approved"
  end

  test "the packet binds the contract, diff and gates and carries no worktree path or transcript",
       c do
    {first, opts} = start!(c, "    return a + b\n")
    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    record = record!(first)
    packet = Jason.decode!(record.packet_json)

    assert Enum.sort(Map.keys(packet)) ==
             ~w(base_commit changed_files commit diff gates goal output_schema plan repository_files repository_files_complete rubric task version)

    assert packet["commit"] == record.commit
    assert packet["diff"] =~ "+    return a + b"
    assert packet["changed_files"] == [%{"path" => "calc.py", "status" => "M"}]

    assert [%{"gate" => _, "exit_status" => 0, "output_tail" => "hermetic gate output"}] =
             packet["gates"]

    refute record.packet_json =~ c.worktrees_dir
    refute record.packet_json =~ "transcript"
    assert record.packet_digest == Shoestring.Cobbler.PlanContract.digest(packet)
  end

  test "a failing gate never reaches review", c do
    {first, opts} = start!(c, "    return a + b\n")

    failing =
      Keyword.update!(opts, :gate_runner_opts, &Keyword.put(&1, :runner, failing_runner()))

    assert {:ok, %{disposition: :gate_failed}} = complete(c, first, failing)
    assert Repo.aggregate(Record, :count) == 0
    assert count("cobbler.plan.task.review_requested", c.goal.id) == 0
  end

  test "blocking findings resolve the attempt for repair; the next attempt gets them and the reviewed commit",
       c do
    {first, opts} =
      start!(c, "    return a - b  # #{Fixture.marker()} subtracts instead of adding\n")

    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    confirm!(c, record!(first))

    assert {:ok, %{disposition: :review_blocked, retry_state: "retry"}} = complete(c, first, opts)
    record = record!(first)
    assert record.state == "changes_requested"

    assert [%{"path" => "calc.py", "line" => 2, "severity" => "blocking"}] =
             PlanReview.blocking_findings(record)

    blocked = event!(c.goal.id, "cobbler.plan.task.review_blocked")
    assert blocked.payload["gate"] == "cross_review"
    assert blocked.payload["commit"] == record.commit
    refute event(c.goal.id, "cobbler.plan.task.accepted")

    # The executor retries the task (not its dependent); the repair prompt
    # carries the findings and the reviewed commit.
    second = advance!(c, opts)
    assert second.plan_task_id == "alpha"
    assert second.attempt == 2
    prompt = run_prompt!(c.goal.id, second.run_id)
    assert prompt =~ "Cross-review of attempt 1"
    assert prompt =~ record.commit
    assert prompt =~ "subtracts instead of adding"
    assert run_count(c.goal.id) == 2
  end

  test "a repeated blocking finding escalates to the user, who can dismiss it with a reason", c do
    {first, opts} = start!(c, "    return a - b  # #{Fixture.marker()} subtracts\n")
    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    confirm!(c, record!(first))
    assert {:ok, %{disposition: :review_blocked}} = complete(c, first, opts)

    second = advance!(c, opts)
    complete_run!(c.goal, second.run_id)
    assert {:ok, %{reason: :review_held}} = complete(c, second, opts)
    confirm!(c, record!(second))

    assert {:ok, %{disposition: :review_pending, reason: :review_escalated}} =
             complete(c, second, opts)

    assert record!(second).state == "escalated"
    assert {:ok, %{needs_user?: true}} = Cobbler.plan_execution_status(c.goal.id)
    refute event(c.goal.id, "cobbler.plan.task.accepted")
    # Nothing re-dispatches while the escalation is open.
    assert %{disposition: :awaiting_task} = advance!(c, opts)

    decide!(c, record!(second), "accept", "The subtraction is the specified behaviour here.")
    assert {:ok, %{disposition: :accepted}} = complete(c, second, opts)
    review = event!(c.goal.id, "cobbler.plan.task.accepted").payload["review"]
    assert review["state"] == "waived"
    assert review["decided_by"] == @human
    assert review["blocking_count"] == 1
  end

  test "shoestring review lists, shows and decides an escalated review", c do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    {first, opts} =
      start!(c, "    return a - b  # #{Fixture.marker()} subtracts\n",
        review_config: Keyword.put(@review, :max_rounds, 1)
      )

    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    confirm!(c, record!(first))
    assert {:ok, %{reason: :review_escalated}} = complete(c, first, opts)

    Mix.Tasks.Shoestring.Review.run(["list", c.goal.id])
    assert_receive {:mix_shell, :info, [line]}
    assert line =~ "alpha attempt 1 round 1: escalated (fixture:fixture-reviewer)"
    assert line =~ "<- needs you"

    Mix.Tasks.Shoestring.Review.run(["show", c.goal.id, "alpha"])
    assert_receive {:mix_shell, :info, [_summary]}
    assert_receive {:mix_shell, :info, ["  reason: escalated"]}
    assert_receive {:mix_shell, :info, ["  F1 blocking calc.py:2: subtracts"]}

    assert_raise Mix.Error, ~r/--reason is required/, fn ->
      Mix.Tasks.Shoestring.Review.run(["accept", c.goal.id, "alpha"])
    end

    assert_raise Mix.Error, ~r/retry is not allowed now/, fn ->
      Mix.Tasks.Shoestring.Review.run(["retry", c.goal.id, "alpha", "--reason", "again"])
    end

    Mix.Tasks.Shoestring.Review.run([
      "accept",
      c.goal.id,
      "alpha",
      "--reason",
      "Intended.",
      "--by",
      @human
    ])

    assert_receive {:mix_shell, :info, ["Recorded accept for the review of alpha" <> _]}
    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)
  end

  test "a human rejection resolves the attempt as needing the user", c do
    {first, opts} = start!(c, "    return a - b  # #{Fixture.marker()} subtracts\n")
    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    decide!(c, record!(first), "reject", "Not acceptable without review.")

    assert {:ok, %{disposition: :review_blocked, retry_state: "needs_user"}} =
             complete(c, first, opts)

    assert {:ok, %{needs_user?: true}} = Cobbler.plan_execution_status(c.goal.id)
  end

  test "a reviewer of the implementer's provider is unavailable and never approves", c do
    {first, opts} =
      start!(c, "    return a + b\n",
        review_config: [enabled: true, adapter: :fixture, model: "m"],
        implementer: "fixture"
      )

    assert {:ok, %{reason: {:review_unavailable, "same_provider"}}} = complete(c, first, opts)
    assert {:ok, %{needs_user?: true}} = Cobbler.plan_execution_status(c.goal.id)
    refute event(c.goal.id, "cobbler.plan.task.reviewed")

    assert {:error, :review_confirmation_mismatch} =
             PlanReview.confirm(c.goal.id,
               review_id: record!(first).id,
               confirmation_id: Ecto.UUID.generate(),
               confirmed_by: @human
             )

    decide!(c, record!(first), "accept", "Waived: no second provider is configured yet.")
    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)

    assert event!(c.goal.id, "cobbler.plan.task.accepted").payload["review"]["reviewer"] ==
             "unavailable:same_provider"
  end

  test "a finding about a file the packet does not contain is unsupported and never blocks", c do
    fun = fn _packet ->
      {:ok,
       Jason.encode!(%{
         "verdict" => "request_changes",
         "summary" => "One invented problem.",
         "findings" => [finding("F1", "blocking", "lib/invented.py")]
       })}
    end

    {first, opts} = start!(c, "    return a + b\n", adapter_opts: [fixture_fun: fun])
    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    confirm!(c, record!(first))
    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)

    [finding] = Jason.decode!(record!(first).result_json)["findings"]
    assert finding["reference"] == "unsupported"
    assert record!(first).state == "approved"
  end

  test "a reviewer that changes the implementation fails the review and approves nothing", c do
    {first, opts} = start!(c, "    return a + b\n")
    worktree = record_worktree(opts)

    fun = fn _packet ->
      File.write!(Path.join(worktree, "calc.py"), "tampered\n")
      {:ok, Jason.encode!(%{"verdict" => "approve", "summary" => "Fine.", "findings" => []})}
    end

    opts = Keyword.put(opts, :review_adapter_opts, fixture_fun: fun)
    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    confirm!(c, record!(first))

    assert {:ok,
            %{disposition: :review_pending, reason: {:review_failed, "reviewed_commit_changed"}}} =
             complete(c, first, opts)

    assert record!(first).state == "failed"
    assert event!(c.goal.id, "cobbler.plan.task.reviewed").payload["outcome"] == "failed"
    refute event(c.goal.id, "cobbler.plan.task.accepted")
    assert {:ok, %{needs_user?: true}} = Cobbler.plan_execution_status(c.goal.id)
  end

  test "evidence goes stale when the reviewed commit moves before the call", c do
    {first, opts} = start!(c, "    return a + b\n")
    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    worktree = record_worktree(opts)
    File.write!(Path.join(worktree, "calc.py"), "def add(a, b):\n    return b + a\n")
    git!(worktree, ["-c", "commit.gpgsign=false", "commit", "-am", "Moved after the gates"])

    confirm!(c, record!(first))

    assert {:ok, %{reason: {:review_failed, "reviewed_commit_changed"}}} =
             complete(c, first, opts)

    refute event(c.goal.id, "cobbler.plan.task.reviewed")
    refute event(c.goal.id, "cobbler.plan.task.accepted")
  end

  test "a lost call is never re-sent by itself; a human retry makes exactly one more call", c do
    calls = :counters.new(1, [])

    fun = fn _packet ->
      :counters.add(calls, 1, 1)
      {:ok, Jason.encode!(%{"verdict" => "approve", "summary" => "Fine.", "findings" => []})}
    end

    {first, opts} = start!(c, "    return a + b\n", adapter_opts: [fixture_fun: fun])
    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)

    # A crash after the call started leaves the record running.
    record = record!(first)

    Repo.update_all(from(r in Record, where: r.id == ^record.id),
      set: [state: "running", calls: 1]
    )

    assert {:ok, %{reason: :review_running}} = complete(c, first, opts)
    assert {:ok, %{reason: :review_running}} = complete(c, first, opts)
    assert :counters.get(calls, 1) == 0

    decide!(c, record!(first), "retry", "The service restarted during the call.")
    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    confirm!(c, record!(first))
    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)
    assert :counters.get(calls, 1) == 1
    assert record!(first).calls == 2

    # The record is final: no further call is possible.
    assert {:error, :review_decision_not_allowed} =
             PlanReview.decide(c.goal.id,
               review_id: record!(first).id,
               decision_id: Ecto.UUID.generate(),
               decision: "retry",
               reason: "again",
               decided_by: @human
             )
  end

  test "known capacity admits the call without a confirmation", c do
    {first, opts} = start!(c, "    return a + b\n")
    opts = Keyword.put(opts, :review_snapshot, snapshot(:observed))

    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)
    assert record!(first).calls == 1
  end

  test "exhausted reviewer capacity queues the review; a confirmation cannot bypass it", c do
    calls = :counters.new(1, [])

    fun = fn _packet ->
      :counters.add(calls, 1, 1)
      {:ok, Jason.encode!(%{"verdict" => "approve", "summary" => "Fine.", "findings" => []})}
    end

    {first, opts} = start!(c, "    return a + b\n", adapter_opts: [fixture_fun: fun])
    opts = Keyword.put(opts, :review_snapshot, snapshot(:refused))

    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)
    confirm!(c, record!(first))
    assert {:ok, %{reason: :review_held}} = complete(c, first, opts)

    assert :counters.get(calls, 1) == 0
    assert record!(first).calls == 0
    refute event(c.goal.id, "cobbler.plan.task.accepted")
    # Waiting for capacity is not a decision the user must take.
    assert {:ok, %{needs_user?: false}} = Cobbler.plan_execution_status(c.goal.id)
  end

  test "review off keeps the previous acceptance path", c do
    {first, opts} = start!(c, "    return a + b\n", review_config: [])
    assert {:ok, %{disposition: :accepted}} = complete(c, first, opts)
    assert Repo.aggregate(Record, :count) == 0
    refute Map.has_key?(event!(c.goal.id, "cobbler.plan.task.accepted").payload, "review")
  end

  # ----------------------------------------------------------------------------

  defp start!(c, body, extra \\ []) do
    {:ok, wt} =
      Worktrees.create(c.source, Ecto.UUID.generate(), "HEAD",
        private_git: true,
        worktrees_dir: c.worktrees_dir
      )

    File.write!(Path.join(wt.path, "calc.py"), "def add(a, b):\n" <> body)
    git!(wt.path, ["-c", "commit.gpgsign=false", "commit", "-am", "Implement add"])
    head = wt.path |> git!(["rev-parse", "HEAD"]) |> String.trim()

    implementer = Keyword.get(extra, :implementer)

    opts =
      exec_opts(
        gate_runner_opts:
          Keyword.merge(gate_opts(),
            worktree_path: wt.path,
            commit: head,
            worktrees_dir: c.worktrees_dir
          ),
        review_config: Keyword.get(extra, :review_config, @review),
        review_adapter_opts: Keyword.get(extra, :adapter_opts, [])
      )

    rev = propose_and_approve!(c.goal)
    admission = admit!(c.goal)

    attrs =
      %{
        revision_number: rev.revision_number,
        digest: rev.digest,
        admission_event_id: admission.id
      }

    assert {:ok, _} = Cobbler.request_plan_execution(c.goal.id, attrs, opts)

    first = advance!(c, Keyword.put(opts, :admission_event_id, admission.id))

    if implementer do
      # Stand in for an execution bound to an agent of this provider.
      Repo.update_all(
        from(e in TrajectoryEvent,
          where: e.goal_id == ^c.goal.id and e.type == "cobbler.plan.execution.requested"
        ),
        set: [payload: execution_payload(c.goal.id, implementer)]
      )
    end

    complete_run!(c.goal, first.run_id)
    {first, opts}
  end

  defp execution_payload(goal_id, provider) do
    event =
      Repo.one!(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type == "cobbler.plan.execution.requested"
      )

    Map.put(event.payload, "agent_profile", %{"provider" => provider})
  end

  defp advance!(c, opts) do
    opts = Keyword.put_new_lazy(opts, :admission_event_id, fn -> admit!(c.goal).id end)
    assert {:ok, result} = Cobbler.advance_plan_execution(c.goal.id, opts)
    result
  end

  defp complete(c, dispatched, opts),
    do: Cobbler.complete_plan_task_run(c.goal.id, dispatched.run_id, opts)

  defp record!(dispatched), do: Repo.get_by!(Record, run_id: dispatched.run_id)

  defp record_worktree(opts),
    do: opts |> Keyword.fetch!(:gate_runner_opts) |> Keyword.fetch!(:worktree_path)

  defp confirm!(c, record) do
    assert {:ok, _} =
             PlanReview.confirm(c.goal.id,
               review_id: record.id,
               confirmation_id: Ecto.UUID.generate(),
               confirmed_by: @human
             )
  end

  defp decide!(c, record, decision, reason) do
    assert {:ok, _} =
             PlanReview.decide(c.goal.id,
               review_id: record.id,
               decision_id: Ecto.UUID.generate(),
               decision: decision,
               reason: reason,
               decided_by: @human
             )
  end

  defp snapshot(state) do
    now = DateTime.utc_now()

    windows =
      case state do
        :observed ->
          for {kind, seconds} <- [{"five_hour", 3600}, {"weekly", 86_400}],
              do: %{
                kind: kind,
                state: :observed,
                used_percent: 10,
                reset_at: DateTime.add(now, seconds)
              }

        :refused ->
          for kind <- ["five_hour", "weekly"],
              do: %{kind: kind, state: :unknown, reason: "quota refused"}
      end

    {:ok, snapshot} =
      Shoestring.Harness.CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: state,
          windows: windows,
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "reviewer.fixture",
            provider_id: "fixture",
            invocation_mode: "structured-review",
            event: :explicit_read
          },
          scope: "reviewer:fixture",
          confidence: if(state == :observed, do: :high, else: :medium),
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: if(state == :refused, do: "provider reported quota refusal"),
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  defp failing_runner do
    fn _argv, _worktree, _timeout ->
      {:ok, %{exit_status: 1, output: "FAILED", duration_ms: 3}}
    end
  end

  defp finding(id, severity, path) do
    %{
      "id" => id,
      "severity" => severity,
      "path" => path,
      "line" => 1,
      "claim" => "A claim.",
      "evidence" => "Some evidence.",
      "violates" => "correctness",
      "correction" => "A correction.",
      "confidence" => "high"
    }
  end

  defp run_prompt!(goal_id, run_id) do
    event =
      Repo.one!(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type == "run.requested" and e.run_id == ^run_id,
          limit: 1
      )

    event.payload["prompt"] || inspect(event.payload)
  end

  defp count(type, goal_id),
    do:
      Repo.aggregate(
        from(e in TrajectoryEvent, where: e.goal_id == ^goal_id and e.type == ^type),
        :count
      )

  defp event(goal_id, type),
    do:
      Repo.one(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type == ^type,
          order_by: [desc: e.sequence],
          limit: 1
      )

  defp event!(goal_id, type), do: event(goal_id, type) || flunk("no #{type} event")

  defp git!(repository, args) do
    assert {:ok, result} = GateProcess.run(["git" | args], repository, 15_000, 65_536)
    assert result.exit_status == 0, result.output
    result.output
  end
end
