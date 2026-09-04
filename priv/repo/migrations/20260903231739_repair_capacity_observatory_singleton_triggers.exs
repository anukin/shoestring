defmodule Shoestring.Repo.Migrations.RepairCapacityObservatorySingletonTriggers do
  use Ecto.Migration

  @observatory_goal_id "00000000-0000-4000-8000-000000000cb0"
  @observatory_owner_id "00000000-0000-4000-8000-0000000000cb"
  @observatory_title "Capacity Observatory"
  @observatory_description "Protected singleton capacity observatory"
  @observatory_status "protected"

  def up do
    execute "DROP TRIGGER IF EXISTS protect_observatory_goal_delete"
    execute "DROP TRIGGER IF EXISTS protect_observatory_goal_update"

    # Earlier projector versions allowed user-goal leases to reference observatory
    # snapshots. Those derived rows violate the now-enforced same-goal boundary and
    # can prevent observatory rebuilds through their restrictive foreign key.
    execute """
    DELETE FROM harness_execution_leases
    WHERE goal_id != '#{@observatory_goal_id}'
      AND admitted_snapshot_id IN (
        SELECT id
        FROM harness_capacity_snapshots
        WHERE goal_id = '#{@observatory_goal_id}'
      )
    """

    execute(fn ->
      result =
        repo().query!(
          "SELECT owner_id, status, title, description FROM goals WHERE id = ?",
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

        [
          [
            @observatory_owner_id,
            @observatory_status,
            @observatory_title,
            @observatory_description
          ]
        ] ->
          :ok

        [[_owner_id, _status, _title, _description]] ->
          # Preserve a conflicting user row. The identity-qualified triggers below
          # do not lock it, but will protect a genuine singleton provisioned later.
          :ok
      end
    end)

    create_identity_qualified_triggers()
  end

  def down do
    execute(fn ->
      %{rows: [[event_count]]} =
        repo().query!("SELECT COUNT(*) FROM trajectory_events WHERE goal_id = ?", [
          @observatory_goal_id
        ])

      %{rows: [[snapshot_count]]} =
        repo().query!("SELECT COUNT(*) FROM harness_capacity_snapshots WHERE goal_id = ?", [
          @observatory_goal_id
        ])

      if event_count > 0 or snapshot_count > 0 do
        raise "Cannot roll back capacity observatory repair: ledger data exists (#{event_count} events, #{snapshot_count} snapshots) for observatory goal #{@observatory_goal_id}; refusing rollback to prevent data destruction"
      end
    end)

    execute "DROP TRIGGER IF EXISTS protect_observatory_goal_delete"
    execute "DROP TRIGGER IF EXISTS protect_observatory_goal_update"

    execute """
    CREATE TRIGGER IF NOT EXISTS protect_observatory_goal_delete
    BEFORE DELETE ON goals
    WHEN OLD.id = '#{@observatory_goal_id}'
    BEGIN
      SELECT RAISE(ABORT, 'protected observatory goal cannot be deleted');
    END
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS protect_observatory_goal_update
    BEFORE UPDATE ON goals
    WHEN OLD.id = '#{@observatory_goal_id}'
    BEGIN
      SELECT RAISE(ABORT, 'protected observatory goal cannot be updated');
    END
    """
  end

  defp create_identity_qualified_triggers do
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
end
