defmodule Shoestring.Cobbler.HandoffWorkerTest do
  @moduledoc """
  End-to-end durable handoff: intent → `handoff`-queue delivery →
  `Handoffs.perform/3` → `dispatch`-queue delivery → supervised Elf → the
  receiver run actually executes and reaches terminal.

  This is the test the enqueue-only coverage could not be: it drives BOTH
  delivery legs and asserts a real Elf ran the receiver exactly once, with
  the receiver's own lease and a transcript-free projection.

  Hermetic: Oban `testing: :manual` (jobs are performed explicitly, never by a
  running queue), the `Shoestring.Harness.Fake` adapter, a trivial local
  `sleep` command, and an isolated Elf supervisor per test. Never a provider
  CLI, never the network, no provider quota.

  ## Lock ledger (base `01f2a54`, and the PR's own prior head `335b56a`)

  Every test here is a TRUE behavioural lock against `335b56a`: at that head
  `request/3` wrote a command row and **nothing consumed it** — there was no
  `handoff` queue, no `HandoffWorker`, and no `reconcile/1`, so the intent
  could never become an execution. These tests fail there because no delivery
  attempt exists to perform, which is the defect itself rather than a missing
  module name.
  """
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Commands, Handoffs}
  alias Shoestring.Harness.{CapacitySnapshot, DispatchRecord, ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Harness.Dispatch.ElfEffect
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Harness.Projector
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  # The worker derives its `now` from `:dispatch_clock`, so the whole fixture
  # runs on that same clock. Using a different instant would make the
  # receiver observation read as future-dated, and admission would honestly
  # (but confusingly) demand confirmation for a clock artifact.
  @t0 Shoestring.Test.FixedClock.now()

  # The sender is a different provider from the receiver — that is what makes
  # this a cross-provider handoff at all.
  @sender_provider "codex_app_server_stdio"
  @receiver_provider "fake"
  @receiver_adapter "shoestring.harness.fake"
  @receiver_scope "account:fake"

  @sender_transcript_marker "SENDER-TRANSCRIPT-GOLF4"
  @sender_session "codex-session-sender-GOLF4"
  @next_action_marker "NEXTACTION-GOLF4"

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})

    previous = %{
      effect: Application.get_env(:shoestring, :dispatch_effect),
      elf_opts: Application.get_env(:shoestring, :elf_dispatch_opts),
      clock: Application.get_env(:shoestring, :dispatch_clock),
      observe: Application.get_env(:shoestring, :handoff_observe)
    }

    Application.put_env(:shoestring, :dispatch_effect, ElfEffect)
    Application.put_env(:shoestring, :dispatch_clock, Shoestring.Test.FixedClock)

    Application.put_env(:shoestring, :elf_dispatch_opts,
      supervisor: sup,
      scenario: Scenario.normal_completion(),
      command: ["sleep", "30"],
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000]
    )

    Application.put_env(:shoestring, :handoff_observe, fn _scoping ->
      {:ok, eligible_snapshot!()}
    end)

    on_exit(fn ->
      restore(:dispatch_effect, previous.effect)
      restore(:elf_dispatch_opts, previous.elf_opts)
      restore(:dispatch_clock, previous.clock)
      restore(:handoff_observe, previous.observe)
    end)

    :ok
  end

  test "request → handoff delivery → dispatch delivery → one supervised Elf runs the receiver" do
    fixture = fixture()

    assert {:ok, %{handoff_id: handoff_id, job: handoff_job}} =
             Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

    assert is_binary(handoff_id)

    # Leg 1: the durable consumer. Nothing has executed yet.
    assert handoff_job.queue == "handoff"
    assert Repo.all(DispatchRecord) == []

    assert :ok = perform_delivery(handoff_job)

    # The handoff decided and dispatched; the receiver run exists but has not
    # run — the dispatch job is still only a delivery attempt.
    receiver = receiver_run!(fixture)
    assert receiver.dispatch_id == handoff_id
    assert receiver.provider_id == @receiver_adapter
    assert receiver.status == "requested"
    assert 0 == ElvesHelpers.count_events(fixture.goal.id, receiver.id, ["run.running"])

    # Receiver projection: the bounded checkpoint context, never the sender's
    # transcript or session.
    assert receiver.prompt =~ fixture.checkpoint_id
    assert receiver.prompt =~ @next_action_marker
    refute receiver.prompt =~ @sender_transcript_marker
    refute receiver.prompt =~ @sender_session
    assert receiver.continuation["checkpoint_id"] == fixture.checkpoint_id

    # The receiver's OWN lease, from the handoff's own admission decision.
    lease = Repo.get_by!(ExecutionLeaseRecord, run_id: receiver.id)
    assert lease.extensions["cobbler.lease:handoff_id"] == handoff_id
    refute Repo.get_by(ExecutionLeaseRecord, run_id: fixture.run.id)

    # Leg 2: the dispatch delivery starts the supervised Elf.
    assert [dispatch_job] = Repo.all(from j in Job, where: j.queue == "dispatch")
    assert :ok = perform_delivery(dispatch_job)

    assert {:ok, _terminal} =
             ElvesHelpers.wait_until(fn ->
               ElvesHelpers.terminal_event(fixture.goal.id, receiver.id)
             end)

    assert ElvesHelpers.terminal_event(fixture.goal.id, receiver.id).type == "run.completed"

    # ACTUAL one-run execution: exactly one Elf ran the receiver.
    assert 1 == ElvesHelpers.count_events(fixture.goal.id, receiver.id, ["run.running"])

    assert %DispatchRecord{status: "effect_completed"} =
             Repo.get(DispatchRecord, handoff_id)

    # The sender never ran again.
    assert 0 == ElvesHelpers.count_events(fixture.goal.id, fixture.run.id, ["run.running"])

    ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(fixture.goal.id, receiver.id))
  end

  test "a duplicate handoff delivery converges: no second receiver, no second Elf" do
    fixture = fixture()

    {:ok, %{job: handoff_job}} =
      Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

    assert :ok = perform_delivery(handoff_job)
    receiver = receiver_run!(fixture)

    assert [dispatch_job] = Repo.all(from j in Job, where: j.queue == "dispatch")
    assert :ok = perform_delivery(dispatch_job)

    assert {:ok, _} =
             ElvesHelpers.wait_until(fn ->
               ElvesHelpers.terminal_event(fixture.goal.id, receiver.id)
             end)

    # The same delivery attempt runs again (at-least-once delivery is the
    # normal case, not an exotic one).
    assert :ok = perform_delivery(handoff_job)

    assert length(handoff_events(fixture.goal.id)) == 1
    assert Enum.map(receiver_runs(fixture), & &1.id) == [receiver.id]
    assert length(Repo.all(DispatchRecord)) == 1
    assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 1

    # And re-delivering the dispatch does not start a second Elf.
    assert 1 == ElvesHelpers.count_events(fixture.goal.id, receiver.id, ["run.running"])

    ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(fixture.goal.id, receiver.id))
  end

  test "a restart with the delivery attempt lost still executes the standing intent" do
    fixture = fixture()

    {:ok, %{command: command, handoff_id: handoff_id}} =
      Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

    # The crash window: the intent committed, the delivery attempt is gone.
    Repo.delete_all(Job)
    assert Repo.all(DispatchRecord) == []

    # Boot-time repair (what `Shoestring.Cobbler.HandoffReconciler` runs).
    assert {:ok, %{repaired_count: 1, failures: []}} = Handoffs.reconcile()

    assert [restored] = Repo.all(from j in Job, where: j.queue == "handoff")
    assert restored.args["handoff_id"] == handoff_id
    assert restored.args["command_id"] == command.command_id

    assert :ok = perform_delivery(restored)

    receiver = receiver_run!(fixture)
    assert [dispatch_job] = Repo.all(from j in Job, where: j.queue == "dispatch")
    assert :ok = perform_delivery(dispatch_job)

    assert {:ok, _} =
             ElvesHelpers.wait_until(fn ->
               ElvesHelpers.terminal_event(fixture.goal.id, receiver.id)
             end)

    assert 1 == ElvesHelpers.count_events(fixture.goal.id, receiver.id, ["run.running"])
    assert length(handoff_events(fixture.goal.id)) == 1

    ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(fixture.goal.id, receiver.id))
  end

  # LOCK (final-acceptance.md §5.4, live): an identical `run.handoff` replayed
  # after the first delivery COMPLETED and the claim was released inserted a
  # sixth handoff job, which then failed `handoff_claim_lost` and retried.
  test "a replay after the transfer settled enqueues nothing, and a late delivery is a no-op" do
    fixture = fixture()
    attrs = handoff_attrs(fixture)

    {:ok, %{job: handoff_job, handoff_id: handoff_id}} = Handoffs.request(fixture.goal.id, attrs)
    assert :ok = perform_delivery(handoff_job)
    receiver = receiver_run!(fixture)

    assert [dispatch_job] = Repo.all(from j in Job, where: j.queue == "dispatch")
    assert :ok = perform_delivery(dispatch_job)

    assert {:ok, _} =
             ElvesHelpers.wait_until(fn ->
               ElvesHelpers.terminal_event(fixture.goal.id, receiver.id)
             end)

    # What the live node did: the delivery finished and the operator
    # released the goal's claim.
    Repo.update_all(from(j in Job, where: j.id == ^handoff_job.id), set: [state: "completed"])
    {:ok, %{command: release}} = Commands.submit(fixture.goal.id, release_command())
    assert release.status == "resolved"

    assert {:ok, %{outcome: :replayed, handoff_id: ^handoff_id, job: nil}} =
             Handoffs.request(fixture.goal.id, attrs)

    assert [only] = Repo.all(from j in Job, where: j.queue == "handoff")
    assert only.id == handoff_job.id

    # At-least-once delivery of the settled transfer, after the claim is gone,
    # converges without touching anything.
    assert :ok = perform_delivery(handoff_job)

    assert length(handoff_events(fixture.goal.id)) == 1
    assert Enum.map(receiver_runs(fixture), & &1.id) == [receiver.id]
    assert length(Repo.all(DispatchRecord)) == 1
    assert [_dispatch_job] = Repo.all(from j in Job, where: j.queue == "dispatch")
    assert 1 == ElvesHelpers.count_events(fixture.goal.id, receiver.id, ["run.running"])

    ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(fixture.goal.id, receiver.id))
  end

  test "a replay while the first delivery is still pending returns that attempt" do
    fixture = fixture()
    attrs = handoff_attrs(fixture)

    {:ok, %{job: first}} = Handoffs.request(fixture.goal.id, attrs)
    assert {:ok, %{outcome: :replayed, job: replayed}} = Handoffs.request(fixture.goal.id, attrs)

    assert replayed.id == first.id
    assert [only] = Repo.all(from j in Job, where: j.queue == "handoff")
    assert only.id == first.id
    assert receiver_runs(fixture) == []
  end

  test "a replay in the crash window (intent committed, attempt lost) restores one attempt" do
    fixture = fixture()
    attrs = handoff_attrs(fixture)

    {:ok, %{handoff_id: handoff_id}} = Handoffs.request(fixture.goal.id, attrs)
    Repo.delete_all(Job)

    assert {:ok, %{outcome: :replayed, job: %Job{} = restored}} =
             Handoffs.request(fixture.goal.id, attrs)

    assert restored.args["handoff_id"] == handoff_id
    assert [_only] = Repo.all(from j in Job, where: j.queue == "handoff")

    assert :ok = perform_delivery(restored)
    receiver = receiver_run!(fixture)
    assert length(handoff_events(fixture.goal.id)) == 1
    assert receiver.dispatch_id == handoff_id
  end

  test "a refused handoff delivery is :ok, records the decision, and executes nothing" do
    fixture = fixture()

    Application.put_env(:shoestring, :handoff_observe, fn _scoping ->
      {:ok, degraded_snapshot!()}
    end)

    {:ok, %{job: handoff_job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

    # A recorded refusal is a completed delivery, not a retriable failure:
    # retrying would re-observe the provider behind the operator's back.
    assert :ok = perform_delivery(handoff_job)

    assert [decision] = handoff_decisions(fixture.goal.id)
    assert decision.payload["result"] == "require_confirmation"
    assert handoff_events(fixture.goal.id) == []
    assert Repo.all(DispatchRecord) == []
    assert receiver_runs(fixture) == []
  end

  test "the worker fails closed with no observer configured" do
    fixture = fixture()
    Application.delete_env(:shoestring, :handoff_observe)

    {:ok, %{job: handoff_job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

    assert {:error, {:observation_failed, :missing_observe_fun}} = perform_delivery(handoff_job)

    assert handoff_decisions(fixture.goal.id) == []
    assert Repo.all(DispatchRecord) == []
  end

  test "production config wires the receiver observe MFA tuple" do
    # File contract, asserted without booting prod: the `handoff` queue exists
    # and the receiver probe is wired to the real Observatory-backed reader.
    runtime = File.read!(Path.join([File.cwd!(), "config", "runtime.exs"]))
    config = File.read!(Path.join([File.cwd!(), "config", "config.exs"]))

    assert runtime =~ ":handoff_observe"
    assert runtime =~ "WakeupObserve"
    assert config =~ "handoff:"
  end

  # ----------------------------------------------------------------------------
  # Fixture
  # ----------------------------------------------------------------------------

  defp fixture do
    goal = FakeHelpers.insert_goal(Ecto.UUID.generate())
    task = FakeHelpers.insert_task(goal, Ecto.UUID.generate())

    run =
      FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate()
      )

    run =
      Repo.update!(
        Ecto.Changeset.change(run,
          provider_id: @sender_provider,
          prompt: "#{@sender_transcript_marker} implement the widget",
          status: "suspended",
          requested_capabilities: %{"items" => ["resume", "cancel"]}
        )
      )

    checkpoint_id = Ecto.UUID.generate()
    decision = admission_payload(provider_id: "codex", adapter_id: "codex_app_server")
    admission = append_admission_event!(goal.id, decision)

    {:ok, %{command: claim}} = Commands.submit(goal.id, claim_command(admission))
    assert claim.status == "resolved"

    {:ok, _} =
      Trajectory.append(
        goal.id,
        %{
          "type" => "checkpoint.created",
          "schema_version" => 1,
          "actor" => "harness",
          "occurred_at" => @t0,
          "idempotency_key" => "checkpoint:#{checkpoint_id}",
          "payload" => %{
            "checkpoint_id" => checkpoint_id,
            "run_id" => run.id,
            "contract_version" => 1,
            "acceptance_contract" => %{"criteria" => ["tests pass"]},
            "repository_state" => %{"revision" => "abc123", "dirty" => false},
            "evidence" => %{"items" => []},
            "decisions" => %{"items" => ["chose approach A"]},
            "unresolved_issues" => %{"items" => []},
            "next_action" => "#{@next_action_marker} advance to step seven",
            "provider_session_id" => @sender_session,
            "stop_reason" => "quota_refused",
            "artifact_ids" => %{"items" => []},
            "extensions" => %{}
          }
        },
        trusted: [run_id: run.id]
      )

    {:ok, _} = Projector.project(goal.id)

    %{
      goal: goal,
      task: task,
      run: Repo.get!(RunRecord, run.id),
      checkpoint_id: checkpoint_id,
      decision_id: decision["decision_id"]
    }
  end

  defp handoff_attrs(fixture) do
    %{
      "command_id" => "cmd-handoff-" <> Ecto.UUID.generate(),
      "payload" => %{
        "run_id" => fixture.run.id,
        "checkpoint_id" => fixture.checkpoint_id,
        "decision_refs" => [fixture.decision_id],
        "to_provider_id" => @receiver_provider,
        "to_adapter_id" => @receiver_adapter,
        "scope" => @receiver_scope,
        "reason" => "sender quota exhausted",
        "requested_by" => "user:operator-1"
      }
    }
  end

  defp receiver_run!(fixture) do
    [receiver] = receiver_runs(fixture)
    receiver
  end

  defp receiver_runs(fixture) do
    sender_id = fixture.run.id
    goal_id = fixture.goal.id

    Repo.all(
      from run in RunRecord,
        where: run.goal_id == ^goal_id and run.id != ^sender_id,
        order_by: [asc: run.inserted_at, asc: run.id]
    )
  end

  defp handoff_events(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == "handoff.created",
        order_by: [asc: event.sequence]
    )
  end

  defp handoff_decisions(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == "admission.decided" and
            like(event.idempotency_key, "handoff-decision:%"),
        order_by: [asc: event.sequence]
    )
  end

  defp eligible_snapshot!, do: snapshot!(:observed, :compatible, :high, nil)

  defp degraded_snapshot! do
    snapshot!(:degraded, :degraded, :medium, "receiver adapter surface is degraded")
  end

  defp snapshot!(capacity_state, compatibility_state, confidence, reason) do
    reset_at = DateTime.add(@t0, 7_200, :second)

    attrs = %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: capacity_state,
      windows: [
        %{kind: "five_hour", state: :observed, used_percent: 10.0, reset_at: reset_at},
        %{kind: "weekly", state: :observed, used_percent: 12.0, reset_at: reset_at}
      ],
      observed_at: @t0,
      freshness: %{max_age_seconds: 300},
      source: %{
        adapter_id: @receiver_adapter,
        provider_id: @receiver_provider,
        invocation_mode: "headless",
        event: :explicit_read
      },
      scope: @receiver_scope,
      confidence: confidence,
      support_tier: :proactive,
      compatibility_state: compatibility_state,
      reason: reason,
      extensions: %{}
    }

    {:ok, snapshot} = CapacitySnapshot.new(attrs, now: @t0)
    snapshot
  end

  defp perform_delivery(job) do
    job
    |> Map.put(:attempted_at, Shoestring.Test.FixedClock.now())
    |> Map.put(:scheduled_at, Shoestring.Test.FixedClock.now())
    |> perform_job()
  end

  defp restore(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore(key, value), do: Application.put_env(:shoestring, key, value)
end
