defmodule Shoestring.Cobbler.HandoffProductionTest do
  @moduledoc """
  Hermetic tests for production cross-provider handoff
  (`Shoestring.Cobbler.Handoffs`).

  Fake adapter and local state only: no provider CLI, no network, no live
  run, no provider quota spent. The Oban `dispatch` job is asserted as a
  persisted delivery attempt; it is never executed here, so no Elf and no
  adapter call happens in this suite.

  ## What each group locks

  - **Intent before effects.** `request/3` writes a `run.handoff` command row
    and nothing else — zero `handoff.created`, zero receiver runs, zero
    dispatches, zero leases.
  - **Production transfer.** `perform/3` observes the receiver's capacity,
    persists `admission.decided`, creates the receiver run, grants the
    receiver its OWN lease, appends `handoff.created` with source/receiver/
    projection version/prior run/grant, and enqueues ONE durable dispatch.
    The adapter is never started directly.
  - **Honest admission.** A degraded or incompatible receiver refuses with
    the decision persisted and no receiver run, lease or dispatch. An
    attributable override lifts a confirmation-class refusal; an
    unattributed one does not; neither lifts a hard stop.
  - **Boundary + one active Elf.** A superseded checkpoint refuses as
    `:stale_continuation`; a sender still `running` refuses as
    `:sender_run_active`. Neither leaves any effect behind.
  - **Idempotence.** Performing twice converges on one handoff, one receiver
    run, one dispatch, one lease.
  - **Privacy, both directions.** The receiver's prompt carries the
    checkpoint pointer, `next_action` and decision refs, and carries neither
    the sender's transcript text nor the sender's provider session id.

  ## Lock-vs-documentation ledger (base `01f2a54`)

  Every test here is a TRUE behavioural lock against base: `Handoffs` does
  not exist on base, and base's only handoff path
  (`Shoestring.Elves.resume_run/2`) performs no observation, no admission,
  no receiver lease and no durable dispatch. Base-failure for the right
  behavioural reason is recorded in
  `plans/evidence/05-quota-aware-mvp/handoff-production.md`; because the
  module is new surface, base failure surfaces as
  `UndefinedFunctionError`, which is DOCUMENTATION strength for the
  new-module arms and a genuine behavioural lock only for the arms that also
  assert against the durable pipeline (dispatch rows, lease rows, decision
  events) that base never produces for a handoff.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Commands, Handoffs}

  alias Shoestring.Harness.{
    CapacitySnapshot,
    Contract,
    Continuation,
    DispatchRecord,
    ExecutionLeaseRecord,
    Projector,
    RunRecord
  }

  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.ManualClock
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @t0 ~U[2026-09-07 12:00:00.000000Z]

  @sender_provider "shoestring.harness.fake"
  @receiver_provider "fake-receiver"
  @receiver_adapter "shoestring.harness.fake"
  @receiver_scope "account:fake-receiver"

  @sender_transcript_marker "SENDER-TRANSCRIPT-DELTA9"
  @sender_session "fake-session-sender-DELTA9"
  @next_action_marker "NEXTACTION-ECHO9"

  setup do
    ManualClock.set(@t0)
    previous_clock = Application.get_env(:shoestring, :dispatch_clock)
    Application.put_env(:shoestring, :dispatch_clock, ManualClock)

    on_exit(fn ->
      case previous_clock do
        nil -> Application.delete_env(:shoestring, :dispatch_clock)
        value -> Application.put_env(:shoestring, :dispatch_clock, value)
      end
    end)

    :ok
  end

  # ----------------------------------------------------------------------------
  # Intent before effects
  # ----------------------------------------------------------------------------

  describe "request/3 records durable intent and nothing else" do
    test "the command row exists; no handoff, run, lease or dispatch does" do
      fixture = fixture()

      assert {:ok, %{command: command, handoff_id: handoff_id, outcome: :recorded}} =
               Handoffs.request(fixture.goal.id, handoff_attrs(fixture))

      assert command.type == "run.handoff"
      assert command.status == "resolved"
      assert command.result["kind"] == "handoff_requested"
      assert command.result["to_provider_id"] == @receiver_provider
      assert command.result["requested_by"] == "user:operator-1"
      assert handoff_id == command.id

      # Intent only: not one effect.
      assert handoff_events(fixture.goal.id) == []
      assert run_ids(fixture.goal.id) == [fixture.run.id]
      assert dispatch_count() == 0
      assert lease_count(fixture.goal.id) == 0
      assert job_count() == 0
    end

    test "re-requesting the same command id replays the intent without new events" do
      fixture = fixture()
      attrs = handoff_attrs(fixture)

      assert {:ok, %{command: first, outcome: :recorded}} =
               Handoffs.request(fixture.goal.id, attrs)

      before = command_event_count(fixture.goal.id)

      assert {:ok, %{command: second, outcome: :replayed}} =
               Handoffs.request(fixture.goal.id, attrs)

      assert second.id == first.id
      assert command_event_count(fixture.goal.id) == before
    end

    test "a handoff naming the sender's own provider is rejected, not recorded as intent" do
      fixture = fixture()

      attrs =
        fixture
        |> handoff_attrs()
        |> put_payload("to_provider_id", @sender_provider)

      assert {:ok, %{command: command}} = Handoffs.request(fixture.goal.id, attrs)
      assert command.status == "rejected"
      assert command.result["reason"] == "handoff_same_provider"

      assert {:error, {:handoff_not_requested, detail}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      assert detail["status"] == "rejected"
      assert dispatch_count() == 0
    end

    test "a checkpoint belonging to another run is rejected as a boundary" do
      fixture = fixture()
      other_run = FakeHelpers.insert_run_record(fixture.goal, fixture.task, Ecto.UUID.generate())

      attrs =
        fixture
        |> handoff_attrs()
        |> put_payload("run_id", other_run.id)

      assert {:ok, %{command: command}} = Handoffs.request(fixture.goal.id, attrs)
      assert command.status == "rejected"
      assert command.result["reason"] == "handoff_checkpoint_run_mismatch"
    end
  end

  # ----------------------------------------------------------------------------
  # Production transfer
  # ----------------------------------------------------------------------------

  describe "perform/3 executes the production transfer" do
    test "observes, admits, creates, grants, points and dispatches — exactly once" do
      fixture = fixture()
      {:ok, %{command: command, handoff_id: handoff_id}} = request!(fixture)

      assert {:ok, result} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      assert result.outcome == :dispatched
      assert result.handoff_id == handoff_id
      assert result.decision_result == :admit
      assert result.lease == :granted

      # Fresh observation for the RECEIVER, persisted.
      assert [snapshot_event] = events(fixture.goal.id, "capacity.snapshot_observed")
      assert snapshot_event.idempotency_key =~ "handoff-snapshot:#{handoff_id}:"

      # Honest fresh admission for the RECEIVER, persisted.
      assert [decision_event] = handoff_decisions(fixture.goal.id)
      assert decision_event.payload["result"] == "admit"
      assert decision_event.payload["candidate"]["provider_id"] == @receiver_provider

      # Receiver run: a NEW run of the SAME goal and task, never the sender.
      receiver = Repo.get!(RunRecord, result.run.id)
      refute receiver.id == fixture.run.id
      assert receiver.goal_id == fixture.goal.id
      assert receiver.task_id == fixture.task.id
      assert receiver.dispatch_id == handoff_id
      assert receiver.status == "requested"

      # The receiver's OWN granted lease, chained to the fresh snapshot.
      lease = Repo.get_by!(ExecutionLeaseRecord, run_id: receiver.id)
      assert lease.status in ["granted", "active"]
      assert lease.extensions["cobbler.lease:handoff_id"] == handoff_id
      assert lease.admitted_snapshot_id == snapshot_event.payload["snapshot_id"]
      refute Repo.get_by(ExecutionLeaseRecord, run_id: fixture.run.id)

      # The canonical pointer: source, receiver, projection version, grant.
      assert [pointer] = handoff_events(fixture.goal.id)
      assert pointer.idempotency_key == "handoff:" <> handoff_id
      assert pointer.payload["from_provider_id"] == @sender_provider
      assert pointer.payload["to_provider_id"] == @receiver_provider
      assert pointer.payload["contract_version"] == 1
      assert pointer.payload["checkpoint_id"] == fixture.checkpoint_id
      assert pointer.payload["prior_run_id"] == fixture.run.id
      assert pointer.payload["run_id"] == receiver.id
      assert pointer.payload["lease_grant_id"] == lease.id
      assert pointer.payload["decision_refs"] == [fixture.decision_id]
      assert pointer.payload["extensions"]["cobbler.handoff:requested_by"] == "user:operator-1"

      # ONE durable supervised dispatch: a row and a delivery attempt. No
      # adapter was started here — the run is still `requested`.
      assert [dispatch] = Repo.all(DispatchRecord)
      assert dispatch.run_id == receiver.id
      assert dispatch.dispatch_id == handoff_id
      assert dispatch.job_id
      assert [job] = Repo.all(Job)
      assert job.queue == "dispatch"
      assert job.id == dispatch.job_id
      assert result.dispatch_id == dispatch.dispatch_id
    end

    test "performing twice converges: one handoff, one receiver, one dispatch, one lease" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert {:ok, %{outcome: :dispatched, run: first}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      assert {:ok, %{outcome: :converged, run: second}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      assert second.id == first.id
      assert length(handoff_events(fixture.goal.id)) == 1
      assert length(Repo.all(DispatchRecord)) == 1
      assert job_count() == 1
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 1
      assert run_ids(fixture.goal.id) |> length() == 2

      # A convergent retry re-observes nothing and re-admits nothing: the
      # transfer decision already committed.
      assert length(handoff_decisions(fixture.goal.id)) == 1
      assert length(events(fixture.goal.id, "capacity.snapshot_observed")) == 1
    end

    test "the dispatch is gated on the live claim: a lost claim performs no effect" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      {:ok, _} =
        Commands.submit(fixture.goal.id, release_command("operator released for the test"))

      assert {:error, {:handoff_claim_lost, _}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      assert dispatch_count() == 0
      assert handoff_events(fixture.goal.id) == []
    end
  end

  # ----------------------------------------------------------------------------
  # Honest admission for the receiver
  # ----------------------------------------------------------------------------

  describe "receiver admission is fresh and honest" do
    test "a degraded receiver refuses with the decision persisted and no effect" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert {:ok, result} =
               Handoffs.perform(
                 fixture.goal.id,
                 command.command_id,
                 perform_opts(snapshot: degraded_snapshot!())
               )

      assert result.outcome == :refused
      assert result.decision_result == :require_confirmation
      assert is_binary(result.reason_code)

      # Auditable, not silent: the decision IS on the trajectory.
      assert [decision] = handoff_decisions(fixture.goal.id)
      assert decision.payload["result"] == "require_confirmation"

      # And nothing was transferred.
      assert handoff_events(fixture.goal.id) == []
      assert run_ids(fixture.goal.id) == [fixture.run.id]
      assert dispatch_count() == 0
      assert lease_count(fixture.goal.id) == 0
    end

    test "an attributable override lifts the confirmation refusal; an unattributed one does not" do
      # Both arms share one goal: the task claim is globally exclusive, so a
      # second goal could not hold it and would refuse at the gate instead of
      # at the override, which is not what this test is about.
      fixture = fixture()
      {:ok, %{command: unattributed}} = request!(fixture)

      assert {:ok, %{outcome: :refused}} =
               Handoffs.perform(
                 fixture.goal.id,
                 unattributed.command_id,
                 perform_opts(
                   snapshot: degraded_snapshot!(),
                   override: %{"confirmed_by" => "   "}
                 )
               )

      assert dispatch_count() == 0

      {:ok, %{command: attributed}} = request!(fixture)

      assert {:ok, %{outcome: :dispatched, decision_id: decision_id}} =
               Handoffs.perform(
                 fixture.goal.id,
                 attributed.command_id,
                 perform_opts(
                   snapshot: degraded_snapshot!(),
                   override: %{
                     "confirmed_by" => "user:operator-1",
                     "target_provider_id" => @receiver_provider,
                     "target_scope" => @receiver_scope,
                     "intent" => "manual_execution"
                   }
                 )
               )

      # Attribution is persisted with the decision it authorized.
      assert [_refusal, decision] = handoff_decisions(fixture.goal.id)
      assert decision.payload["decision_id"] == decision_id
      assert decision.payload["override"]["confirmed_by"] == "user:operator-1"
      assert decision.payload["override"]["valid"] == true
    end

    test "an incompatible receiver is a hard stop that no override can lift" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert {:ok, result} =
               Handoffs.perform(
                 fixture.goal.id,
                 command.command_id,
                 perform_opts(
                   snapshot: incompatible_snapshot!(),
                   override: %{
                     "confirmed_by" => "user:operator-1",
                     "target_provider_id" => @receiver_provider,
                     "target_scope" => @receiver_scope
                   }
                 )
               )

      assert result.outcome == :refused
      assert result.decision_result == :reject
      assert result.reason_code == "incompatible_cli"
      assert dispatch_count() == 0
      assert run_ids(fixture.goal.id) == [fixture.run.id]
    end

    test "an unobservable receiver is not admitted and leaves no decision" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert {:error, {:observation_failed, :probe_unavailable}} =
               Handoffs.perform(
                 fixture.goal.id,
                 command.command_id,
                 perform_opts(observe: fn _scoping -> {:error, :probe_unavailable} end)
               )

      assert handoff_decisions(fixture.goal.id) == []
      assert dispatch_count() == 0
    end

    test "with no observer configured at all the handoff fails closed" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      opts = perform_opts() |> Keyword.delete(:observe)

      assert {:error, {:observation_failed, :missing_observe_fun}} =
               Handoffs.perform(fixture.goal.id, command.command_id, opts)

      assert dispatch_count() == 0
    end

    test "the receiver candidate takes its tier and compatibility from the observation" do
      # Guards the fail-open default: `AdmissionEvaluation` defaults an
      # undeclared candidate to :proactive/:compatible. If the handoff ever
      # stops sourcing these from the snapshot, this degraded observation
      # would admit instead of asking for confirmation.
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert {:ok, %{outcome: :refused}} =
               Handoffs.perform(
                 fixture.goal.id,
                 command.command_id,
                 perform_opts(snapshot: degraded_snapshot!())
               )

      assert [decision] = handoff_decisions(fixture.goal.id)
      assert decision.payload["candidate"]["compatibility_state"] == "degraded"
    end
  end

  # ----------------------------------------------------------------------------
  # Boundary and single-Elf rules
  # ----------------------------------------------------------------------------

  describe "checkpoint boundary and one active Elf" do
    test "a superseded checkpoint refuses as stale with no effect" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      # The run advances past the boundary the operator authorized.
      append_checkpoint!(fixture, Ecto.UUID.generate(), "MOVED-ON advance to step eight")
      {:ok, _} = Projector.project(fixture.goal.id)

      assert {:error, :stale_continuation} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      assert handoff_events(fixture.goal.id) == []
      assert dispatch_count() == 0
      assert handoff_decisions(fixture.goal.id) == []
    end

    test "a sender still running refuses: handoff never races or interrupts the Elf" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      Repo.update!(Ecto.Changeset.change(fixture.run, status: "running"))

      assert {:error, {:sender_run_active, "running"}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      assert handoff_events(fixture.goal.id) == []
      assert dispatch_count() == 0
      assert lease_count(fixture.goal.id) == 0
    end

    test "a live sender Elf refuses even when the run row already looks settled" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert {:error, {:sender_elf_active, run_id}} =
               Handoffs.perform(
                 fixture.goal.id,
                 command.command_id,
                 perform_opts(sender_elf: true)
               )

      assert run_id == fixture.run.id
      assert dispatch_count() == 0
    end

    test "an unresumable sender lease refuses before any observation" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert {:error, :lease_not_resumable} =
               Handoffs.perform(
                 fixture.goal.id,
                 command.command_id,
                 perform_opts(lease_status: "revoked")
               )

      assert events(fixture.goal.id, "capacity.snapshot_observed") == []
      assert dispatch_count() == 0
    end
  end

  # ----------------------------------------------------------------------------
  # Privacy
  # ----------------------------------------------------------------------------

  describe "the receiver gets the projection, never the sender's transcript" do
    test "required context present AND sensitive sender context absent" do
      fixture = fixture()
      {:ok, %{command: command}} = request!(fixture)

      assert {:ok, %{run: inserted}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      # Reloaded, so the assertions are about what was PERSISTED.
      receiver = Repo.get!(RunRecord, inserted.id)

      # Required, both in the prompt and in the structured continuation.
      assert receiver.prompt =~ fixture.checkpoint_id
      assert receiver.prompt =~ @next_action_marker
      assert receiver.prompt =~ fixture.decision_id
      assert receiver.continuation["checkpoint_id"] == fixture.checkpoint_id
      assert receiver.continuation["decision_refs"] == [fixture.decision_id]

      assert Enum.sort(Map.keys(receiver.continuation)) ==
               ["checkpoint_id", "decision_refs", "next_action"]

      # Removed: the sender's transcript and its session identity.
      refute receiver.prompt =~ @sender_transcript_marker
      refute receiver.prompt =~ @sender_session
      refute receiver.provider_session_id == @sender_session
      refute inspect(receiver.extensions) =~ @sender_session
      refute Map.has_key?(receiver.extensions, "wakeup:resume_prior_session_id")

      # The prompt is bounded and secret-free, and carries no sender content.
      assert String.length(receiver.prompt) <= Continuation.handoff_prompt_max_chars()
      assert Contract.safe_term?(%{"prompt" => receiver.prompt})

      # The pointer event carries provenance and no transcript-scale content.
      assert [pointer] = handoff_events(fixture.goal.id)
      assert Contract.safe_term?(pointer.payload)
      refute inspect(pointer.payload) =~ @sender_transcript_marker
      refute inspect(pointer.payload) =~ @sender_session

      for key <- Continuation.forbidden_keys() do
        refute Map.has_key?(pointer.payload, Atom.to_string(key))
      end
    end

    test "a resume-prior-session hint on the sender is not carried to the receiver" do
      fixture = fixture()

      Repo.update!(
        Ecto.Changeset.change(fixture.run,
          extensions: %{
            "wakeup:resume_prior_session_id" => @sender_session,
            "sender.note:keep" => "me"
          }
        )
      )

      {:ok, %{command: command}} = request!(fixture)

      assert {:ok, %{run: inserted}} =
               Handoffs.perform(fixture.goal.id, command.command_id, perform_opts())

      receiver = Repo.get!(RunRecord, inserted.id)

      refute Map.has_key?(receiver.extensions, "wakeup:resume_prior_session_id")
      assert receiver.extensions["sender.note:keep"] == "me"
      assert receiver.extensions["cobbler.handoff:from_provider_id"] == @sender_provider
      assert receiver.extensions["cobbler.handoff:to_provider_id"] == @receiver_provider
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
          prompt: "#{@sender_transcript_marker} implement the widget",
          status: "suspended",
          requested_capabilities: %{"items" => ["resume", "cancel"]}
        )
      )

    checkpoint_id = Ecto.UUID.generate()
    decision = admission_payload(provider_id: "codex", adapter_id: "codex_app_server")
    admission = append_admission_event!(goal.id, decision)

    # The goal holds the live exclusive claim: every dispatch entrypoint,
    # including this one, is gated on it.
    {:ok, %{command: claim}} = Commands.submit(goal.id, claim_command(admission))
    assert claim.status == "resolved"

    append_checkpoint!(
      %{goal: goal, run: run},
      checkpoint_id,
      "#{@next_action_marker} advance to step seven"
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
            "decisions" => %{"items" => ["chose approach A"]},
            "unresolved_issues" => %{"items" => []},
            "next_action" => next_action,
            "provider_session_id" => @sender_session,
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
        "to_provider_id" => @receiver_provider,
        "to_adapter_id" => @receiver_adapter,
        "scope" => @receiver_scope,
        "reason" => "sender quota exhausted",
        "requested_by" => "user:operator-1"
      }
    }
  end

  defp put_payload(attrs, key, value),
    do: put_in(attrs, ["payload", key], value)

  defp request!(fixture) do
    {:ok, result} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))
    {:ok, result}
  end

  defp perform_opts(overrides \\ []) do
    snapshot = Keyword.get_lazy(overrides, :snapshot, &eligible_snapshot!/0)

    [
      clock: ManualClock,
      now: @t0,
      observe: Keyword.get(overrides, :observe, fn _scoping -> {:ok, snapshot} end),
      goal_state: :working
    ]
    |> maybe_put(:override, Keyword.get(overrides, :override))
    |> maybe_put(:sender_elf, Keyword.get(overrides, :sender_elf))
    |> maybe_put(:lease_status, Keyword.get(overrides, :lease_status))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # ----------------------------------------------------------------------------
  # Snapshots
  # ----------------------------------------------------------------------------

  defp eligible_snapshot! do
    snapshot!(
      capacity_state: :observed,
      compatibility_state: :compatible,
      confidence: :high,
      reason: nil
    )
  end

  # `CapacitySnapshot` refuses to call a degraded/incompatible reading
  # `:observed`, so these carry the degraded capacity state and its required
  # reason. That is what an honest receiver observation looks like.
  defp degraded_snapshot! do
    snapshot!(
      capacity_state: :degraded,
      compatibility_state: :degraded,
      confidence: :medium,
      reason: "receiver CLI reported a degraded adapter surface"
    )
  end

  defp incompatible_snapshot! do
    snapshot!(
      capacity_state: :degraded,
      compatibility_state: :incompatible,
      confidence: :medium,
      reason: "receiver CLI version is incompatible with this adapter"
    )
  end

  defp snapshot!(opts) do
    reset_at = DateTime.add(@t0, 7_200, :second)

    attrs = %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: Keyword.fetch!(opts, :capacity_state),
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
      confidence: Keyword.fetch!(opts, :confidence),
      support_tier: :proactive,
      compatibility_state: Keyword.fetch!(opts, :compatibility_state),
      reason: Keyword.fetch!(opts, :reason),
      extensions: %{}
    }

    {:ok, snapshot} = CapacitySnapshot.new(attrs, now: @t0)
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

  # The fixture seeds the goal's own `admission.decided` (the claim's), so
  # handoff decisions are read by their handoff-scoped idempotency key —
  # never by "the goal has an admission event".
  defp handoff_decisions(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == "admission.decided" and
            like(event.idempotency_key, "handoff-decision:%"),
        order_by: [asc: event.sequence]
    )
  end

  defp command_event_count(goal_id),
    do: event_count(goal_id, ["cobbler.command.accepted", "cobbler.command.resolved"])

  defp run_ids(goal_id) do
    Repo.all(from run in RunRecord, where: run.goal_id == ^goal_id, select: run.id)
  end

  defp dispatch_count, do: Repo.aggregate(DispatchRecord, :count, :dispatch_id)

  defp lease_count(goal_id) do
    Repo.one!(
      from lease in ExecutionLeaseRecord,
        where: lease.goal_id == ^goal_id,
        select: count(lease.id)
    )
  end

  defp job_count, do: Repo.aggregate(Job, :count, :id)
end
