defmodule Shoestring.Cobbler.ResponseAttributionTest do
  @moduledoc """
  Hermetic DataCase tests for strict command-response attribution: every new
  response recorded through `Commands.respond/4` must carry a non-blank
  `confirmed_by` identity (fail-closed, no trace on refusal), attribution
  persists to the row and the `cobbler.command.resolved` event under the
  existing `response_digest` pair semantics, and pre-attribution rows still
  rebuild. No provider CLIs, no network, no execution.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.Command
  alias Shoestring.Cobbler.Commands
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  @now ~U[2026-09-07 12:00:00.000000Z]

  @cobbler_event_types [
    "cobbler.command.accepted",
    "cobbler.command.resolved",
    "cobbler.claim.acquired",
    "cobbler.claim.released"
  ]

  setup do
    goal = create_goal!()
    holder = create_goal!()
    holder_admission = append_admission_event!(holder.id)

    assert {:ok, _} =
             Commands.submit(
               holder.id,
               claim_command(holder_admission, command_id: "cmd-attr-holder"),
               now: @now
             )

    goal_admission = append_admission_event!(goal.id)

    {:ok, %{command: contender}} =
      Commands.submit(goal.id, claim_command(goal_admission, command_id: "cmd-attr-contender"),
        now: @now
      )

    assert contender.status == "needs_user"
    {:ok, goal: goal, holder: holder, contender: contender}
  end

  test "a human identity resolves and persists to the row, the event, and rebuild", %{
    goal: goal,
    holder: holder,
    contender: contender
  } do
    assert {:ok, %{command: row, outcome: :recorded, events: events}} =
             Commands.respond(
               goal.id,
               contender.command_id,
               %{
                 "resolution" => "abandon",
                 "confirmed_by" => "Ada Operator",
                 "intent" => "supervised_execution"
               },
               now: @now
             )

    assert row.status == "resolved"
    assert row.result["kind"] == "abandoned"
    assert row.response["resolution"] == "abandon"
    assert row.response["confirmed_by"] == "Ada Operator"
    assert row.response["intent"] == "supervised_execution"
    assert row.confirmed_by == "Ada Operator"
    assert row.confirmed_intent == "supervised_execution"

    assert [%TrajectoryEvent{type: "cobbler.command.resolved"} = event] = events
    assert event.payload["response"]["confirmed_by"] == "Ada Operator"
    assert event.payload["confirmed_by"] == "Ada Operator"
    assert event.payload["confirmed_intent"] == "supervised_execution"
    assert event.payload["response_digest"] == row.response_digest

    # The holder's global claim is unrelated to this goal's rebuild; release
    # it so rebuild consistency reflects this goal's canonical events only.
    release_holder!(holder)

    assert {:ok, rebuilt} = Commands.rebuild(goal.id, [])
    assert rebuilt.consistent?

    by_id = Map.new(rebuilt.commands, &{&1["command_id"], &1})
    assert by_id[contender.command_id]["confirmed_by"] == "Ada Operator"
    assert by_id[contender.command_id]["confirmed_intent"] == "supervised_execution"
  end

  test "an explicit system:-prefixed identity resolves automated responses", %{
    goal: goal,
    contender: contender
  } do
    assert {:ok, %{command: row, outcome: :recorded}} =
             Cobbler.respond_command(
               goal.id,
               contender.command_id,
               %{
                 "resolution" => "abandon",
                 "confirmed_by" => "system:wakeup",
                 "intent" => "supervised_execution"
               },
               now: @now
             )

    assert row.status == "resolved"
    assert row.confirmed_by == "system:wakeup"
    assert row.response["confirmed_by"] == "system:wakeup"
  end

  test "nil, missing, and blank confirmed_by are rejected with no trace", %{
    goal: goal,
    contender: contender
  } do
    for bad_response <- [
          %{"resolution" => "abandon", "confirmed_by" => nil},
          %{"resolution" => "abandon"},
          %{"resolution" => "abandon", "confirmed_by" => ""},
          %{"resolution" => "abandon", "confirmed_by" => "   "}
        ] do
      events_before = cobbler_events(goal.id)

      assert {:error, {:confirmation_invalid_responder, %{"reason" => "unattributed"}}} =
               Commands.respond(goal.id, contender.command_id, bad_response, now: @now)

      # Refusal leaves no trace: no events appended, row untouched.
      assert cobbler_events(goal.id) == events_before

      stored = Commands.get(goal.id, contender.command_id, [])
      assert stored.status == "needs_user"
      assert is_nil(stored.response)
      assert is_nil(stored.response_digest)
      assert is_nil(stored.confirmed_by)
      assert is_nil(stored.confirmed_intent)
    end
  end

  test "intent is persisted where carried and nil otherwise", %{goal: goal, contender: contender} do
    assert {:ok, %{command: row}} =
             Commands.respond(
               goal.id,
               contender.command_id,
               %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"},
               now: @now
             )

    assert row.status == "resolved"
    assert row.response == %{"resolution" => "abandon", "confirmed_by" => "Ada Operator"}
    assert is_nil(row.confirmed_intent)
  end

  test "attribution is digest-covered: the same resolution from another identity conflicts", %{
    goal: goal,
    contender: contender
  } do
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
               %{"resolution" => "abandon", "confirmed_by" => "Grace Hopper"},
               now: @now
             )

    assert conflict["existing_digest"] != conflict["incoming_digest"]
    assert cobbler_events(goal.id) == events_before
  end

  test "response and response_digest stay paired over the attributed response", %{
    goal: goal,
    contender: contender
  } do
    assert {:ok, %{command: row, events: [event]}} =
             Commands.respond(
               goal.id,
               contender.command_id,
               %{
                 "resolution" => "abandon",
                 "confirmed_by" => "Ada Operator",
                 "intent" => "supervised_execution"
               },
               now: @now
             )

    assert row.response_digest == Command.response_digest(row.response)
    assert event.payload["response"] == row.response
    assert event.payload["response_digest"] == row.response_digest
    refute is_nil(row.response)
    refute is_nil(row.response_digest)
  end

  test "a pre-attribution row without attribution still rebuilds with no backfill", %{
    goal: goal,
    holder: holder,
    contender: contender
  } do
    # A legacy resolution written before attribution existed: response and
    # event carry the resolution only, and the attribution columns stay nil.
    legacy_response = %{"resolution" => "abandon"}
    legacy_digest = Command.response_digest(legacy_response)
    result = %{"kind" => "abandoned", "reason" => "claim_held", "resolved_by" => "user_response"}

    %TrajectoryEvent{goal_id: goal.id, sequence: next_sequence(goal.id)}
    |> TrajectoryEvent.changeset(%{
      "type" => "cobbler.command.resolved",
      "schema_version" => 1,
      "actor" => "cobbler",
      "occurred_at" => @now,
      "idempotency_key" => "cobbler-command-resolved:#{goal.id}:#{contender.command_id}",
      "payload" => %{
        "command_id" => contender.command_id,
        "command_type" => contender.type,
        "response" => legacy_response,
        "response_digest" => legacy_digest,
        "from_status" => "needs_user",
        "to_status" => "resolved",
        "result" => result
      }
    })
    |> Repo.insert!()

    contender
    |> Ecto.Changeset.change(%{
      response: legacy_response,
      response_digest: legacy_digest,
      status: "resolved",
      result: result,
      confirmed_by: nil,
      confirmed_intent: nil
    })
    |> Repo.update!()

    stored = Commands.get(goal.id, contender.command_id, [])
    assert stored.status == "resolved"
    assert is_nil(stored.confirmed_by)
    assert is_nil(stored.confirmed_intent)

    release_holder!(holder)

    assert {:ok, rebuilt} = Commands.rebuild(goal.id, [])
    assert rebuilt.consistent?
    assert rebuilt.divergences == []

    by_id = Map.new(rebuilt.commands, &{&1["command_id"], &1})
    assert is_nil(by_id[contender.command_id]["confirmed_by"])
    assert is_nil(by_id[contender.command_id]["confirmed_intent"])
  end

  defp release_holder!(holder) do
    assert {:ok, _} =
             Commands.submit(
               holder.id,
               release_command("freeing slot for rebuild", command_id: "cmd-attr-release"),
               now: @now
             )
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
end
