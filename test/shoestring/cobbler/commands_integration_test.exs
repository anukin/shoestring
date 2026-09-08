defmodule Shoestring.Cobbler.CommandsIntegrationTest do
  @moduledoc """
  Hermetic integration tests binding the Cobbler command foundation to the
  trajectory boundary and the generated migration: registry validation, the
  standard writer append path, safety scanning, and the SQLite schema
  constraints that make the global claim exclusive. No provider CLIs, no
  network, no execution.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.EventRegistry

  import Shoestring.Test.CobblerHelpers

  @now ~U[2026-09-07 12:00:00.000000Z]

  @cobbler_types [
    {"cobbler.command.accepted", 1},
    {"cobbler.command.resolved", 1},
    {"cobbler.claim.acquired", 1},
    {"cobbler.claim.released", 1}
  ]

  describe "event registry" do
    test "cobbler command event types are registered at version 1" do
      registered = EventRegistry.registered_types()
      assert @cobbler_types -- registered == []
    end

    test "cobbler.command.accepted validates its payload and rejects required gaps" do
      payload = %{
        "command_id" => "cmd-registry-1",
        "command_type" => "task.claim",
        "command_digest" => String.duplicate("a", 64),
        "command_payload" => %{"intent" => "supervised_execution"},
        "from_status" => "pending",
        "to_status" => "resolved",
        "result" => %{"kind" => "claimed"}
      }

      assert {:ok, ^payload} =
               EventRegistry.validate_payload("cobbler.command.accepted", 1, payload, now: @now)

      assert {:error, {:invalid_payload, "cobbler.command.accepted", 1, changeset}} =
               EventRegistry.validate_payload(
                 "cobbler.command.accepted",
                 1,
                 Map.delete(payload, "result"),
                 now: @now
               )

      assert "can't be blank" in errors_on(changeset).result
    end

    test "claim_id is validated as a UUID when present" do
      base = %{
        "command_id" => "cmd-registry-2",
        "command_type" => "task.claim",
        "command_digest" => String.duplicate("b", 64),
        "command_payload" => %{},
        "from_status" => "pending",
        "to_status" => "needs_user",
        "result" => %{"kind" => "needs_user"}
      }

      assert {:ok, _} =
               EventRegistry.validate_payload(
                 "cobbler.command.accepted",
                 1,
                 Map.put(base, "claim_id", "01950000-0000-7000-8000-0000000000cc"),
                 now: @now
               )

      assert {:error, {:invalid_payload, "cobbler.command.accepted", 1, _changeset}} =
               EventRegistry.validate_payload(
                 "cobbler.command.accepted",
                 1,
                 Map.put(base, "claim_id", "not-a-uuid"),
                 now: @now
               )
    end

    test "cobbler payloads are scanned for secrets and raw transcripts" do
      payload = %{
        "command_id" => "cmd-registry-3",
        "command_type" => "task.claim",
        "command_digest" => String.duplicate("c", 64),
        "command_payload" => %{"intent" => "supervised_execution"},
        "from_status" => "pending",
        "to_status" => "resolved",
        "result" => %{"credential" => "sk-abcdefgh12345678"}
      }

      assert {:error, {:invalid_payload, "cobbler.command.accepted", 1, changeset}} =
               EventRegistry.validate_payload("cobbler.command.accepted", 1, payload, now: @now)

      assert changeset.errors[:base] != nil
    end
  end

  describe "trajectory boundary" do
    test "cobbler events flow through the standard writer append and replay" do
      goal = create_goal!()

      accepted = %{
        "type" => "cobbler.command.accepted",
        "schema_version" => 1,
        "actor" => "cobbler",
        "occurred_at" => @now,
        "idempotency_key" => "cobbler-command-accepted:#{goal.id}:cmd-writer-1",
        "payload" => %{
          "command_id" => "cmd-writer-1",
          "command_type" => "task.claim",
          "command_digest" => String.duplicate("d", 64),
          "command_payload" => %{"intent" => "supervised_execution"},
          "from_status" => "pending",
          "to_status" => "resolved",
          "result" => %{"kind" => "claimed"}
        }
      }

      assert {:ok, appended} = Trajectory.append(goal.id, accepted)
      assert appended.type == "cobbler.command.accepted"
      assert appended.actor == "cobbler"
      assert appended.sequence == 1

      assert {:ok, events} = Trajectory.replay(goal.id)
      assert Enum.map(events, & &1.type) == ["cobbler.command.accepted"]
    end

    test "cobbler event inputs coexist with other canonical families in replay" do
      goal = create_goal!()

      {:ok, _} =
        Trajectory.append(goal.id, %{
          "type" => "goal.created",
          "schema_version" => 1,
          "actor" => "system",
          "occurred_at" => @now,
          "payload" => %{"title" => goal.title}
        })

      append_admission_event!(goal.id)

      assert {:ok, events} = Trajectory.replay(goal.id)
      assert Enum.map(events, & &1.type) == ["goal.created", "admission.decided"]
    end
  end

  describe "generated migration schema" do
    test "cobbler tables carry the exclusive claim and command identity constraints" do
      assert ["cobbler_commands", "cobbler_task_claims"] -- table_names() == []

      command_indexes = index_names("cobbler_commands")
      assert "cobbler_commands_goal_id_command_id_index" in command_indexes
      assert "cobbler_commands_goal_id_status_index" in command_indexes

      claim_indexes = index_names("cobbler_task_claims")
      assert "cobbler_task_claims_scope_index" in claim_indexes

      assert partial_index_sql("cobbler_task_claims_scope_index") =~ ~r/status\s*=\s*'active'/
    end

    test "the partial unique index rejects a second active claim on one connection" do
      goal = create_goal!()

      assert {:ok, _} = Repo.query(claim_insert_sql(), claim_params(goal.id, "cmd-schema-1"))

      assert {:error, _constraint} =
               Repo.query(claim_insert_sql(), claim_params(goal.id, "cmd-schema-2"))

      {:ok, %{rows: [[active_count]]}} =
        Repo.query("SELECT count(*) FROM cobbler_task_claims WHERE status = 'active'", [])

      assert active_count == 1

      # A released row no longer competes for the exclusive slot.
      assert {:ok, _} =
               Repo.query(
                 "UPDATE cobbler_task_claims SET status = 'released', released_at = ?, released_by_command_id = ?, release_reason = ? WHERE command_id = ?",
                 [iso(@now), "cmd-schema-release", "done", "cmd-schema-1"]
               )

      assert {:ok, _} = Repo.query(claim_insert_sql(), claim_params(goal.id, "cmd-schema-3"))
    end

    test "check constraints reject invalid command and claim states" do
      goal = create_goal!()

      assert {:error, _} =
               Repo.query(
                 "INSERT INTO cobbler_commands (id, goal_id, command_id, version, type, payload, digest, status, result, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                 [
                   Ecto.UUID.generate(),
                   goal.id,
                   "cmd-bad-status",
                   1,
                   "task.claim",
                   "{}",
                   String.duplicate("a", 64),
                   "pending",
                   "{}",
                   iso(@now),
                   iso(@now)
                 ]
               )

      assert {:error, _} =
               Repo.query(
                 "INSERT INTO cobbler_commands (id, goal_id, command_id, version, type, payload, digest, status, result, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                 [
                   Ecto.UUID.generate(),
                   goal.id,
                   "cmd-bad-type",
                   1,
                   "task.execute",
                   "{}",
                   String.duplicate("a", 64),
                   "resolved",
                   "{}",
                   iso(@now),
                   iso(@now)
                 ]
               )

      assert {:ok, _} =
               Repo.query(claim_insert_sql(), claim_params(goal.id, "cmd-schema-constraint"))

      assert {:error, _} =
               Repo.query(
                 "UPDATE cobbler_task_claims SET status = 'active', released_at = ? WHERE command_id = ?",
                 [iso(@now), "cmd-schema-constraint"]
               )

      assert {:error, _} =
               Repo.query(
                 "UPDATE cobbler_task_claims SET scope = 'account:codex' WHERE command_id = ?",
                 ["cmd-schema-constraint"]
               )
    end
  end

  defp claim_insert_sql do
    "INSERT INTO cobbler_task_claims
       (id, scope, status, goal_id, command_id, intent, provider_id,
        admission_decision_id, admission_event_id, inserted_at, updated_at)
     VALUES (?, 'global', 'active', ?, ?, 'supervised_execution', 'codex',
             ?, ?, ?, ?)"
  end

  defp claim_params(goal_id, command_id) do
    [
      Ecto.UUID.generate(),
      goal_id,
      command_id,
      "00000000-0000-4000-8000-0000000000ee",
      Ecto.UUID.generate(),
      iso(@now),
      iso(@now)
    ]
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp table_names do
    {:ok, %{rows: rows}} = Repo.query("SELECT name FROM sqlite_master WHERE type = 'table'", [])
    Enum.map(rows, &hd/1)
  end

  defp index_names(table) do
    {:ok, %{rows: rows}} =
      Repo.query("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", [table])

    Enum.map(rows, &hd/1)
  end

  defp partial_index_sql(index_name) do
    {:ok, %{rows: [[sql]]}} =
      Repo.query("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", [index_name])

    sql
  end
end
