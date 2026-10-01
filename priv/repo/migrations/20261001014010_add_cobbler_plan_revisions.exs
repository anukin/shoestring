defmodule Shoestring.Repo.Migrations.AddCobblerPlanRevisions do
  use Ecto.Migration

  # Durable storage for immutable plan revisions and the terminal human
  # decision on each one.
  #
  # Two SQLite-enforced invariants carry the authority rules, so concurrency
  # loses on an index rather than on a read-then-write race:
  #
  #   * at most ONE approved revision per goal, enforced by a partial unique
  #     index over `goal_id` where `status = 'approved'`. Two concurrent
  #     approvals cannot both win; the loser sees a constraint violation and
  #     its whole transaction rolls back.
  #   * at most ONE decision per revision, enforced by a unique index on
  #     `plan_revision_id` in the decisions table. A revision cannot be both
  #     approved and rejected, and cannot be approved twice under two
  #     different decision ids.
  #
  # Revision rows are append-only in substance: `content`, `digest`, and
  # `revision_number` are written once and never updated. The only column
  # that changes after insert is `status`, and only along
  # proposed -> approved | rejected and approved -> superseded.
  def up do
    create table(:cobbler_plan_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      # Caller-supplied, goal-scoped idempotency key. Re-proposing the same
      # id with the same digest replays; with a different digest it is a
      # conflict, exactly like a Cobbler command id.
      add :proposal_id, :string,
        null: false,
        check: %{
          name: "cobbler_plan_revisions_proposal_id_present",
          expr: "length(proposal_id) > 0"
        }

      add :revision_number, :integer,
        null: false,
        check: %{
          name: "cobbler_plan_revisions_revision_number_positive",
          expr: "revision_number > 0"
        }

      # A revision derived from an earlier one records its parent, so the
      # edit lineage is a durable fact rather than an inference from
      # numbering.
      add :parent_revision_number, :integer,
        check: %{
          name: "cobbler_plan_revisions_parent_before_child",
          expr: "parent_revision_number IS NULL OR parent_revision_number < revision_number"
        }

      add :plan_version, :integer,
        null: false,
        check: %{
          name: "cobbler_plan_revisions_plan_version_positive",
          expr: "plan_version > 0"
        }

      add :digest, :string,
        null: false,
        check: %{name: "cobbler_plan_revisions_digest_present", expr: "length(digest) > 0"}

      add :content, :map, null: false

      add :status, :string,
        null: false,
        check: %{
          name: "cobbler_plan_revisions_status_valid",
          expr: "status IN ('proposed', 'approved', 'rejected', 'superseded')"
        }

      # Revisions in this slice are human-authored. A planner may be recorded
      # as provenance inside `content`, but it never authors or approves.
      add :authored_by, :string,
        null: false,
        check: %{
          name: "cobbler_plan_revisions_authored_by_present",
          expr: "length(authored_by) > 0"
        }

      add :author_kind, :string,
        null: false,
        default: "human",
        check: %{
          name: "cobbler_plan_revisions_author_kind_human",
          expr: "author_kind = 'human'"
        }

      add :task_count, :integer,
        null: false,
        check: %{name: "cobbler_plan_revisions_task_count_positive", expr: "task_count > 0"}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cobbler_plan_revisions, [:goal_id, :revision_number])
    create unique_index(:cobbler_plan_revisions, [:goal_id, :proposal_id])

    # The single active authority. Superseded, rejected, and still-proposed
    # revisions are all outside this index and can never authorize dispatch.
    create unique_index(:cobbler_plan_revisions, [:goal_id], where: "status = 'approved'")

    create index(:cobbler_plan_revisions, [:goal_id, :status])

    create table(:cobbler_plan_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      add :plan_revision_id,
          references(:cobbler_plan_revisions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :decision_id, :string,
        null: false,
        check: %{
          name: "cobbler_plan_decisions_decision_id_present",
          expr: "length(decision_id) > 0"
        }

      add :revision_number, :integer,
        null: false,
        check: %{
          name: "cobbler_plan_decisions_revision_number_positive",
          expr: "revision_number > 0"
        }

      add :kind, :string,
        null: false,
        check: %{
          name: "cobbler_plan_decisions_kind_valid",
          expr: "kind IN ('approve', 'reject')"
        }

      # The exact content digest the human decided against. An approval that
      # does not carry the digest of the revision it names is stale and is
      # rejected before it reaches this table.
      add :bound_digest, :string,
        null: false,
        check: %{
          name: "cobbler_plan_decisions_bound_digest_present",
          expr: "length(bound_digest) > 0"
        }

      # A rejection must say why; an approval may carry an optional note.
      add :reason, :string,
        check: %{
          name: "cobbler_plan_decisions_reason_required_on_reject",
          expr: "kind = 'approve' OR (reason IS NOT NULL AND length(reason) > 0)"
        }

      add :note, :string

      add :decided_by, :string,
        null: false,
        check: %{
          name: "cobbler_plan_decisions_decided_by_present",
          expr: "length(decided_by) > 0"
        }

      add :decided_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cobbler_plan_decisions, [:goal_id, :decision_id])

    # One terminal decision per revision. This is what makes a replayed
    # approval converge instead of authorizing twice.
    create unique_index(:cobbler_plan_decisions, [:plan_revision_id])
    create index(:cobbler_plan_decisions, [:goal_id, :kind])
  end

  def down do
    drop_if_exists table(:cobbler_plan_decisions)
    drop_if_exists table(:cobbler_plan_revisions)
  end
end
