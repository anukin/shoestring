defmodule Shoestring.Cobbler.HandoffProdObserverTest do
  @moduledoc """
  The CONFIGURED production receiver-observation path, end to end.

  `config/runtime.exs` wires `:handoff_observe` for `:prod` to the MFA tuple
  `{Shoestring.Cobbler.WakeupObserve, :observe, []}`, which serves the
  receiver's capacity out of the `Shoestring.Harness.Observatory` ledger.
  Every test here installs that exact tuple and ingests the reading through
  the real Observatory, instead of injecting a snapshot fun the way
  `HandoffWorkerTest` does. Nothing is bypassed: the delivery goes through
  `Shoestring.Cobbler.HandoffWorker.perform/1`, never through
  `Handoffs.perform/3` directly.

  ## The defect these lock (base `733c39b`)

  Every snapshot the Observatory serves is ALREADY projected as a
  `CapacitySnapshotRecord` owned by the protected observatory singleton goal.
  `Handoffs` re-appends that reading as `capacity.snapshot_observed` under
  the USER's goal so the receiver's lease can chain to a snapshot its own
  goal owns — the locked "Strict Same-Goal Lease Ownership" rule. At base it
  re-appended it under the ORIGINAL snapshot id, so
  `Shoestring.Harness.Projector` found a row owned by another goal and failed
  with `{:capacity_snapshot_not_owned, id}`.

  Measured against base: **9 of the 12 tests here fail**, and every one of
  them fails on the behavioural reason —
  `{:error, {:harness_projection_failed, 6, {:capacity_snapshot_not_owned,
  _}}}` — not on a missing module or a changed signature. The 3 that pass at
  base are honestly not defect locks: the two fail-closed probe tests (empty
  ledger, foreign-provider-only ledger) and the `config/runtime.exs` file
  contract, none of which ever reached the projector.

  The blast radius is the point. The poisoned event is durable, so the goal's
  `harness` projector position is left at `status: "failed"` and every LATER
  projection of that goal re-reads it and fails again. One production handoff
  wedged the goal's projector permanently, while the receiver run row and
  dispatch row (written directly, not via projection) still existed — a goal
  left half-transferred and unprojectable. `"the goal's projector is not
  wedged"` locks that consequence specifically.

  Hermetic: Oban `testing: :manual`, the real Observatory ledger in the test
  repo, and no adapter start at all (the `dispatch` job is left unperformed —
  this file is about the handoff leg). Never a provider CLI, never the
  network, no provider quota.
  """
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Commands, HandoffWorker, Handoffs, WakeupObserve}

  alias Shoestring.Harness.{
    CapacitySnapshot,
    CapacitySnapshotRecord,
    DispatchRecord,
    ExecutionLeaseRecord,
    Observatory,
    Projector,
    RunRecord
  }

  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{ProjectorPosition, TrajectoryEvent}

  @t0 Shoestring.Test.FixedClock.now()

  @sender_provider "codex_app_server_stdio"
  @receiver_provider "fake"
  @receiver_adapter "shoestring.harness.fake"
  @receiver_scope "account:fake"

  # The production wiring, verbatim from the `:prod` block of
  # `config/runtime.exs`. Asserted rather than restated so a drift in that
  # file breaks this file too.
  @prod_observe {WakeupObserve, :observe, []}

  setup do
    previous = %{
      observe: Application.get_env(:shoestring, :handoff_observe),
      clock: Application.get_env(:shoestring, :dispatch_clock)
    }

    Application.put_env(:shoestring, :dispatch_clock, Shoestring.Test.FixedClock)
    Application.put_env(:shoestring, :handoff_observe, @prod_observe)

    on_exit(fn ->
      restore(:handoff_observe, previous.observe)
      restore(:dispatch_clock, previous.clock)
    end)

    :ok
  end

  describe "the configured production observer performs the transfer" do
    test "the worker observes through the Observatory ledger and dispatches" do
      fixture = fixture()
      ledger_snapshot = ingest_eligible!()

      # Precondition: the reading really is in the ledger, and the configured
      # probe really does serve it for this receiver's provider/scope.
      assert {:ok, %CapacitySnapshot{snapshot_id: served_id}} =
               WakeupObserve.observe(%{provider_id: @receiver_provider, scope: @receiver_scope})

      assert served_id == ledger_snapshot.snapshot_id

      {:ok, %{handoff_id: handoff_id, job: job}} =
        Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

      assert :ok = perform_delivery(job)

      receiver = receiver_run!(fixture)
      assert receiver.dispatch_id == handoff_id
      assert receiver.provider_id == @receiver_adapter
      assert receiver.status == "requested"

      assert [_pointer] = handoff_events(fixture.goal.id)
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1
    end

    test "the goal's projector is not wedged: it projects clean afterwards" do
      fixture = fixture()
      ingest_eligible!()

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))
      assert :ok = perform_delivery(job)

      # The consequence that made the defect more than one failed handoff:
      # at base the position was left `failed` and every later projection of
      # this goal re-read the poisoned event and failed again.
      position = Repo.get_by!(ProjectorPosition, goal_id: fixture.goal.id, projector: "harness")
      assert position.status != "failed"
      assert is_nil(position.error_detail)

      assert {:ok, _position} = Projector.project(fixture.goal.id)
      assert {:ok, _position} = Projector.project(fixture.goal.id)
    end

    test "the observation is owned by the goal, and carries its ledger provenance" do
      fixture = fixture()
      ledger_snapshot = ingest_eligible!()

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))
      assert :ok = perform_delivery(job)

      [event] = snapshot_events(fixture.goal.id)
      local_id = event.payload["snapshot_id"]

      # Re-identified, not reused: the goal records its OWN observation.
      refute local_id == ledger_snapshot.snapshot_id

      # Owned by THIS goal — which is what lets the lease chain to it without
      # weakening the same-goal rule.
      local_row = Repo.get!(CapacitySnapshotRecord, local_id)
      assert local_row.goal_id == fixture.goal.id

      # The observatory's own row is untouched and still owned by the
      # observatory: nothing was rewritten or taken over.
      ledger_row = Repo.get!(CapacitySnapshotRecord, ledger_snapshot.snapshot_id)
      assert ledger_row.goal_id == Observatory.observatory_goal_id()

      # Provenance is preserved: the goal-local observation can be joined
      # back to the ledger entry it was taken from.
      assert event.payload["extensions"]["cobbler.handoff:observed_snapshot_id"] ==
               ledger_snapshot.snapshot_id

      # Every other field of the reading is the reading, unchanged.
      assert event.payload["capacity_state"] == "observed"
      assert event.payload["scope"] == @receiver_scope
      assert event.payload["source"]["provider_id"] == @receiver_provider
    end

    test "the receiver's lease chains to the goal-owned observation" do
      fixture = fixture()
      ingest_eligible!()

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))
      assert :ok = perform_delivery(job)

      receiver = receiver_run!(fixture)
      lease = Repo.get_by!(ExecutionLeaseRecord, run_id: receiver.id)

      [event] = snapshot_events(fixture.goal.id)
      assert lease.admitted_snapshot_id == event.payload["snapshot_id"]
      assert lease.goal_id == fixture.goal.id

      snapshot_row = Repo.get!(CapacitySnapshotRecord, lease.admitted_snapshot_id)
      assert snapshot_row.goal_id == lease.goal_id
    end

    test "a second goal handing off the same ledger reading owns its own observation" do
      ledger_snapshot = ingest_eligible!()

      # The task claim is exclusive across goals, so the two transfers are
      # sequential: first goal claims and transfers, releases, then the
      # second goal claims and transfers the SAME ledger reading.
      first = fixture()
      {:ok, %{job: first_job}} = Handoffs.request(first.goal.id, handoff_attrs(first))
      assert :ok = perform_delivery(first_job)

      {:ok, %{command: released}} = Commands.submit(first.goal.id, release_command())
      assert released.status == "resolved"

      second = fixture()
      {:ok, %{job: second_job}} = Handoffs.request(second.goal.id, handoff_attrs(second))
      assert :ok = perform_delivery(second_job)

      [first_event] = snapshot_events(first.goal.id)
      [second_event] = snapshot_events(second.goal.id)

      # Derived per (goal, handoff, reading), so two goals observing the SAME
      # ledger entry never contend for one snapshot row.
      refute first_event.payload["snapshot_id"] == second_event.payload["snapshot_id"]

      assert Repo.get!(CapacitySnapshotRecord, first_event.payload["snapshot_id"]).goal_id ==
               first.goal.id

      assert Repo.get!(CapacitySnapshotRecord, second_event.payload["snapshot_id"]).goal_id ==
               second.goal.id

      for event <- [first_event, second_event] do
        assert event.payload["extensions"]["cobbler.handoff:observed_snapshot_id"] ==
                 ledger_snapshot.snapshot_id
      end
    end
  end

  describe "replay through the production observer is exact" do
    test "performing the same delivery twice converges: one of everything" do
      fixture = fixture()
      ingest_eligible!()

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

      assert :ok = perform_delivery(job)
      assert :ok = perform_delivery(job)

      assert length(receiver_runs(fixture)) == 1
      assert length(handoff_events(fixture.goal.id)) == 1
      assert length(snapshot_events(fixture.goal.id)) == 1
      assert length(decision_events(fixture.goal.id)) == 1
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1

      receiver = receiver_run!(fixture)

      assert Repo.aggregate(
               from(l in ExecutionLeaseRecord, where: l.run_id == ^receiver.id),
               :count,
               :id
             ) == 1
    end

    test "a re-observation of the same ledger reading collapses on its idempotency key" do
      fixture = fixture()
      ingest_eligible!()

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

      assert :ok = perform_delivery(job)
      [%TrajectoryEvent{idempotency_key: key, id: id}] = snapshot_events(fixture.goal.id)

      assert :ok = perform_delivery(job)

      # Same handoff, same reading → the SAME derived id, so the same
      # idempotency key, so one event. A non-deterministic id would have
      # appended a second observation on every retry.
      assert [%TrajectoryEvent{idempotency_key: ^key, id: ^id}] =
               snapshot_events(fixture.goal.id)
    end
  end

  describe "reconciliation reaches the production observer" do
    test "an intent whose delivery attempt was lost is repaired and then performs" do
      fixture = fixture()
      ingest_eligible!()

      {:ok, %{handoff_id: handoff_id, job: job}} =
        Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

      # Lose the delivery attempt, exactly as a crash between the command
      # commit and the Oban insert would.
      Repo.delete!(job)
      assert Repo.aggregate(from(j in Job, where: j.queue == "handoff"), :count, :id) == 0

      assert {:ok, %{repaired_count: 1, failures: []}} = Handoffs.reconcile()

      assert [restored] = Repo.all(from j in Job, where: j.queue == "handoff")
      assert restored.args["handoff_id"] == handoff_id

      assert :ok = perform_delivery(restored)

      assert length(receiver_runs(fixture)) == 1
      assert length(handoff_events(fixture.goal.id)) == 1
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1
    end

    test "a completed transfer is settled: reconcile never re-observes it" do
      fixture = fixture()
      ingest_eligible!()

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))
      assert :ok = perform_delivery(job)

      Repo.delete_all(from j in Job, where: j.queue == "handoff")

      assert {:ok, %{repaired_count: 0, failures: []}} = Handoffs.reconcile()
      assert Repo.aggregate(from(j in Job, where: j.queue == "handoff"), :count, :id) == 0
      assert length(snapshot_events(fixture.goal.id)) == 1
    end
  end

  describe "the production observer fails closed" do
    test "an empty ledger refuses with no decision and no effect" do
      fixture = fixture()

      # Nothing ingested at all.
      assert {:error, :no_observation} =
               WakeupObserve.observe(%{provider_id: @receiver_provider, scope: @receiver_scope})

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

      assert {:error, {:observation_failed, :no_observation}} = perform_delivery(job)

      assert snapshot_events(fixture.goal.id) == []
      assert decision_events(fixture.goal.id) == []
      assert receiver_runs(fixture) == []
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 0
    end

    test "a ledger holding only another provider's reading never admits on it" do
      fixture = fixture()
      foreign = ingest_foreign!()

      # The foreign reading IS in the ledger and IS the newest thing in it.
      assert {:ok, %CapacitySnapshot{snapshot_id: foreign_id}} =
               WakeupObserve.observe(%{provider_id: "other", scope: "account:other"})

      assert foreign_id == foreign.snapshot_id

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

      assert {:error, {:observation_failed, :no_observation_for_provider}} =
               perform_delivery(job)

      assert snapshot_events(fixture.goal.id) == []
      assert decision_events(fixture.goal.id) == []
      assert receiver_runs(fixture) == []
    end
  end

  test "config/runtime.exs still wires this exact MFA for :prod" do
    # The tuple this file installs is only meaningful if production installs
    # the same one. Read from the file so the two cannot drift apart.
    runtime = File.read!(Path.join([File.cwd!(), "config", "runtime.exs"]))

    assert runtime =~
             "config :shoestring, :handoff_observe, {Shoestring.Cobbler.WakeupObserve, :observe, []}"

    assert @prod_observe == {Shoestring.Cobbler.WakeupObserve, :observe, []}
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
          prompt: "implement the widget",
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
            "next_action" => "advance to step seven",
            "provider_session_id" => "codex-session-sender",
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
      run: Repo.get!(RunRecord, run.id),
      checkpoint_id: checkpoint_id,
      decision_id: decision["decision_id"]
    }
  end

  defp handoff_attrs(fixture, payload_overrides \\ %{}) do
    %{
      "command_id" => "cmd-handoff-" <> Ecto.UUID.generate(),
      "payload" =>
        Map.merge(
          %{
            "run_id" => fixture.run.id,
            "checkpoint_id" => fixture.checkpoint_id,
            "decision_refs" => [fixture.decision_id],
            "to_provider_id" => @receiver_provider,
            "to_adapter_id" => @receiver_adapter,
            "scope" => @receiver_scope,
            "reason" => "sender quota exhausted",
            "requested_by" => "user:operator-1"
          },
          payload_overrides
        )
    }
  end

  # ----------------------------------------------------------------------------
  # Observatory ledger
  # ----------------------------------------------------------------------------

  defp ingest_eligible! do
    snapshot = snapshot!(@receiver_provider, @receiver_adapter, @receiver_scope)
    {:ok, :persisted, _event} = Observatory.ingest(snapshot)
    snapshot
  end

  defp ingest_foreign! do
    snapshot = snapshot!("other", "other_adapter", "account:other")
    {:ok, :persisted, _event} = Observatory.ingest(snapshot)
    snapshot
  end

  defp snapshot!(provider_id, adapter_id, scope) do
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
            adapter_id: adapter_id,
            provider_id: provider_id,
            invocation_mode: "headless",
            event: :explicit_read
          },
          scope: scope,
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

  defp snapshot_events(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == "capacity.snapshot_observed" and
            like(event.idempotency_key, "handoff-snapshot:%"),
        order_by: [asc: event.sequence]
    )
  end

  defp decision_events(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == "admission.decided" and
            like(event.idempotency_key, "handoff-decision:%"),
        order_by: [asc: event.sequence]
    )
  end

  defp perform_delivery(%Job{} = job) do
    job
    |> Map.put(:attempted_at, @t0)
    |> Map.put(:scheduled_at, @t0)
    |> perform_job()
  end

  defp restore(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore(key, value), do: Application.put_env(:shoestring, key, value)

  # Silences the "unused" warning for the worker module this file exercises
  # only through `perform_job/1`.
  @doc false
  def worker, do: HandoffWorker
end
