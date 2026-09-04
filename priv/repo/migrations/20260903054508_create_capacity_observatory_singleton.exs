defmodule Shoestring.Repo.Migrations.CreateCapacityObservatorySingleton do
  use Ecto.Migration

  @observatory_goal_id "00000000-0000-4000-8000-000000000cb0"
  @observatory_owner_id "00000000-0000-4000-8000-0000000000cb"
  @observatory_title "Capacity Observatory"
  @observatory_description "Protected singleton capacity observatory"
  @observatory_status "protected"

  def up do
    execute """
    INSERT OR IGNORE INTO goals (id, owner_id, title, description, status, inserted_at, updated_at)
    VALUES (
      '#{@observatory_goal_id}',
      '#{@observatory_owner_id}',
      '#{@observatory_title}',
      '#{@observatory_description}',
      '#{@observatory_status}',
      CURRENT_TIMESTAMP,
      CURRENT_TIMESTAMP
    )
    """

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

  def down do
    execute "DROP TRIGGER IF EXISTS protect_observatory_goal_delete"
    execute "DROP TRIGGER IF EXISTS protect_observatory_goal_update"
    execute "DELETE FROM goals WHERE id = '#{@observatory_goal_id}'"
  end
end
