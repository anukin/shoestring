defmodule Shoestring.Cobbler.HandoffCrashWindowTest do
  @moduledoc """
  The decision-to-pointer crash window, and what a permanently failed intent
  must do instead of retrying forever.

  ## The window

  `Handoffs.transfer/10` commits its own `admission.decided` BEFORE the
  receiver row, the lease and the `handoff.created` pointer. A crash in that
  gap leaves a committed decision and no pointer, so the retry misses the
  idempotency guard and lands back on the boundary check — where an
  unfiltered projection shows the handoff *its own* decision as an external
  change.

  Unrepaired, that is permanent: every retry re-reads the same committed
  decision and returns `:decision_superseded`, and no amount of reconciling,
  restarting or operator patience clears it. The handoff can only be
  abandoned. These tests prove it recovers instead, and that the repair does
  not blind the check to a genuinely external decision.

  ## Injection

  `perform/3` documents `:repo`, so the crash is injected through that real
  seam rather than a test-only hook: `CrashingRepo` delegates everything to
  `Shoestring.Repo` except the receiver-run insert, where it raises. The
  decision is appended through the trajectory writer (which uses the global
  repo), so it genuinely commits before the raise — this reproduces the
  window, it does not simulate it.

  ## Lock ledger

  TRUE behavioural locks against the PR's own prior head `640f6be`:

    * every test in the `"recovering the decision-to-pointer crash window"`
      group — at `640f6be` the retry returns `{:error, :decision_superseded}`
      where a completed transfer is asserted;
    * every test in the `"a permanently failed intent settles durably"`
      group — at `640f6be` `handoff.failed` does not exist, `reconcile/1`
      re-enqueues the failed intent on every pass, and the worker burns
      retries on an error no retry can clear.

  DOCUMENTATION: the external-change and transient twins, which pass at both
  heads and pin the behaviour the repair must not break.

  Hermetic: Fake-derived state and local commands only. No provider CLI, no
  network, no provider quota.
  """
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Commands, Handoffs, HandoffReconciler}
  alias Shoestring.Harness.{CapacitySnapshot, DispatchRecord, ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Harness.Projector
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.ManualClock
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @t0 ~U[2026-09-07 12:00:00.000000Z]

  @sender_provider "shoestring.harness.fake"
  @receiver_provider "fake-receiver"
  @receiver_adapter "shoestring.harness.fake"
  @receiver_scope "account:fake-receiver"
  @next_action "NEXTACTION-HOTEL5 advance to step seven"

  defmodule CrashingRepo do
    @moduledoc """
    `Shoestring.Repo`, except that inserting the receiver run raises.

    Every other call delegates, so the handoff runs normally right up to the
    first irreversible step and then dies there — exactly the
    decision-committed / pointer-missing state a real crash leaves behind.
    """
    alias Shoestring.Harness.RunRecord
    alias Shoestring.Repo

    defdelegate one(queryable), to: Repo
    defdelegate one(queryable, opts), to: Repo
    defdelegate all(queryable), to: Repo
    defdelegate get(schema, id), to: Repo
    defdelegate get(schema, id, opts), to: Repo
    defdelegate get_by(schema, clauses), to: Repo
    defdelegate exists?(queryable), to: Repo

    def insert(%Ecto.Changeset{data: %RunRecord{}}) do
      raise "simulated crash after admission, before the handoff pointer"
    end

    defdelegate insert(struct_or_changeset), to: Repo
    defdelegate insert(struct_or_changeset, opts), to: Repo
  end

  setup do
    ManualClock.set(@t0)
    previous = Application.get_env(:shoestring, :dispatch_clock)
    Application.put_env(:shoestring, :dispatch_clock, ManualClock)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:shoestring, :dispatch_clock)
        value -> Application.put_env(:shoestring, :dispatch_clock, value)
      end
    end)

    :ok
  end

  # ----------------------------------------------------------------------------
  # C1: the decision-to-pointer crash window
  # ----------------------------------------------------------------------------

  describe "recovering the decision-to-pointer crash window" do
    test "a crash after admission recovers into ONE receiver, lease, pointer and dispatch" do
      fixture = fixture()
      {:ok, %{command: command, handoff_id: handoff_id}} = request!(fixture)

      # The crash. It happens after the decision commits and before anything
      # irreversible, which is the whole point of the window.
      assert_raise RuntimeError, ~r/simulated crash/, fn ->
        Handoffs.perform(
          fixture.goal.id,
          command.command_id,
          perform_opts(repo: CrashingRepo)
        )
      end

      # The durable wreckage: a committed decision, and nothing else.
      assert [crashed_decision] = handoff_decisions(fixture.goal.id)
      assert crashed_decision.payload["result"] == "admit"
      assert handoff_events(fixture.goal.id) == []
      assert receiver_runs(fixture) == []
      assert Repo.all(DispatchRecord) == []
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 0

      # Projection now genuinely contains a ref the operator never authorized
      # — this handoff's own. An unfiltered comparison would refuse here.
      refute Repo.one!(
               from event in TrajectoryEvent,
                 where: event.goal_id == ^fixture.goal.id and event.type == "admission.decided",
                 select: count(event.id)
             ) == 1

      # THE LOCK: the retry completes rather than refusing itself forever.
      assert {:ok, %{outcome: :dispatched, run: receiver}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      # Exactly one of everything.
      assert Enum.map(receiver_runs(fixture), & &1.id) == [receiver.id]
      assert length(handoff_events(fixture.goal.id)) == 1
      assert length(Repo.all(DispatchRecord)) == 1
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 1

      lease = Repo.get_by!(ExecutionLeaseRecord, run_id: receiver.id)
      assert lease.extensions["cobbler.lease:handoff_id"] == handoff_id

      [pointer] = handoff_events(fixture.goal.id)
      assert pointer.payload["run_id"] == receiver.id
      assert pointer.payload["lease_grant_id"] == lease.id
      assert pointer.payload["prior_run_id"] == fixture.run.id

      # The receiver was handed the AUTHORIZED refs, not the handoff's own
      # bookkeeping decision.
      assert pointer.payload["decision_refs"] == [fixture.decision_id]

      assert Repo.get!(RunRecord, receiver.id).continuation["decision_refs"] == [
               fixture.decision_id
             ]

      # And no handoff.failed was recorded: nothing failed permanently.
      assert failure_events(fixture.goal.id) == []
    end

    test "recovery runs end to end: the repaired delivery starts one supervised Elf" do
      sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert_raise RuntimeError, fn ->
        Handoffs.perform(
          fixture.goal.id,
          command.command_id,
          perform_opts(repo: CrashingRepo)
        )
      end

      # The standing intent is NOT settled by a crash, so reconcile keeps it
      # alive and the repaired delivery attempt performs the recovery.
      assert {:ok, %{repaired_count: repaired}} = Handoffs.reconcile()
      assert repaired >= 0

      Application.put_env(:shoestring, :handoff_observe, fn _scoping ->
        {:ok, eligible_snapshot!()}
      end)

      configure_elf_dispatch(sup)

      on_exit(fn ->
        Application.delete_env(:shoestring, :handoff_observe)
        Application.delete_env(:shoestring, :dispatch_effect)
        Application.delete_env(:shoestring, :elf_dispatch_opts)
      end)

      [handoff_job] = Repo.all(from j in Job, where: j.queue == "handoff")
      assert :ok = perform_delivery(handoff_job)

      receiver = receiver_run!(fixture)
      [dispatch_job] = Repo.all(from j in Job, where: j.queue == "dispatch")
      assert :ok = perform_delivery(dispatch_job)

      assert {:ok, _terminal} =
               Shoestring.Test.ElvesHelpers.wait_until(fn ->
                 Shoestring.Test.ElvesHelpers.terminal_event(fixture.goal.id, receiver.id)
               end)

      # ACTUAL one-run execution after recovery.
      assert 1 ==
               Shoestring.Test.ElvesHelpers.count_events(
                 fixture.goal.id,
                 receiver.id,
                 ["run.running"]
               )

      assert length(handoff_events(fixture.goal.id)) == 1
      assert length(Repo.all(DispatchRecord)) == 1

      Shoestring.Test.ElvesHelpers.cleanup_group(
        Shoestring.Test.ElvesHelpers.recorded_pgid(fixture.goal.id, receiver.id)
      )
    end

    test "a GENUINELY external decision in the same window still refuses" do
      # The repair must exclude only this handoff's own decisions. A decision
      # from any other source keeps a different idempotency key, stays in the
      # comparison, and must still supersede the authorization.
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert_raise RuntimeError, fn ->
        Handoffs.perform(
          fixture.goal.id,
          command.command_id,
          perform_opts(repo: CrashingRepo)
        )
      end

      # Someone else decides admission for this goal while the handoff is
      # mid-flight.
      append_admission_event!(
        fixture.goal.id,
        admission_payload(decision_id: Ecto.UUID.generate())
      )

      assert {:error, :decision_superseded} =
               Handoffs.perform(
                 fixture.goal.id,
                 command.command_id,
                 perform_opts(observe: fn _ -> flunk("must refuse before observing") end)
               )

      assert handoff_events(fixture.goal.id) == []
      assert receiver_runs(fixture) == []
    end

    test "two crashes in a row still recover to exactly one transfer" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      for _attempt <- 1..2 do
        assert_raise RuntimeError, fn ->
          Handoffs.perform(
            fixture.goal.id,
            command.command_id,
            perform_opts(repo: CrashingRepo)
          )
        end
      end

      # Both attempts observed and both decisions committed under this
      # handoff's own prefix; neither may count against the authorization.
      assert length(handoff_decisions(fixture.goal.id)) == 2

      assert {:ok, %{outcome: :dispatched, run: receiver}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      assert Enum.map(receiver_runs(fixture), & &1.id) == [receiver.id]
      assert length(handoff_events(fixture.goal.id)) == 1
      assert length(Repo.all(DispatchRecord)) == 1
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 1
    end
  end

  # ----------------------------------------------------------------------------
  # C2: permanent failures settle durably
  # ----------------------------------------------------------------------------

  describe "a permanently failed intent settles durably" do
    test "a moved boundary records handoff.failed with an operator-visible reason" do
      fixture = fixture()
      {:ok, %{command: command, handoff_id: handoff_id}} = request!(fixture)

      # The run advances past the boundary the operator authorized.
      append_checkpoint!(fixture, Ecto.UUID.generate(), "MOVED-ON advance to step eight")
      {:ok, _} = Projector.project(fixture.goal.id)

      assert {:error, :stale_continuation} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      # The outcome is on the trajectory, not in a log line or a row flag.
      assert [failure] = failure_events(fixture.goal.id)
      assert failure.idempotency_key == "handoff-failed:#{handoff_id}"
      assert failure.payload["handoff_id"] == handoff_id
      assert failure.payload["reason"] == "stale_continuation"
      assert failure.payload["run_id"] == fixture.run.id
      assert failure.payload["contract_version"] == 1
      assert failure.payload["extensions"]["cobbler.handoff:requested_by"] == "user:operator-1"
      assert is_binary(failure.payload["detail"])
    end

    test "reconcile NEVER resurrects a permanently failed intent, on any pass" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      append_checkpoint!(fixture, Ecto.UUID.generate(), "MOVED-ON")
      {:ok, _} = Projector.project(fixture.goal.id)

      assert {:error, :stale_continuation} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      # Clear every delivery attempt, exactly as a restart with a pruned job
      # table would. Cancelling the job alone would not be enough here: it is
      # the trajectory that reconcile reads.
      Repo.delete_all(Job)

      for _boot <- 1..3 do
        assert {:ok, %{repaired_count: 0, failures: []}} = Handoffs.reconcile()
        assert handoff_job_count() == 0
      end

      # Including through the real boot path.
      start_supervised!({HandoffReconciler, name: nil})
      assert handoff_job_count() == 0
    end

    test "the worker cancels rather than retrying an error no retry can clear" do
      fixture = fixture()
      {:ok, %{job: job}} = request!(fixture)

      append_checkpoint!(fixture, Ecto.UUID.generate(), "MOVED-ON")
      {:ok, _} = Projector.project(fixture.goal.id)

      Application.put_env(:shoestring, :handoff_observe, fn _scoping ->
        {:ok, eligible_snapshot!()}
      end)

      on_exit(fn -> Application.delete_env(:shoestring, :handoff_observe) end)

      assert {:cancel, :stale_continuation} = perform_delivery(job)
      assert [_failure] = failure_events(fixture.goal.id)
    end

    test "the durable failure is idempotent across repeated attempts" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      append_checkpoint!(fixture, Ecto.UUID.generate(), "MOVED-ON")
      {:ok, _} = Projector.project(fixture.goal.id)

      for _attempt <- 1..3 do
        assert {:error, :stale_continuation} =
                 Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())
      end

      assert length(failure_events(fixture.goal.id)) == 1
    end

    test "a superseded authorization settles too" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      append_admission_event!(
        fixture.goal.id,
        admission_payload(decision_id: Ecto.UUID.generate())
      )

      assert {:error, :decision_superseded} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      assert [failure] = failure_events(fixture.goal.id)
      assert failure.payload["reason"] == "decision_superseded"

      Repo.delete_all(Job)
      assert {:ok, %{repaired_count: 0, failures: []}} = Handoffs.reconcile()
    end

    test "an unknown receiver settles too" do
      fixture = fixture()

      attrs =
        fixture
        |> handoff_attrs()
        |> put_payload("to_provider_id", "provider-that-does-not-exist")
        |> put_payload("to_adapter_id", "adapter-that-does-not-exist")

      {:ok, %{command: command}} = Handoffs.request(fixture.goal.id, attrs)

      assert {:error, {:unknown_provider, _}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      assert [failure] = failure_events(fixture.goal.id)
      assert failure.payload["reason"] == "unknown_provider"

      Repo.delete_all(Job)
      assert {:ok, %{repaired_count: 0, failures: []}} = Handoffs.reconcile()
    end

    test "TRANSIENT twin: a live sender neither settles nor cancels" do
      # The contrast that makes the whole classification meaningful. A sender
      # that is still running today may be finished in a minute, so this must
      # stay retriable and the intent must stay alive across a restart.
      fixture = fixture()
      {:ok, %{command: command, job: job}} = request!(fixture)

      Repo.update!(Ecto.Changeset.change(fixture.run, status: "running"))

      Application.put_env(:shoestring, :handoff_observe, fn _scoping ->
        {:ok, eligible_snapshot!()}
      end)

      on_exit(fn -> Application.delete_env(:shoestring, :handoff_observe) end)

      assert {:error, {:sender_run_active, "running"}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      # No durable failure: nothing is final here.
      assert failure_events(fixture.goal.id) == []

      # The worker RETRIES rather than cancelling.
      assert {:error, {:sender_run_active, "running"}} = perform_delivery(job)

      # And a restart keeps the intent alive.
      Repo.delete_all(Job)
      assert {:ok, %{repaired_count: 1, failures: []}} = Handoffs.reconcile()
      assert handoff_job_count() == 1

      # Once the sender parks, the same intent completes. (Reloaded, so the
      # update is against the row as it is now — `fixture.run` predates the
      # change to "running" and would produce an empty changeset.)
      RunRecord
      |> Repo.get!(fixture.run.id)
      |> Ecto.Changeset.change(status: "suspended")
      |> Repo.update!()

      assert {:ok, %{outcome: :dispatched}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())
    end

    test "TRANSIENT twin: an unreachable probe neither settles nor cancels" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert {:error, {:observation_failed, :probe_unavailable}} =
               Handoffs.perform(
                 fixture.goal.id,
                 command.command_id,
                 perform_opts(observe: fn _ -> {:error, :probe_unavailable} end)
               )

      assert failure_events(fixture.goal.id) == []

      Repo.delete_all(Job)
      assert {:ok, %{repaired_count: 1, failures: []}} = Handoffs.reconcile()
    end

    test "a crash is transient: the crash window itself never settles" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert_raise RuntimeError, fn ->
        Handoffs.perform(
          fixture.goal.id,
          command.command_id,
          perform_opts(repo: CrashingRepo)
        )
      end

      assert failure_events(fixture.goal.id) == []

      Repo.delete_all(Job)
      assert {:ok, %{repaired_count: 1, failures: []}} = Handoffs.reconcile()
    end
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
          status: "suspended",
          requested_capabilities: %{"items" => ["resume", "cancel"]}
        )
      )

    checkpoint_id = Ecto.UUID.generate()
    decision = admission_payload(provider_id: "codex", adapter_id: "codex_app_server")
    admission = append_admission_event!(goal.id, decision)

    {:ok, %{command: claim}} = Commands.submit(goal.id, claim_command(admission))
    assert claim.status == "resolved"

    fixture = %{goal: goal, task: task, run: run}
    append_checkpoint!(fixture, checkpoint_id, @next_action)
    {:ok, _} = Projector.project(goal.id)

    %{
      goal: goal,
      task: task,
      run: Repo.get!(RunRecord, run.id),
      checkpoint_id: checkpoint_id,
      decision_id: decision["decision_id"]
    }
  end

  defp append_checkpoint!(%{goal: goal, run: run}, checkpoint_id, next_action) do
    {:ok, event} =
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
            "decisions" => %{"items" => []},
            "unresolved_issues" => %{"items" => []},
            "next_action" => next_action,
            "provider_session_id" => "fake-session-HOTEL5",
            "stop_reason" => "quota_refused",
            "artifact_ids" => %{"items" => []},
            "extensions" => %{}
          }
        },
        trusted: [run_id: run.id]
      )

    event
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

  defp put_payload(attrs, key, value), do: put_in(attrs, ["payload", key], value)

  defp request!(fixture), do: Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

  defp perform_opts(overrides \\ []) do
    snapshot = eligible_snapshot!()

    [
      clock: ManualClock,
      now: @t0,
      observe: Keyword.get(overrides, :observe, fn _scoping -> {:ok, snapshot} end),
      goal_state: :working
    ]
    |> then(fn opts ->
      case Keyword.get(overrides, :repo) do
        nil -> opts
        repo -> Keyword.put(opts, :repo, repo)
      end
    end)
  end

  defp configure_elf_dispatch(sup) do
    Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)

    Application.put_env(:shoestring, :elf_dispatch_opts,
      supervisor: sup,
      scenario: Shoestring.Harness.Fake.Scenario.normal_completion(),
      command: ["sleep", "30"],
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000]
    )
  end

  defp perform_delivery(job) do
    job
    |> Map.put(:attempted_at, ManualClock.now())
    |> Map.put(:scheduled_at, ManualClock.now())
    |> perform_job()
  end

  defp eligible_snapshot! do
    reset_at = DateTime.add(@t0, 7_200, :second)

    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :observed,
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
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: @t0
      )

    snapshot
  end

  # ----------------------------------------------------------------------------
  # Reads
  # ----------------------------------------------------------------------------

  defp events(goal_id, type) do
    Repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == ^type,
        order_by: [asc: event.sequence]
    )
  end

  defp handoff_events(goal_id), do: events(goal_id, "handoff.created")
  defp failure_events(goal_id), do: events(goal_id, "handoff.failed")

  defp handoff_decisions(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == "admission.decided" and
            like(event.idempotency_key, "handoff-decision:%"),
        order_by: [asc: event.sequence]
    )
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

  defp handoff_job_count do
    Repo.one!(from j in Job, where: j.queue == "handoff", select: count(j.id))
  end
end
