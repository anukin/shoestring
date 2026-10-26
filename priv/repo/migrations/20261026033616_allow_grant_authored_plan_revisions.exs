defmodule Shoestring.Repo.Migrations.AllowGrantAuthoredPlanRevisions do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Iteration 14 decision 5: a coordinator's dispatch is a plan revision
  # authored under a person's grant, so `author_kind` may now be `grant` as
  # well as `human`. SQLite cannot alter a CHECK constraint, so the table is
  # rebuilt by SQLite's documented procedure: foreign keys off, a new table
  # with the same columns, constraints and indexes, a copy of every row, the
  # old table dropped, the new one renamed, and a foreign-key check before
  # committing. Only the author_kind constraint differs. `down` refuses once a
  # grant-authored revision exists, because the copy would violate the old
  # check.
  def up,
    do:
      rebuild(
        "cobbler_plan_revisions_author_kind_valid",
        "author_kind IN ('human', 'grant')"
      )

  def down,
    do: rebuild("cobbler_plan_revisions_author_kind_human", "author_kind = 'human'")

  defp rebuild(constraint, check) do
    repo().query!("PRAGMA foreign_keys = OFF")

    try do
      repo().query!("BEGIN IMMEDIATE")

      for statement <- statements(constraint, check), do: repo().query!(statement)

      case repo().query!("PRAGMA foreign_key_check") do
        %{rows: []} -> repo().query!("COMMIT")
        %{rows: rows} -> raise "foreign key check failed after rebuild: #{inspect(rows)}"
      end
    rescue
      error ->
        repo().query("ROLLBACK")
        reraise error, __STACKTRACE__
    after
      repo().query!("PRAGMA foreign_keys = ON")
    end
  end

  defp statements(constraint, check) do
    [
      ~s|CREATE TABLE "cobbler_plan_revisions_new" ("id" TEXT PRIMARY KEY, "goal_id" TEXT NOT NULL CONSTRAINT "cobbler_plan_revisions_goal_id_fkey" REFERENCES "goals"("id") ON DELETE CASCADE, "proposal_id" TEXT NOT NULL CONSTRAINT cobbler_plan_revisions_proposal_id_present CHECK (length(proposal_id) > 0), "revision_number" INTEGER NOT NULL CONSTRAINT cobbler_plan_revisions_revision_number_positive CHECK (revision_number > 0), "parent_revision_number" INTEGER CONSTRAINT cobbler_plan_revisions_parent_before_child CHECK (parent_revision_number IS NULL OR parent_revision_number < revision_number), "plan_version" INTEGER NOT NULL CONSTRAINT cobbler_plan_revisions_plan_version_positive CHECK (plan_version > 0), "digest" TEXT NOT NULL CONSTRAINT cobbler_plan_revisions_digest_present CHECK (length(digest) > 0), "content" TEXT NOT NULL, "status" TEXT NOT NULL CONSTRAINT cobbler_plan_revisions_status_valid CHECK (status IN ('proposed', 'approved', 'rejected', 'superseded')), "authored_by" TEXT NOT NULL CONSTRAINT cobbler_plan_revisions_authored_by_present CHECK (length(authored_by) > 0), "author_kind" TEXT DEFAULT 'human' NOT NULL CONSTRAINT #{constraint} CHECK (#{check}), "task_count" INTEGER NOT NULL CONSTRAINT cobbler_plan_revisions_task_count_positive CHECK (task_count > 0), "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)|,
      ~s|INSERT INTO "cobbler_plan_revisions_new" SELECT "id", "goal_id", "proposal_id", "revision_number", "parent_revision_number", "plan_version", "digest", "content", "status", "authored_by", "author_kind", "task_count", "inserted_at", "updated_at" FROM "cobbler_plan_revisions"|,
      ~s|DROP TABLE "cobbler_plan_revisions"|,
      ~s|ALTER TABLE "cobbler_plan_revisions_new" RENAME TO "cobbler_plan_revisions"|,
      ~s|CREATE UNIQUE INDEX "cobbler_plan_revisions_goal_id_revision_number_index" ON "cobbler_plan_revisions" ("goal_id", "revision_number")|,
      ~s|CREATE UNIQUE INDEX "cobbler_plan_revisions_goal_id_proposal_id_index" ON "cobbler_plan_revisions" ("goal_id", "proposal_id")|,
      ~s|CREATE UNIQUE INDEX "cobbler_plan_revisions_goal_id_index" ON "cobbler_plan_revisions" ("goal_id") WHERE status = 'approved'|,
      ~s|CREATE INDEX "cobbler_plan_revisions_goal_id_status_index" ON "cobbler_plan_revisions" ("goal_id", "status")|
    ]
  end
end
