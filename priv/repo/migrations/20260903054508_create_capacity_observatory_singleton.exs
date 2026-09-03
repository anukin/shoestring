defmodule Shoestring.Repo.Migrations.CreateCapacityObservatorySingleton do
  use Ecto.Migration

  @observatory_goal_id "00000000-0000-4000-8000-000000000cb0"
  @observatory_owner_id "00000000-0000-4000-8000-0000000000cb"
  @observatory_title "Capacity Observatory"
  @observatory_description "Protected singleton capacity observatory"
  @observatory_status "protected"

  def up do
    execute(fn ->
      result =
        repo().query!(
          "SELECT id, owner_id, title, status FROM goals WHERE id = ?",
          [@observatory_goal_id]
        )

      case result.rows do
        [] ->
          repo().query!(
            """
            INSERT INTO goals (id, owner_id, title, description, status, inserted_at, updated_at)
            VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            """,
            [
              @observatory_goal_id,
              @observatory_owner_id,
              @observatory_title,
              @observatory_description,
              @observatory_status
            ]
          )

        [[@observatory_goal_id, @observatory_owner_id, @observatory_title, @observatory_status]] ->
          :ok

        [[id, owner_id, title, status]] ->
          raise "Cannot provision capacity observatory: pre-existing conflicting goal found at reserved ID #{id} with owner #{inspect(owner_id)}, title #{inspect(title)}, status #{inspect(status)}"
      end
    end)

    execute """
    CREATE TRIGGER IF NOT EXISTS protect_observatory_goal_delete
    BEFORE DELETE ON goals
    WHEN OLD.id = '#{@observatory_goal_id}'
      AND OLD.owner_id = '#{@observatory_owner_id}'
      AND OLD.status = '#{@observatory_status}'
    BEGIN
      SELECT RAISE(ABORT, 'protected observatory goal cannot be deleted');
    END
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS protect_observatory_goal_update
    BEFORE UPDATE ON goals
    WHEN OLD.id = '#{@observatory_goal_id}'
      AND OLD.owner_id = '#{@observatory_owner_id}'
      AND OLD.status = '#{@observatory_status}'
    BEGIN
      SELECT RAISE(ABORT, 'protected observatory goal cannot be updated');
    END
    """
  end

  def down do
    execute(fn ->
      event_count =
        case repo().query!("SELECT COUNT(*) FROM trajectory_events WHERE goal_id = ?", [
               @observatory_goal_id
             ]) do
          %{rows: [[count]]} -> count
          _ -> 0
        end

      snapshot_count =
        case repo().query!("SELECT COUNT(*) FROM harness_capacity_snapshots WHERE goal_id = ?", [
               @observatory_goal_id
             ]) do
          %{rows: [[count]]} -> count
          _ -> 0
        end

      if event_count > 0 or snapshot_count > 0 do
        raise "Cannot roll back capacity observatory migration: ledger data exists (#{event_count} events, #{snapshot_count} snapshots) for observatory goal #{@observatory_goal_id}; refusing rollback to prevent data destruction"
      end
    end)

    execute "DROP TRIGGER IF EXISTS protect_observatory_goal_delete"
    execute "DROP TRIGGER IF EXISTS protect_observatory_goal_update"

    execute(fn ->
      repo().query!(
        "DELETE FROM goals WHERE id = ? AND owner_id = ? AND status = ?",
        [@observatory_goal_id, @observatory_owner_id, @observatory_status]
      )
    end)
  end
end
