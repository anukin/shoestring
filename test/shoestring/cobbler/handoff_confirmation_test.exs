defmodule Shoestring.Cobbler.HandoffConfirmationTest do
  @moduledoc """
  The operator's confirmation travels on the durable `run.handoff` intent, so
  a confirmation-class receiver refusal is answerable through the PRODUCTION
  delivery path — and it carries no caller-authored identity.

  Hermetic: `Fake` sender, injected snapshots, no provider CLI, no network,
  no Elf, no quota. The receiver dispatch is asserted as a persisted row and
  a queued delivery attempt; it is never executed here.

  ## Why this exists

  `Shoestring.Cobbler.Handoffs.perform/3` reads the operator's confirmation
  from `opts[:override]`. `Shoestring.Cobbler.HandoffWorker` — the only thing
  that consumes a handoff intent in production — passes no such option and
  has no channel for one. Any receiver whose measured capacity is less than
  automatically safe therefore produced `require_confirmation` forever, no
  matter what the operator decided, and the transfer was unreachable.

  That is not a hypothetical class. The production Claude capacity source
  (`Shoestring.Harness.Capacity.ClaudeMonitor`) is passive by design and
  declares `support_tier: :conservative_partial` unconditionally
  (`claude_monitor.ex`, `support_tier/0`), so EVERY Claude receiver lands in
  it. Observed live: see
  `plans/evidence/05-quota-aware-mvp/live-cross-provider-handoff.md`.

  ## The attribution rule these tests hold

  The payload says THAT it confirms (`intent`) and nothing about WHO. A
  string in a request body is an assertion by the requester, not an
  authenticated identity, and admission treats `confirmed_by` as attribution
  that can lift a refusal — so accepting one would let a caller mint an
  operator, or a `system:` principal, for itself. `confirmed_by` is derived
  in `Shoestring.Cobbler.Commands` from the goal's durable `owner_id`; the
  target provider and scope are derived from the same payload's receiver.
  A goal with no owner is refused rather than attributed to nobody.

  ## Lock-vs-documentation ledger

  Measured against base `6f1653fed931d120d463676ec40e95e6b8ad7327`, where the
  `confirmation` key is silently dropped from the payload — accepted, then
  ignored.

  **TRUE behavioural locks** (base reaches the same surface and does the
  wrong thing there):

    * `"the production worker admits a confirmation-class receiver …"` and
      `"a matching intent is not blocked"` — base refuses with
      `require_confirmation` and writes no `handoff.created`.
    * `"confirmed_by is derived from the goal owner, not from the request"` —
      base writes no `handoff.created`, so there is no decision to carry an
      attribution and no confirmation on the intent either.
    * `"a goal with no usable owner … is refused"` — base records the intent
      as `resolved`.
    * every test in `"the confirmation is rejected at request time"` — base
      records each of these intents as `resolved`, silently discarding the
      field it should have refused.
    * `"re-submitting the same command id with a different confirmation is a
      conflict"` and `"adding a confirmation to a previously unconfirmed
      command id is a conflict"` — base computes the same digest either way,
      so the second submission replays instead of conflicting.
    * `"a confirmation whose intent is not the requested capability refuses
      permanently"` — base never reaches the check and settles nothing.

  **DOCUMENTATION, not locks** (these pass on base too; they are the
  both-directions controls that keep the fix from being fail-open):

    * `"without a confirmation the same intent is refused, and leaves no
      effect behind"` — the control the locks are measured against.
    * every test in `"a confirmation never lifts a hard stop"` — base also
      refuses, for the different reason that it has no confirmation at all.
      They are here so the fix cannot later be widened into one that does
      lift a hard stop. Two of them (`scope_mismatch`,
      `unsupported_capability`) assert against `AdmissionEvaluation`
      directly, because `Handoffs.perform/3` derives both sides of each
      comparison from the same intent and cannot construct the mismatch;
      the moduledoc of that group says so.
    * `"a null owner is impossible at the schema, so the nil branch stays
      defensive"` — a schema fact, true on base too.
    * `"an explicit :override option still wins over the intent"` — the
      in-process path base already had.
    * `"an intent with no confirmation keeps the payload it always had"` and
      `"an identical re-submission replays with no duplicate effects"` — base
      behaves the same; they lock the no-churn and idempotence properties of
      the change, not a repaired defect.

  The exact base output is recorded in
  `plans/evidence/05-quota-aware-mvp/live-cross-provider-handoff.md` §7.1.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Command, CommandRecord, Commands, Handoffs, HandoffWorker}

  alias Shoestring.Harness.{
    CapacitySnapshot,
    DispatchRecord,
    ExecutionLeaseRecord,
    Projector,
    RunRecord
  }

  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

  @t0 ~U[2026-09-21 12:00:00.000000Z]

  @sender_provider "shoestring.harness.fake"
  @receiver_provider "claude"
  @receiver_adapter "claude_headless_stream_json"
  @receiver_scope "subscription"

  setup do
    previous = Application.get_env(:shoestring, :handoff_observe)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:shoestring, :handoff_observe)
        value -> Application.put_env(:shoestring, :handoff_observe, value)
      end
    end)

    :ok
  end

  # ----------------------------------------------------------------------------
  # The lock
  # ----------------------------------------------------------------------------

  describe "an attributable confirmation on the durable intent" do
    test "the production worker admits a confirmation-class receiver when the intent carries one" do
      fixture = fixture()
      observe!(conservative_partial_snapshot!())

      {:ok, handoff_id} = request!(fixture, confirmation: confirmation())

      assert :ok = HandoffWorker.perform(job!(handoff_id))

      # The transfer happened: pointer, receiver run, receiver lease, one
      # durable dispatch.
      assert [pointer] = events(fixture.goal.id, "handoff.created")
      assert pointer.payload["to_provider_id"] == @receiver_provider
      assert pointer.payload["prior_run_id"] == fixture.run.id

      receiver = Repo.get!(RunRecord, pointer.payload["run_id"])
      assert receiver.provider_id == @receiver_adapter
      refute receiver.id == fixture.run.id

      assert %ExecutionLeaseRecord{} = Repo.get_by(ExecutionLeaseRecord, run_id: receiver.id)
      assert [dispatch] = Repo.all(DispatchRecord)
      assert dispatch.run_id == receiver.id

      # And it happened as an ATTRIBUTED confirmation, not as an automatic
      # admit: the persisted decision says the admission was not
      # automatically safe.
      assert [decision] = handoff_decisions(fixture.goal.id)
      assert decision.payload["result"] == "admit"
      assert decision.payload["reason_code"] == "confirmed_support_tier_conservative_partial"
      assert decision.payload["override"]["valid"] == true
      assert decision.payload["override"]["target_provider_id"] == @receiver_provider
      assert decision.payload["override"]["target_scope"] == @receiver_scope
    end

    test "confirmed_by is derived from the goal owner, not from the request" do
      fixture = fixture()
      observe!(conservative_partial_snapshot!())

      {:ok, _handoff_id} = request!(fixture, confirmation: confirmation())
      assert :ok = HandoffWorker.perform(job!(handoff_id_of(fixture.goal.id)))

      expected = "owner:" <> fixture.goal.owner_id

      # On the durable intent…
      command = handoff_command(fixture.goal.id)
      assert command.result["confirmation"]["confirmed_by"] == expected
      # …and on the decision admission actually took.
      assert [decision] = handoff_decisions(fixture.goal.id)
      assert decision.payload["override"]["confirmed_by"] == expected

      # The request never mentioned it, and the payload still does not.
      assert command.payload["confirmation"] == %{"intent" => "supervised_execution"}
    end

    test "a goal with no usable owner has no principal to attribute to, and is refused" do
      fixture = fixture()

      # The protected Observatory principal is not an operator. Written with
      # `update_all` deliberately: `Goal.changeset/2` refuses observatory
      # identity, so this is the state a direct write could still produce.
      {1, _} =
        Repo.update_all(
          from(goal in Goal, where: goal.id == ^fixture.goal.id),
          set: [owner_id: Shoestring.Harness.Observatory.observatory_owner_id()]
        )

      assert {:ok, %{command: command, job: nil}} = submit(fixture, confirmation: confirmation())
      assert command.status == "rejected"
      assert command.result["reason"] == "handoff_confirmation_unattributable"
      assert job_count() == 0
      assert events(fixture.goal.id, "handoff.created") == []
    end

    test "a null owner is impossible at the schema, so the nil branch stays defensive" do
      fixture = fixture()

      # `goals.owner_id` is `null: false`
      # (`20260830012112_create_trajectory_foundation.exs`), so the nil arm of
      # `trusted_confirmed_by/2` cannot be reached through the database. It is
      # kept as belt-and-braces, and this test records WHY it has no
      # behavioural row of its own rather than leaving the gap unexplained.
      assert_raise Exqlite.Error, fn ->
        Repo.update_all(
          from(goal in Goal, where: goal.id == ^fixture.goal.id),
          set: [owner_id: nil]
        )
      end
    end

    test "without a confirmation the same intent is refused, and leaves no effect behind" do
      fixture = fixture()
      observe!(conservative_partial_snapshot!())

      {:ok, handoff_id} = request!(fixture)

      # A recorded refusal is a successful production outcome, so the worker
      # reports :ok and settles rather than retrying behind the operator.
      assert :ok = HandoffWorker.perform(job!(handoff_id))

      assert [decision] = handoff_decisions(fixture.goal.id)
      assert decision.payload["result"] == "require_confirmation"
      assert decision.payload["reason_code"] == "support_tier_conservative_partial"

      assert no_transfer_effects!(fixture)
    end
  end

  # ----------------------------------------------------------------------------
  # A confirmation never lifts a hard stop
  # ----------------------------------------------------------------------------

  # One row per unbypassable constraint in
  # `AdmissionEvaluation.check_hard_constraints/6` that a handoff can reach,
  # each driven with a VALID confirmation present, so the fix can never be
  # widened into one that lifts any of them.
  describe "a confirmation never lifts a hard stop" do
    test "an incompatible receiver CLI still refuses" do
      assert_hard_stop(incompatible_snapshot!(), "incompatible_cli")
    end

    test "an unsupported receiver tier still refuses" do
      assert_hard_stop(unsupported_tier_snapshot!(), "unsupported_tier")
    end

    test "a snapshot recorded for another provider still refuses" do
      assert_hard_stop(foreign_provider_snapshot!(), "snapshot_provider_mismatch")
    end

    test "a snapshot recorded for another scope still refuses" do
      assert_hard_stop(foreign_scope_snapshot!(), "snapshot_provider_mismatch")
    end

    test "a breached five-hour reserve still refuses" do
      fixture = fixture()
      observe!(reserve_breach_snapshot!())

      {:ok, handoff_id} = request!(fixture, confirmation: confirmation())
      assert :ok = HandoffWorker.perform(job!(handoff_id))

      assert [decision] = handoff_decisions(fixture.goal.id)
      refute decision.payload["result"] == "admit"
      assert no_transfer_effects!(fixture)
    end

    test "a hard quota refusal still refuses" do
      assert_hard_stop(refused_snapshot!(), "hard_quota_refusal_delayed")
    end

    test "an occupied scope still refuses" do
      fixture = fixture()

      {:ok, _handoff_id} = request!(fixture, confirmation: confirmation())

      # `occupancy: true` is exactly what `Commands.active_claim/1` reports
      # when another goal holds the live claim.
      assert {:ok, %{outcome: :refused, decision_result: :defer_until, reason_code: reason}} =
               Handoffs.perform(fixture.goal.id, command_id_of(fixture.goal.id),
                 observe: fn _scoping -> {:ok, conservative_partial_snapshot!()} end,
                 occupancy: true
               )

      assert reason == "scope_occupied"
      assert no_transfer_effects!(fixture)
    end

    # `scope_mismatch` and `unsupported_capability` are STRUCTURALLY
    # unreachable through `Handoffs.perform/3`: it builds the request scope
    # and the candidate scope from the same `intent["scope"]`, and the
    # candidate's capability list from the very capability it requests
    # (`handoffs.ex`, `admit/8`). There is no handoff input that makes either
    # disagree, so forcing one through the handoff path would test a shape
    # production cannot produce. They are asserted one layer down instead,
    # against the evaluator that owns the rule, with a valid confirmation in
    # hand — which is the claim that matters: a confirmation cannot lift them.
    test "a scope mismatch is not liftable by a confirmation" do
      assert {:ok, decision} =
               evaluate_with_confirmation(request_overrides: %{scope: "account:somewhere-else"})

      assert decision.result == :reject
      assert decision.reason_code == "scope_mismatch"
      assert decision.override["valid"] == true
    end

    test "an unsupported capability is not liftable by a confirmation" do
      assert {:ok, decision} =
               evaluate_with_confirmation(candidate_overrides: %{capabilities: ["read_only"]})

      assert decision.result == :reject
      assert decision.reason_code == "unsupported_capability"
      assert decision.override["valid"] == true
    end
  end

  # ----------------------------------------------------------------------------
  # Fail-closed at request time
  # ----------------------------------------------------------------------------

  describe "the confirmation is rejected at request time" do
    test "a caller-authored confirmed_by is an unsupported field, not an identity" do
      fixture = fixture()

      assert {:error, changeset} =
               submit(fixture,
                 confirmation: %{
                   "intent" => "supervised_execution",
                   "confirmed_by" => "user:someone"
                 }
               )

      assert %{confirmation: ["contains unsupported fields: confirmed_by"]} = errors_on(changeset)
      assert command_rows(fixture.goal.id) == []
    end

    test "a forged system principal is rejected the same way" do
      fixture = fixture()

      assert {:error, changeset} =
               submit(fixture,
                 confirmation: %{
                   "intent" => "supervised_execution",
                   "confirmed_by" => "system:handoff"
                 }
               )

      assert %{confirmation: ["contains unsupported fields: confirmed_by"]} = errors_on(changeset)
      assert command_rows(fixture.goal.id) == []
    end

    test "a caller-chosen target provider or scope is rejected" do
      fixture = fixture()

      assert {:error, changeset} =
               submit(fixture,
                 confirmation: %{
                   "intent" => "supervised_execution",
                   "target_provider_id" => "some-other-provider",
                   "target_scope" => "account:someone-else"
                 }
               )

      assert %{confirmation: ["contains unsupported fields: target_provider_id, target_scope"]} =
               errors_on(changeset)

      assert command_rows(fixture.goal.id) == []
    end

    test "a confirmation that is not an object is rejected" do
      fixture = fixture()

      for value <- ["yes", 1, [%{"intent" => "supervised_execution"}], true] do
        assert {:error, changeset} = submit(fixture, confirmation: value)
        assert %{confirmation: ["must be an object"]} = errors_on(changeset)
      end

      assert command_rows(fixture.goal.id) == []
    end

    test "an intent outside the capability vocabulary is rejected" do
      fixture = fixture()

      assert {:error, changeset} = submit(fixture, confirmation: %{"intent" => "anything_at_all"})
      assert %{intent: ["must be one of supervised_execution, read_only"]} = errors_on(changeset)
      assert command_rows(fixture.goal.id) == []
    end

    test "a missing, blank, non-string or overlong intent is rejected" do
      fixture = fixture()

      assert {:error, blank} = submit(fixture, confirmation: %{})
      assert %{intent: ["can't be blank"]} = errors_on(blank)

      assert {:error, nil_intent} = submit(fixture, confirmation: %{"intent" => nil})
      assert %{intent: ["can't be blank"]} = errors_on(nil_intent)

      assert {:error, non_string} = submit(fixture, confirmation: %{"intent" => 7})
      assert Map.has_key?(errors_on(non_string), :intent)

      assert {:error, overlong} =
               submit(fixture, confirmation: %{"intent" => String.duplicate("a", 201)})

      assert Map.has_key?(errors_on(overlong), :intent)

      assert command_rows(fixture.goal.id) == []
    end

    test "an unknown key alongside a valid intent is still rejected" do
      fixture = fixture()

      assert {:error, changeset} =
               submit(fixture,
                 confirmation: %{"intent" => "supervised_execution", "escalate" => true}
               )

      assert %{confirmation: ["contains unsupported fields: escalate"]} = errors_on(changeset)
      assert command_rows(fixture.goal.id) == []
    end
  end

  # ----------------------------------------------------------------------------
  # Digest, replay, conflict
  # ----------------------------------------------------------------------------

  describe "replay and conflict" do
    test "an identical re-submission replays with no duplicate effects" do
      fixture = fixture()
      command_id = "cmd-handoff-" <> Ecto.UUID.generate()

      assert {:ok, %{command: first, outcome: :recorded}} =
               submit(fixture, command_id: command_id, confirmation: confirmation())

      before = command_event_count(fixture.goal.id)

      assert {:ok, %{command: second, outcome: :replayed}} =
               submit(fixture, command_id: command_id, confirmation: confirmation())

      assert second.id == first.id
      assert second.digest == first.digest
      assert second.result["confirmation"] == first.result["confirmation"]
      assert command_event_count(fixture.goal.id) == before
      # Oban uniqueness on handoff_id: one delivery attempt, not two.
      assert job_count() == 1
      assert length(command_rows(fixture.goal.id)) == 1
    end

    test "re-submitting the same command id with a different confirmation is a conflict" do
      fixture = fixture()
      command_id = "cmd-handoff-" <> Ecto.UUID.generate()

      assert {:ok, %{command: first}} =
               submit(fixture, command_id: command_id, confirmation: confirmation())

      assert first.status == "resolved"

      assert {:error, {:command_conflict, detail}} =
               submit(fixture,
                 command_id: command_id,
                 confirmation: confirmation(intent: "read_only")
               )

      assert detail["command_id"] == command_id
      assert length(command_rows(fixture.goal.id)) == 1
    end

    test "adding a confirmation to a previously unconfirmed command id is a conflict" do
      fixture = fixture()
      command_id = "cmd-handoff-" <> Ecto.UUID.generate()

      assert {:ok, %{command: _}} = submit(fixture, command_id: command_id)

      assert {:error, {:command_conflict, _detail}} =
               submit(fixture, command_id: command_id, confirmation: confirmation())
    end

    test "an intent with no confirmation keeps the payload it always had" do
      fixture = fixture()

      assert {:ok, %{command: command}} = submit(fixture)
      refute Map.has_key?(command.payload, "confirmation")
      refute Map.has_key?(command.result, "confirmation")

      # The digest of an unconfirmed payload is the digest of exactly those
      # fields, so a command id submitted before this field existed still
      # replays rather than conflicting.
      assert command.digest == Command.digest("run.handoff", command.payload)
    end
  end

  # ----------------------------------------------------------------------------
  # Intent must be the capability admission is deciding
  # ----------------------------------------------------------------------------

  describe "the confirmed intent must be the requested capability" do
    test "a confirmation whose intent is not the requested capability refuses permanently" do
      fixture = fixture()
      observe!(conservative_partial_snapshot!())

      {:ok, handoff_id} = request!(fixture, confirmation: confirmation(intent: "read_only"))

      assert {:error, {:handoff_confirmation_intent_mismatch, detail}} =
               Handoffs.perform(fixture.goal.id, command_id_of(fixture.goal.id),
                 observe: fn _scoping -> {:ok, conservative_partial_snapshot!()} end
               )

      assert detail["confirmed_intent"] == "read_only"
      assert detail["requested_capability"] == "supervised_execution"

      # Permanent: durably settled, so reconcile never resurrects it and the
      # worker cancels the attempt instead of burning retries.
      assert Handoffs.permanent_error?({:handoff_confirmation_intent_mismatch, detail})
      assert [failed] = events(fixture.goal.id, "handoff.failed")
      assert failed.payload["handoff_id"] == handoff_id

      # Nothing was observed, admitted or transferred.
      assert handoff_decisions(fixture.goal.id) == []
      assert events(fixture.goal.id, "capacity.snapshot_observed") == []
      assert no_transfer_effects!(fixture)
    end

    test "a matching intent is not blocked" do
      fixture = fixture()
      observe!(conservative_partial_snapshot!())

      {:ok, handoff_id} = request!(fixture, confirmation: confirmation())
      assert :ok = HandoffWorker.perform(job!(handoff_id))
      assert [_pointer] = events(fixture.goal.id, "handoff.created")
    end
  end

  # ----------------------------------------------------------------------------
  # Precedence
  # ----------------------------------------------------------------------------

  describe "precedence" do
    test "an explicit :override option still wins over the intent" do
      fixture = fixture()
      snapshot = conservative_partial_snapshot!()
      observe!(snapshot)

      {:ok, _handoff_id} = request!(fixture, confirmation: confirmation())

      assert {:ok, %{outcome: :dispatched}} =
               Handoffs.perform(fixture.goal.id, command_id_of(fixture.goal.id),
                 observe: fn _scoping -> {:ok, snapshot} end,
                 override: %{
                   "confirmed_by" => "user:option-wins",
                   "intent" => "supervised_execution",
                   "target_provider_id" => @receiver_provider,
                   "target_scope" => @receiver_scope
                 }
               )

      assert [decision] = handoff_decisions(fixture.goal.id)
      assert decision.payload["override"]["confirmed_by"] == "user:option-wins"
    end
  end

  # ----------------------------------------------------------------------------
  # Shared assertions
  # ----------------------------------------------------------------------------

  defp assert_hard_stop(snapshot, reason_code) do
    fixture = fixture()
    observe!(snapshot)

    {:ok, handoff_id} = request!(fixture, confirmation: confirmation())
    assert :ok = HandoffWorker.perform(job!(handoff_id))

    assert [decision] = handoff_decisions(fixture.goal.id)
    refute decision.payload["result"] == "admit"
    assert decision.payload["reason_code"] == reason_code
    assert no_transfer_effects!(fixture)
  end

  defp no_transfer_effects!(fixture) do
    assert events(fixture.goal.id, "handoff.created") == []
    assert run_ids(fixture.goal.id) == [fixture.run.id]
    assert Repo.all(DispatchRecord) == []
    assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 0
    true
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
          status: "completed",
          requested_capabilities: %{"items" => ["resume", "cancel"]}
        )
      )

    decision = admission_payload(provider_id: @sender_provider, adapter_id: @sender_provider)
    admission = append_admission_event!(goal.id, decision)

    {:ok, %{command: claim}} = Commands.submit(goal.id, claim_command(admission))
    assert claim.status == "resolved"

    checkpoint_id = Ecto.UUID.generate()
    append_checkpoint!(goal, run, checkpoint_id)
    {:ok, _} = Projector.project(goal.id)

    %{
      goal: Repo.get!(Goal, goal.id),
      task: task,
      run: Repo.get!(RunRecord, run.id),
      checkpoint_id: checkpoint_id
    }
  end

  defp append_checkpoint!(goal, run, checkpoint_id) do
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
            "acceptance_contract" => %{"criteria" => ["the CLI plays a full game"]},
            "repository_state" => %{"revision" => "abc123", "dirty" => true},
            "evidence" => %{"items" => ["package tests pass"]},
            "decisions" => %{"items" => ["core package first, CLI second"]},
            "unresolved_issues" => %{"items" => ["no CLI entry point yet"]},
            "next_action" => "add the CLI entry point and make the suite pass",
            "provider_session_id" => nil,
            "stop_reason" => "handoff_boundary",
            "artifact_ids" => %{"items" => []},
            "extensions" => %{}
          }
        },
        trusted: [run_id: run.id]
      )

    event
  end

  defp confirmation(opts \\ []) do
    %{"intent" => Keyword.get(opts, :intent, "supervised_execution")}
  end

  defp submit(fixture, opts \\ []) do
    payload = %{
      "run_id" => fixture.run.id,
      "checkpoint_id" => fixture.checkpoint_id,
      "decision_refs" => decision_refs(fixture.goal.id),
      "to_provider_id" => @receiver_provider,
      "to_adapter_id" => @receiver_adapter,
      "scope" => @receiver_scope,
      "reason" => "sender leg complete at the named boundary",
      "requested_by" => "user:operator-live"
    }

    payload =
      case Keyword.fetch(opts, :confirmation) do
        :error -> payload
        {:ok, confirmation} -> Map.put(payload, "confirmation", confirmation)
      end

    attrs = %{
      "command_id" =>
        Keyword.get_lazy(opts, :command_id, fn -> "cmd-" <> Ecto.UUID.generate() end),
      "payload" => payload
    }

    Handoffs.request(fixture.goal.id, attrs)
  end

  defp request!(fixture, opts \\ []) do
    assert {:ok, %{handoff_id: handoff_id, command: command}} = submit(fixture, opts)
    assert command.status == "resolved"
    {:ok, handoff_id}
  end

  # The production delivery attempt, taken from the row the request wrote.
  defp job!(handoff_id) do
    Repo.one!(
      from job in Job,
        where:
          job.queue == "handoff" and
            fragment("json_extract(?, '$.handoff_id')", job.args) == ^handoff_id
    )
  end

  # The worker's ONLY observation channel.
  defp observe!(snapshot) do
    Application.put_env(:shoestring, :handoff_observe, fn _scoping -> {:ok, snapshot} end)
  end

  defp decision_refs(goal_id), do: Shoestring.Harness.Continuation.decision_refs(Repo, goal_id)

  defp handoff_command(goal_id) do
    Repo.one!(
      from command in CommandRecord,
        where: command.goal_id == ^goal_id and command.type == "run.handoff"
    )
  end

  defp command_id_of(goal_id), do: handoff_command(goal_id).command_id
  defp handoff_id_of(goal_id), do: handoff_command(goal_id).id

  defp command_rows(goal_id) do
    Repo.all(
      from command in CommandRecord,
        where: command.goal_id == ^goal_id and command.type == "run.handoff"
    )
  end

  defp command_event_count(goal_id) do
    Repo.one!(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and like(event.type, "cobbler.command.%"),
        select: count()
    )
  end

  defp job_count, do: Repo.aggregate(Job, :count, :id)

  defp events(goal_id, type) do
    Repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == ^type,
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

  defp run_ids(goal_id) do
    Repo.all(from run in RunRecord, where: run.goal_id == ^goal_id, select: run.id)
  end

  # ----------------------------------------------------------------------------
  # Policies and snapshots
  # ----------------------------------------------------------------------------

  # Evaluates one admission directly, with a VALID confirmation present, so a
  # hard stop that `Handoffs.perform/3` cannot construct is still proven
  # unliftable at the layer that decides it.
  defp evaluate_with_confirmation(opts) do
    now = DateTime.utc_now()
    snapshot = conservative_partial_snapshot!()

    candidate =
      Map.merge(
        %{
          provider_id: @receiver_provider,
          adapter_id: @receiver_adapter,
          support_tier: snapshot.support_tier,
          compatibility_state: snapshot.compatibility_state,
          scope: @receiver_scope,
          capabilities: ["supervised_execution"]
        },
        Keyword.get(opts, :candidate_overrides, %{})
      )

    request =
      Map.merge(
        %{
          requested_capability: "supervised_execution",
          scope: @receiver_scope,
          goal_id: Ecto.UUID.generate(),
          task_id: Ecto.UUID.generate(),
          run_id: Ecto.UUID.generate(),
          override: %{
            "confirmed_by" => "owner:" <> Ecto.UUID.generate(),
            "intent" => "supervised_execution",
            "target_provider_id" => candidate.provider_id,
            "target_scope" => candidate.scope
          }
        },
        Keyword.get(opts, :request_overrides, %{})
      )

    Shoestring.Cobbler.AdmissionEvaluation.evaluate(
      request,
      candidate,
      snapshot,
      Shoestring.Cobbler.AdmissionPolicy.default(),
      now: now,
      occupancy: false
    )
  end

  # The receiver observation shape the real passive Claude source produces:
  # `conservative_partial` support, which is confirmation-class rather than a
  # hard stop.
  defp conservative_partial_snapshot! do
    snapshot!(
      capacity_state: :unknown,
      windows: [],
      support_tier: :conservative_partial,
      compatibility_state: :degraded,
      confidence: :none,
      reason: "rate limits absent before the first response"
    )
  end

  defp incompatible_snapshot! do
    snapshot!(
      capacity_state: :degraded,
      windows: [observed_window(10.0)],
      support_tier: :conservative_partial,
      compatibility_state: :incompatible,
      confidence: :medium,
      reason: "receiver CLI version is incompatible with this adapter"
    )
  end

  defp unsupported_tier_snapshot! do
    snapshot!(
      capacity_state: :unknown,
      windows: [],
      support_tier: :unsupported,
      compatibility_state: :degraded,
      confidence: :none,
      reason: "receiver exposes no usable capacity surface"
    )
  end

  defp foreign_provider_snapshot! do
    snapshot!(
      capacity_state: :unknown,
      windows: [],
      support_tier: :conservative_partial,
      compatibility_state: :degraded,
      confidence: :none,
      reason: "rate limits absent before the first response",
      provider_id: "codex"
    )
  end

  defp foreign_scope_snapshot! do
    snapshot!(
      capacity_state: :unknown,
      windows: [],
      support_tier: :conservative_partial,
      compatibility_state: :degraded,
      confidence: :none,
      reason: "rate limits absent before the first response",
      scope: "account:someone-else"
    )
  end

  defp reserve_breach_snapshot! do
    snapshot!(
      capacity_state: :observed,
      windows: [observed_window(95.0)],
      support_tier: :proactive,
      compatibility_state: :compatible,
      confidence: :high,
      reason: nil
    )
  end

  # A provider-reported hard quota refusal: `capacity_state: :refused` with a
  # reason, non-high confidence, and no observed windows (the only shape
  # `CapacitySnapshot` accepts as refused). `AdmissionEvaluation.is_refused?/1`
  # hard-stops it before any confirmation-class rule runs.
  defp refused_snapshot! do
    snapshot!(
      capacity_state: :refused,
      windows: [],
      support_tier: :conservative_partial,
      compatibility_state: :compatible,
      confidence: :medium,
      reason: "rate_limit_exceeded"
    )
  end

  defp observed_window(used_percent) do
    %{
      kind: "five_hour",
      state: :observed,
      used_percent: used_percent,
      reset_at: DateTime.add(DateTime.utc_now(), 7_200, :second)
    }
  end

  # `observed_at` tracks real `now`: the production worker judges freshness
  # with `SystemClock`, so a fixed past timestamp would be refused as stale
  # and the test would measure the wrong refusal. One second in the past,
  # because `Handoffs.perform/3` reads its `now` before it observes and a
  # snapshot stamped after that reads as future-dated.
  defp snapshot!(opts) do
    now = DateTime.add(DateTime.utc_now(), -1, :second)

    attrs = %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: Keyword.fetch!(opts, :capacity_state),
      windows: Keyword.fetch!(opts, :windows),
      observed_at: now,
      freshness: %{max_age_seconds: 300},
      source: %{
        adapter_id: "claude_interactive_status_line",
        provider_id: Keyword.get(opts, :provider_id, @receiver_provider),
        invocation_mode: "interactive_status_line",
        event: :status_line_input
      },
      scope: Keyword.get(opts, :scope, @receiver_scope),
      confidence: Keyword.fetch!(opts, :confidence),
      support_tier: Keyword.fetch!(opts, :support_tier),
      compatibility_state: Keyword.fetch!(opts, :compatibility_state),
      reason: Keyword.fetch!(opts, :reason),
      extensions: %{}
    }

    {:ok, snapshot} = CapacitySnapshot.new(attrs, now: now)
    snapshot
  end
end
