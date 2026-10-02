defmodule Shoestring.Repo.Migrations.CreateCobblerPlannerRequests do
  use Ecto.Migration

  # Durable ledger for bounded planner inference (iteration 6, package B).
  #
  # One row per goal-scoped `request_id`. The row is the idempotency token
  # AND the attempt budget: it is claimed (`in_progress`) before any planner
  # invocation, every invocation increments `attempts_used`, and at most
  # `max_attempts` (2: one attempt plus one bounded repair) invocations ever
  # happen for a request. Concurrency loses on the unique
  # `(goal_id, request_id)` index, never on a read-then-write race, and a
  # restart re-reads the row instead of resetting the budget.
  #
  # Terminal states are `proposed` (a revision was persisted through
  # `Shoestring.Cobbler.Plans`), `manual_required` (quota-blocked or repair
  # exhausted: a human must plan or edit), `failed` (transport error or
  # unsafe proposal), and `cancelled` (explicit human cancellation).
  # Terminal rows never move again; only `in_progress` rows settle.
  def up do
    create table(:cobbler_planner_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      # Caller-supplied, goal-scoped idempotency key. Re-sending the same id
      # with the same input digest replays the stored outcome; with a
      # different digest it is a conflict, exactly like a plan proposal id.
      add :request_id, :string,
        null: false,
        check: %{
          name: "cobbler_planner_requests_request_id_present",
          expr: "length(request_id) > 0"
        }

      # The human who asked for a plan. Planners propose; only humans
      # request, author revisions, and approve them.
      add :requested_by, :string,
        null: false,
        check: %{
          name: "cobbler_planner_requests_requested_by_present",
          expr: "length(requested_by) > 0"
        }

      add :status, :string,
        null: false,
        check: %{
          name: "cobbler_planner_requests_status_valid",
          expr: "status IN ('in_progress', 'proposed', 'manual_required', 'failed', 'cancelled')"
        }

      # Bounded invocation budget. Incremented once per planner invocation,
      # never decremented, never reset by retry, replay, or restart.
      add :attempts_used, :integer,
        null: false,
        default: 0,
        check: %{
          name: "cobbler_planner_requests_attempts_used_bounded",
          expr: "attempts_used >= 0 AND attempts_used <= 2"
        }

      add :max_attempts, :integer,
        null: false,
        default: 2,
        check: %{
          name: "cobbler_planner_requests_max_attempts_two",
          expr: "max_attempts = 2"
        }

      # Which planner was invoked, for provenance. Recorded before invocation
      # and echoed into the persisted plan's planner block.
      add :planner_identity, :string, null: false
      add :planner_version, :string, null: false
      add :planner_model, :string, null: false

      # SHA-256 over the canonical planning inputs. The replay guard: the
      # same request id with the same digest is the same request.
      add :input_digest, :string, null: false

      # Bounded, validated evidence the prompt was built from. Full prompts
      # are never stored; raw model output is never stored here either (a
      # validated plan persists only through the plan revision it created).
      add :goal_statement, :string, null: false
      add :base_revision, :string, null: false
      add :source_context_refs, :map, null: false, default: %{}

      # Terminal settlement. `proposal_id` names the revision the success
      # path persisted; `error_kind`/`error_detail` carry the bounded,
      # redacted reason the terminal path stopped.
      add :proposal_id, :string
      add :revision_number, :integer
      add :plan_digest, :string
      add :error_kind, :string
      add :error_detail, :map

      # Admission decision ids (UUID strings) consumed by this request's
      # attempts, newest last. Each invocation is admitted first; each
      # admission is a durable `admission.decided` event.
      add :admission_decision_ids, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cobbler_planner_requests, [:goal_id, :request_id])
    create index(:cobbler_planner_requests, [:goal_id, :status])
  end

  def down do
    drop_if_exists table(:cobbler_planner_requests)
  end
end
