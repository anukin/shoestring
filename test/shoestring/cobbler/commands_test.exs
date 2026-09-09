defmodule Shoestring.Cobbler.CommandsTest do
  @moduledoc """
  Hermetic DataCase tests for the durable command store: replay and conflict
  semantics, validated transitions, recoverable needs_user, atomic
  intent/transition/result, competing goals, inert pending intents, no
  execution, and no timed release.
  """
  use Shoestring.DataCase, async: false

  alias Oban.Job
  alias Shoestring.Cobbler.Command
  alias Shoestring.Cobbler.Commands
  alias Shoestring.Cobbler.CommandRecord
  alias Shoestring.Cobbler.TaskClaimRecord
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  @now ~U[2026-09-07 12:00:00.000000Z]
  @stale_now ~U[2026-01-01 00:00:00.000000Z]

  @cobbler_event_types [
    "cobbler.command.accepted",
    "cobbler.command.resolved",
    "cobbler.claim.acquired",
    "cobbler.claim.released"
  ]

  setup do
    goal = create_goal!()
    {:ok, goal: goal}
  end

  describe "submit task.claim" do
    test "records the claimed outcome, the claim row, and canonical events atomically", %{
      goal: goal
    } do
      admission = append_admission_event!(goal.id)
      command = claim_command(admission, command_id: "cmd-claim-1")

      assert {:ok, %{command: row, outcome: :recorded, events: events}} =
               Commands.submit(goal.id, command, now: @now)

      assert row.status == "resolved"
      assert row.type == "task.claim"
      assert row.result["kind"] == "claimed"
      assert row.command_id == "cmd-claim-1"
      assert Enum.map(events, & &1.type) == ["cobbler.command.accepted", "cobbler.claim.acquired"]

      assert %TaskClaimRecord{} = claim = Commands.active_claim([])
      assert claim.goal_id == goal.id
      assert claim.command_id == "cmd-claim-1"
      assert claim.intent == "supervised_execution"
      assert claim.provider_id == "codex"
      assert claim.status == "active"
      assert claim.admission_event_id == admission.id
      assert claim.admission_decision_id == admission.payload["decision_id"]

      assert event_count(goal.id, @cobbler_event_types) == 2
    end

    test "identical replay returns the original result without appending events", %{goal: goal} do
      admission = append_admission_event!(goal.id)
      command = claim_command(admission, command_id: "cmd-claim-replay")

      assert {:ok, %{outcome: :recorded}} = Commands.submit(goal.id, command, now: @now)
      events_before = cobbler_events(goal.id)

      assert {:ok, %{command: replayed, outcome: :replayed, events: []}} =
               Commands.submit(goal.id, command, now: @now)

      assert replayed.result["kind"] == "claimed"
      assert cobbler_events(goal.id) == events_before
      assert length(cobbler_events(goal.id)) == 2
      assert %TaskClaimRecord{} = Commands.active_claim([])
    end

    test "conflicting reuse of the same command id is rejected", %{goal: goal} do
      admission = append_admission_event!(goal.id)
      command = claim_command(admission, command_id: "cmd-claim-conflict")

      assert {:ok, %{outcome: :recorded}} = Commands.submit(goal.id, command, now: @now)

      conflicting =
        command
        |> put_in(["payload", "scope"], "account:claude")
        |> put_in(["payload", "admission_event_id"], admission.id)

      events_before = cobbler_events(goal.id)

      assert {:error, {:command_conflict, conflict}} =
               Commands.submit(goal.id, conflicting, now: @now)

      assert conflict["command_id"] == "cmd-claim-conflict"
      assert conflict["existing_digest"] != conflict["incoming_digest"]
      assert cobbler_events(goal.id) == events_before

      stored = Commands.get(goal.id, "cmd-claim-conflict", [])
      assert stored.status == "resolved"
      assert stored.result["kind"] == "claimed"
      # The claim was recorded for the original scope, not the conflicting one.
      assert Commands.active_claim([]).provider_id == "codex"
    end

    test "claiming while another goal holds the claim is needs_user and never releases it", %{
      goal: goal
    } do
      holder = create_goal!()
      holder_admission = append_admission_event!(holder.id)

      assert {:ok, %{outcome: :recorded}} =
               Commands.submit(
                 holder.id,
                 claim_command(holder_admission, command_id: "cmd-holder"),
                 now: @now
               )

      admission = append_admission_event!(goal.id)
      command = claim_command(admission, command_id: "cmd-contender")

      assert {:ok, %{command: row, outcome: :recorded, events: events}} =
               Commands.submit(goal.id, command, now: @now)

      assert row.status == "needs_user"
      assert row.result["kind"] == "needs_user"
      assert row.result["reason"] == "claim_held"
      assert row.result["options"] == ["abandon"]
      assert row.result["active_claim"]["goal_id"] == holder.id
      assert row.result["active_claim"]["claim_id"] == Commands.active_claim([]).id
      assert Enum.map(events, & &1.type) == ["cobbler.command.accepted"]

      # The holder's claim is untouched: no timer, staleness, or competing
      # command ever releases it.
      claim = Commands.active_claim([])
      assert claim.goal_id == holder.id
      assert claim.status == "active"
      assert event_count(goal.id, @cobbler_event_types) == 1
    end

    test "invalid commands are rejected without persisting anything", %{goal: goal} do
      admission = append_admission_event!(goal.id)

      for invalid <- [
            %{"type" => "task.execute", "payload" => %{}},
            %{"type" => "task.claim", "payload" => %{"intent" => "x"}},
            claim_command(admission) |> Map.put("payload", %{}),
            claim_command(admission) |> put_in(["payload", "admission_event_id"], "not-a-uuid")
          ] do
        assert {:error, %Ecto.Changeset{}} = Commands.submit(goal.id, invalid, now: @now)
      end

      assert Commands.list(goal.id, []) == []
      assert Commands.active_claim([]) == nil
      assert event_count(goal.id, @cobbler_event_types) == 0
    end

    test "an admission reference from a different goal is rejected before any claim", %{
      goal: goal
    } do
      other = create_goal!()
      foreign_admission = append_admission_event!(other.id)

      command = claim_command(foreign_admission, command_id: "cmd-cross-goal")

      assert {:ok, %{command: row, outcome: :recorded}} =
               Commands.submit(goal.id, command, now: @now)

      assert row.status == "rejected"
      assert row.result["reason"] == "admission_event_not_found"
      assert Commands.active_claim([]) == nil
    end

    test "an admission reference that mismatches intent, scope, or candidate is rejected", %{
      goal: goal
    } do
      admission = append_admission_event!(goal.id)

      mismatches = [
        {"intent", put_in(claim_command(admission), ["payload", "intent"], "read_only"),
         "admission_intent_mismatch"},
        {"scope", put_in(claim_command(admission), ["payload", "scope"], "account:claude"),
         "admission_scope_mismatch"},
        {"candidate",
         put_in(claim_command(admission), ["payload", "candidate", "provider_id"], "claude"),
         "admission_candidate_mismatch"}
      ]

      for {label, command, reason} <- mismatches do
        command_id = "cmd-mismatch-#{label}"

        assert {:ok, %{command: row, outcome: :recorded}} =
                 Commands.submit(goal.id, %{command | "command_id" => command_id}, now: @now)

        assert row.status == "rejected", "expected rejection for #{label}"
        assert row.result["reason"] == reason
      end

      assert Commands.active_claim([]) == nil
      assert event_count(goal.id, @cobbler_event_types) == 3
    end

    test "a non-admission event reference and a missing decision id are rejected", %{goal: goal} do
      # A registered but non-admission event in the same goal.
      {:ok, plain_event} =
        Shoestring.Trajectory.append(goal.id, %{
          "type" => "decision.recorded",
          "schema_version" => 1,
          "actor" => "system",
          "occurred_at" => @now,
          "payload" => %{"decision" => "not an admission"}
        })

      wrong_type_command = %{
        "type" => "task.claim",
        "command_id" => "cmd-wrong-type",
        "payload" => %{
          "intent" => "supervised_execution",
          "scope" => "account:codex",
          "candidate" => %{"provider_id" => "codex", "adapter_id" => "codex_app_server"},
          "admission_event_id" => plain_event.id
        }
      }

      assert {:ok, %{command: row}} = Commands.submit(goal.id, wrong_type_command, now: @now)
      assert row.status == "rejected"
      assert row.result["reason"] == "admission_event_type_invalid"

      # An admission event whose stored payload lost its decision id.
      {:ok, incomplete} = append_admission_event_to_repo(goal.id)

      Repo.update!(
        Ecto.Changeset.change(incomplete,
          payload: Map.put(incomplete.payload, "decision_id", nil)
        )
      )

      command2 = claim_command(incomplete, command_id: "cmd-no-decision")

      assert {:ok, %{command: row2}} = Commands.submit(goal.id, command2, now: @now)
      assert row2.status == "rejected"
      assert row2.result["reason"] == "admission_decision_id_missing"

      assert Commands.active_claim([]) == nil
    end

    test "a mid-transaction failure rolls back the claim, the command row, and the events", %{
      goal: goal
    } do
      admission = append_admission_event!(goal.id)
      command = claim_command(admission, command_id: "cmd-rollback")

      # Pre-seed a canonical event holding the idempotency key the accepted
      # event would use, so the event insert fails after the claim row was
      # already inserted inside the same transaction.
      next_sequence = next_sequence(goal.id)

      %TrajectoryEvent{goal_id: goal.id, sequence: next_sequence}
      |> TrajectoryEvent.changeset(%{
        "type" => "decision.recorded",
        "schema_version" => 1,
        "actor" => "fixture",
        "occurred_at" => @now,
        "payload" => %{"decision" => "idempotency collision"},
        "idempotency_key" => "cobbler-command-accepted:#{goal.id}:cmd-rollback"
      })
      |> Repo.insert!()

      events_before = cobbler_events(goal.id)

      assert {:error, {:event_append_failed, "cobbler.command.accepted", %Ecto.Changeset{}}} =
               Commands.submit(goal.id, command, now: @now)

      # Nothing persisted: no claim, no command row, no new events.
      assert Commands.active_claim([]) == nil
      assert Commands.list(goal.id, []) == []
      assert cobbler_events(goal.id) == events_before
    end

    test "submitting to a nonexistent goal rolls back atomically" do
      missing_goal_id = Ecto.UUID.generate()
      command = %{"type" => "task.release", "payload" => %{"reason" => "no goal"}}

      assert {:error, :goal_not_found} = Commands.submit(missing_goal_id, command, now: @now)

      assert event_count(missing_goal_id, @cobbler_event_types) == 0
    end
  end

  describe "task.release" do
    test "the owning goal releases explicitly and the claim becomes re-acquirable", %{goal: goal} do
      admission = append_admission_event!(goal.id)
      claim_command = claim_command(admission, command_id: "cmd-claim-a")

      assert {:ok, %{outcome: :recorded}} = Commands.submit(goal.id, claim_command, now: @now)
      claim_id = Commands.active_claim([]).id

      release = release_command("operator released", command_id: "cmd-release-a")

      assert {:ok, %{command: row, outcome: :recorded, events: events}} =
               Commands.submit(goal.id, release, now: @now)

      assert row.status == "resolved"
      assert row.result["kind"] == "released"
      assert row.result["claim_id"] == claim_id

      assert Enum.map(events, & &1.type) == [
               "cobbler.command.accepted",
               "cobbler.claim.released"
             ]

      assert Commands.active_claim([]) == nil
      released_row = Repo.get!(TaskClaimRecord, claim_id)
      assert released_row.status == "released"
      assert released_row.released_by_command_id == "cmd-release-a"
      assert released_row.release_reason == "operator released"
      assert released_row.released_at == DateTime.truncate(@now, :microsecond)

      # The global claim slot is free again: a new goal can acquire it.
      other = create_goal!()
      other_command = claim_command(append_admission_event!(other.id), command_id: "cmd-claim-b")

      assert {:ok, %{command: new_row}} = Commands.submit(other.id, other_command, now: @now)
      assert new_row.result["kind"] == "claimed"
    end

    test "releasing with no active claim resolves without side effects", %{goal: goal} do
      release = release_command("nothing held", command_id: "cmd-release-empty")

      assert {:ok, %{command: row, outcome: :recorded, events: events}} =
               Commands.submit(goal.id, release, now: @now)

      assert row.status == "resolved"
      assert row.result["kind"] == "no_active_claim"
      assert Enum.map(events, & &1.type) == ["cobbler.command.accepted"]
      assert Commands.active_claim([]) == nil
    end

    test "release by a goal that does not own the claim is rejected", %{goal: goal} do
      holder = create_goal!()
      holder_admission = append_admission_event!(holder.id)

      assert {:ok, %{outcome: :recorded}} =
               Commands.submit(
                 holder.id,
                 claim_command(holder_admission, command_id: "cmd-holder2"),
                 now: @now
               )

      release = release_command("hostile release", command_id: "cmd-release-other")

      assert {:ok, %{command: row}} = Commands.submit(goal.id, release, now: @now)

      assert row.status == "rejected"
      assert row.result["reason"] == "claim_owned_by_other_goal"
      assert row.result["claim_goal_id"] == holder.id
      assert Commands.active_claim([]).goal_id == holder.id
    end
  end

  describe "recoverable needs_user" do
    setup %{goal: goal} do
      holder = create_goal!()
      holder_admission = append_admission_event!(holder.id)

      assert {:ok, _} =
               Commands.submit(
                 holder.id,
                 claim_command(holder_admission, command_id: "cmd-holder-3"),
                 now: @now
               )

      goal_admission = append_admission_event!(goal.id)

      {:ok, %{command: contender}} =
        Commands.submit(goal.id, claim_command(goal_admission, command_id: "cmd-contender"),
          now: @now
        )

      {:ok, goal: goal, holder: holder, contender: contender}
    end

    test "pending commands are inert, inspectable, and consume nothing", %{
      goal: goal,
      holder: holder,
      contender: contender
    } do
      assert [%CommandRecord{} = pending] = Commands.pending(goal.id, [])
      assert pending.id == contender.id
      assert pending.status == "needs_user"

      # Inert: the pending intent did not create or move a claim, and no
      # background work was enqueued for it.
      claim = Commands.active_claim([])
      assert claim.goal_id == holder.id
      assert claim.command_id == "cmd-holder-3"
      assert Repo.aggregate(Job, :count, :id) == 0
    end

    test "a validated response resolves the pending decision", %{
      goal: goal,
      holder: holder,
      contender: contender
    } do
      assert {:ok, %{command: row, outcome: :recorded, events: events}} =
               Commands.respond(
                 goal.id,
                 contender.command_id,
                 %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"},
                 now: @now
               )

      assert row.status == "resolved"
      assert row.result["kind"] == "abandoned"
      assert row.result["reason"] == "claim_held"
      assert row.response == %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"}
      assert Enum.map(events, & &1.type) == ["cobbler.command.resolved"]
      assert Commands.pending(goal.id, []) == []

      # Resolving the contender never released the holder's claim.
      assert Commands.active_claim([]).goal_id == holder.id
    end

    test "an identical response replays without events", %{goal: goal, contender: contender} do
      assert {:ok, %{outcome: :recorded}} =
               Commands.respond(
                 goal.id,
                 contender.command_id,
                 %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"},
                 now: @now
               )

      events_before = cobbler_events(goal.id)

      assert {:ok, %{command: replayed, outcome: :replayed, events: []}} =
               Commands.respond(
                 goal.id,
                 contender.command_id,
                 %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"},
                 now: @now
               )

      assert replayed.result["kind"] == "abandoned"
      assert cobbler_events(goal.id) == events_before
    end

    test "a conflicting response is rejected", %{goal: goal, contender: contender} do
      assert {:ok, %{outcome: :recorded}} =
               Commands.respond(
                 goal.id,
                 contender.command_id,
                 %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"},
                 now: @now
               )

      events_before = cobbler_events(goal.id)

      assert {:error, {:response_conflict, conflict}} =
               Commands.respond(
                 goal.id,
                 contender.command_id,
                 %{"resolution" => "proceed", "confirmed_by" => "Ada Operator"},
                 now: @now
               )

      assert conflict["existing_digest"] != conflict["incoming_digest"]
      assert cobbler_events(goal.id) == events_before
      assert Commands.get(goal.id, contender.command_id, []).status == "resolved"
    end

    test "an unoffered response changes nothing and the command stays recoverable", %{
      goal: goal,
      contender: contender
    } do
      events_before = cobbler_events(goal.id)

      assert {:error, {:invalid_response, ["abandon"]}} =
               Commands.respond(
                 goal.id,
                 contender.command_id,
                 %{"resolution" => "escalate", "confirmed_by" => "Ada Operator"},
                 now: @now
               )

      assert cobbler_events(goal.id) == events_before

      still_pending = Commands.get(goal.id, contender.command_id, [])
      assert still_pending.status == "needs_user"
      assert is_nil(still_pending.response)

      # Recovery still works afterwards.
      assert {:ok, %{command: resolved}} =
               Commands.respond(
                 goal.id,
                 contender.command_id,
                 %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"},
                 now: @now
               )

      assert resolved.status == "resolved"
    end

    test "respond is an illegal transition on non-needs_user commands", %{
      goal: goal,
      holder: holder
    } do
      # The claim slot is global and held by the setup holder, so free it
      # first with an explicit release by the holder, then let a fresh goal
      # acquire its own claim.
      assert {:ok, _} =
               Commands.submit(
                 holder.id,
                 release_command("freeing slot", command_id: "cmd-free-slot"),
                 now: @now
               )

      fresh = create_goal!()
      admission = append_admission_event!(fresh.id)

      {:ok, %{command: claimed}} =
        Commands.submit(fresh.id, claim_command(admission, command_id: "cmd-ok"), now: @now)

      assert claimed.status == "resolved"

      assert {:error, {:illegal_respond, error}} =
               Commands.respond(
                 fresh.id,
                 claimed.command_id,
                 %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"},
                 now: @now
               )

      assert error["status"] == "resolved"

      assert {:error, :command_not_found} =
               Commands.respond(
                 goal.id,
                 "cmd-unknown",
                 %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"},
                 now: @now
               )
    end
  end

  describe "no execution, no timed release" do
    test "a stale claim is never released and the full flow enqueues no jobs", %{goal: goal} do
      holder = create_goal!()
      holder_admission = append_admission_event!(holder.id)

      {:ok, _} =
        Commands.submit(
          holder.id,
          claim_command(holder_admission, command_id: "cmd-stale-holder"),
          now: @stale_now
        )

      # Simulate staleness: the claim predates any plausible timer horizon,
      # yet nothing in the system releases it.
      assert %TaskClaimRecord{} = stale_claim = Commands.active_claim([])
      assert DateTime.compare(stale_claim.inserted_at, @now) == :lt
      assert stale_claim.status == "active"

      # A competing goal is still refused; the stale claim is not released.
      {:ok, _} =
        Commands.submit(
          goal.id,
          claim_command(append_admission_event!(goal.id), command_id: "cmd-stale-contender"),
          now: @now
        )

      assert Commands.active_claim([]).id == stale_claim.id

      # Execution remains disabled: no Oban jobs were enqueued anywhere.
      assert Repo.aggregate(Job, :count, :id) == 0

      # Restart ambiguity: replaying the holder's identical command after
      # "restart" returns the original result without events or a new claim.
      assert {:ok, %{outcome: :replayed, events: []}} =
               Commands.submit(
                 holder.id,
                 claim_command(holder_admission, command_id: "cmd-stale-holder"),
                 now: @now
               )

      assert Commands.active_claim([]).id == stale_claim.id
      assert Repo.aggregate(Job, :count, :id) == 0
    end
  end

  describe "rebuild" do
    test "reproduces command and claim state from canonical events", %{goal: goal} do
      admission = append_admission_event!(goal.id)

      {:ok, _} =
        Commands.submit(goal.id, claim_command(admission, command_id: "cmd-rebuild-1"), now: @now)

      {:ok, %{command: pending}} =
        Commands.submit(goal.id, claim_command(admission, command_id: "cmd-rebuild-2"), now: @now)

      {:ok, _} =
        Commands.respond(
          goal.id,
          pending.command_id,
          %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"},
          now: @now
        )

      release = release_command("rebuild release", command_id: "cmd-rebuild-3")
      {:ok, _} = Commands.submit(goal.id, release, now: @now)

      assert {:ok, rebuilt} = Commands.rebuild(goal.id, [])
      assert rebuilt.consistent?
      assert rebuilt.divergences == []

      by_id = Map.new(rebuilt.commands, &{&1["command_id"], &1})
      assert by_id["cmd-rebuild-1"]["status"] == "resolved"
      assert by_id["cmd-rebuild-1"]["result"]["kind"] == "claimed"
      assert by_id["cmd-rebuild-2"]["status"] == "resolved"

      assert by_id["cmd-rebuild-2"]["response"] == %{
               "resolution" => "abandon",
               "confirmed_by" => "Ada Operator"
             }

      assert by_id["cmd-rebuild-3"]["result"]["kind"] == "released"
      assert rebuilt.claim["status"] == "released"
      assert rebuilt.claim["claim_id"] == by_id["cmd-rebuild-1"]["result"]["claim_id"]
    end

    test "reports divergence when a row exists without canonical events", %{goal: goal} do
      admission = append_admission_event!(goal.id)

      {:ok, _} =
        Commands.submit(goal.id, claim_command(admission, command_id: "cmd-diverge"), now: @now)

      {:ok, orphan_command} =
        Command.new(%{
          "type" => "task.release",
          "payload" => %{"reason" => "r"},
          "command_id" => "cmd-orphan-row"
        })

      %CommandRecord{}
      |> CommandRecord.outcome_changeset(
        goal.id,
        orphan_command,
        "resolved",
        %{"kind" => "no_active_claim"},
        @now
      )
      |> Repo.insert!()

      assert {:ok, rebuilt} = Commands.rebuild(goal.id, [])
      refute rebuilt.consistent?

      assert rebuilt.divergences == [
               "command cmd-orphan-row persisted without canonical events"
             ]
    end

    test "reports divergence when canonical events have no persisted row", %{goal: goal} do
      admission = append_admission_event!(goal.id)

      {:ok, _} =
        Commands.submit(goal.id, claim_command(admission, command_id: "cmd-events-only"),
          now: @now
        )

      Repo.delete!(Commands.get(goal.id, "cmd-events-only", []))

      assert {:ok, rebuilt} = Commands.rebuild(goal.id, [])
      refute rebuilt.consistent?

      assert rebuilt.divergences == [
               "canonical events for command cmd-events-only have no persisted row"
             ]
    end

    test "fails loudly on an illegal canonical history", %{goal: goal} do
      # Seed a resolution event for a command that was never accepted.
      sequence = next_sequence(goal.id)

      %TrajectoryEvent{goal_id: goal.id, sequence: sequence}
      |> TrajectoryEvent.changeset(%{
        "type" => "cobbler.command.resolved",
        "schema_version" => 1,
        "actor" => "cobbler",
        "occurred_at" => @now,
        "payload" => %{
          "command_id" => "cmd-orphan",
          "command_type" => "task.claim",
          "response" => %{"resolution" => "abandon"},
          "response_digest" => Command.response_digest(%{"resolution" => "abandon"}),
          "from_status" => "needs_user",
          "to_status" => "resolved",
          "result" => %{"kind" => "abandoned"}
        }
      })
      |> Repo.insert!()

      assert {:error, {:rebuild_resolved_without_accepted, ^sequence, "cmd-orphan"}} =
               Commands.rebuild(goal.id, [])
    end

    test "reports divergence when the active claim and canonical state disagree", %{goal: goal} do
      admission = append_admission_event!(goal.id)

      {:ok, _} =
        Commands.submit(goal.id, claim_command(admission, command_id: "cmd-claim-x"), now: @now)

      # Mutate the stored claim so it no longer matches the canonical state.
      claim = Commands.active_claim([])
      Repo.update!(Ecto.Changeset.change(claim, command_id: "cmd-tampered"))

      assert {:ok, rebuilt} = Commands.rebuild(goal.id, [])
      refute rebuilt.consistent?

      assert "canonical active claim diverges from persisted active claim row" in rebuilt.divergences
    end
  end

  describe "facade boundary" do
    test "Shoestring.Cobbler exposes the command, claim, and rebuild boundary", %{goal: goal} do
      admission = append_admission_event!(goal.id)
      command = claim_command(admission, command_id: "cmd-facade")

      assert {:ok, %{command: row, outcome: :recorded, events: events}} =
               Shoestring.Cobbler.submit_command(goal.id, command, now: @now)

      assert row.status == "resolved"
      assert length(events) == 2
      assert %TaskClaimRecord{} = Shoestring.Cobbler.active_claim([])
      assert Shoestring.Cobbler.command(goal.id, "cmd-facade", []).id == row.id
      assert Shoestring.Cobbler.list_commands(goal.id, []) |> length() == 1
      assert Shoestring.Cobbler.pending_commands(goal.id, []) == []

      assert {:ok, %{consistent?: true, divergences: []}} =
               Shoestring.Cobbler.rebuild_commands(goal.id, [])
    end
  end

  defp cobbler_events(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type in @cobbler_event_types,
        order_by: [asc: event.sequence]
    )
  end

  defp next_sequence(goal_id) do
    (Repo.one(
       from event in TrajectoryEvent,
         where: event.goal_id == ^goal_id,
         select: max(event.sequence)
     ) ||
       0) + 1
  end

  # Appends an admission event through the standard boundary, returning the
  # raw event for later row mutation in malformed-payload tests.
  defp append_admission_event_to_repo(goal_id) do
    case Shoestring.Trajectory.append(goal_id, %{
           "type" => "admission.decided",
           "schema_version" => 1,
           "actor" => "cobbler",
           "occurred_at" => now(),
           "payload" => admission_payload()
         }) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> flunk("admission event append failed: #{inspect(reason)}")
    end
  end
end
