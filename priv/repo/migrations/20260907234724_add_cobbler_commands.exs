defmodule Shoestring.Repo.Migrations.AddCobblerCommands do
  use Ecto.Migration

  # Upgrading from the superseded PR #50 foundation
  # (20260907234352_create_cobbler_foundation): that migration created
  # cobbler_commands/cobbler_intents/cobbler_claims in the PR #50 shape, which
  # is incompatible with the schema below. Drop those tables first so the two
  # migrations compose on databases migrated from either side of the merge.
  # Pre-MVP: no production data exists in these tables; nothing is preserved.
  def up do
    drop_if_exists table(:cobbler_claims)
    drop_if_exists table(:cobbler_intents)
    drop_if_exists table(:cobbler_commands)

    create table(:cobbler_commands, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      add :command_id, :string,
        null: false,
        check: %{name: "cobbler_commands_command_id_present", expr: "length(command_id) > 0"}

      add :version, :integer,
        null: false,
        default: 1,
        check: %{name: "cobbler_commands_version_positive", expr: "version > 0"}

      add :type, :string,
        null: false,
        check: %{
          name: "cobbler_commands_type_valid",
          expr: "type IN ('task.claim', 'task.release')"
        }

      add :payload, :map, null: false

      add :digest, :string,
        null: false,
        check: %{name: "cobbler_commands_digest_present", expr: "length(digest) > 0"}

      # A persisted command always carries its transition and result: the
      # intent, the state transition, and the result commit in one write
      # transaction, so a bare 'pending' row can never exist.
      add :status, :string,
        null: false,
        check: %{
          name: "cobbler_commands_status_valid",
          expr: "status IN ('needs_user', 'resolved', 'rejected')"
        }

      add :result, :map, null: false
      add :response, :map

      add :response_digest, :string,
        check: %{
          name: "cobbler_commands_response_digest_pair",
          expr: "(response IS NULL) = (response_digest IS NULL)"
        }

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cobbler_commands, [:goal_id, :command_id])
    create index(:cobbler_commands, [:goal_id, :status])
    create index(:cobbler_commands, [:type, :status])

    create table(:cobbler_task_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :scope, :string,
        null: false,
        default: "global",
        check: %{name: "cobbler_task_claims_scope_global", expr: "scope = 'global'"}

      add :status, :string,
        null: false,
        default: "active",
        check: %{
          name: "cobbler_task_claims_status_valid",
          expr: "status IN ('active', 'released')"
        }

      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      add :command_id, :string,
        null: false,
        check: %{name: "cobbler_task_claims_command_id_present", expr: "length(command_id) > 0"}

      add :intent, :string,
        null: false,
        check: %{name: "cobbler_task_claims_intent_present", expr: "length(intent) > 0"}

      add :provider_id, :string,
        null: false,
        check: %{name: "cobbler_task_claims_provider_id_present", expr: "length(provider_id) > 0"}

      add :admission_decision_id, :string, null: false
      add :admission_event_id, :binary_id, null: false

      # Exclusivity lives in the partial unique index below; these checks keep
      # the release fields consistent with the status. SQLite evaluates
      # column checks against the whole row, so they may reference status.
      add :released_by_command_id, :string,
        check: %{
          name: "cobbler_task_claims_release_attribution_present",
          expr:
            "status = 'active' OR (released_by_command_id IS NOT NULL AND release_reason IS NOT NULL)"
        }

      add :release_reason, :string

      add :released_at, :utc_datetime_usec,
        check: %{
          name: "cobbler_task_claims_release_fields_consistent",
          expr: "(status = 'active') = (released_at IS NULL)"
        }

      timestamps(type: :utc_datetime_usec)
    end

    # SQLite enforces the atomic exclusive global claim: at most one active
    # claim row can exist, so the second concurrent writer loses on the index,
    # never through a count-then-act read.
    create unique_index(:cobbler_task_claims, [:scope], where: "status = 'active'")
    create index(:cobbler_task_claims, [:goal_id, :status])
    create index(:cobbler_task_claims, [:admission_event_id])
  end

  def down do
    drop_if_exists table(:cobbler_task_claims)
    drop_if_exists table(:cobbler_commands)

    create table(:cobbler_commands, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :command_id, :string, null: false
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :intent_id, :binary_id
      add :command_type, :string, null: false
      add :payload, :map, null: false
      add :payload_hash, :string, null: false
      add :status, :string, null: false
      add :result, :map, null: false
      add :trajectory_event_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cobbler_commands, [:goal_id, :command_id],
             name: :cobbler_commands_goal_id_command_id_index
           )

    create index(:cobbler_commands, [:goal_id, :intent_id])

    create table(:cobbler_intents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :title, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :requested_capability, :string, null: false
      add :provider_id, :string, null: false
      add :account_id, :string, null: false
      add :scope, :string, null: false
      add :admission_decision_id, :binary_id, null: false
      add :proposed_bounds, :map, null: false
      add :override, :map
      add :recovery_data, :map
      add :terminal_reason, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cobbler_intents, [:goal_id, :status])
    create index(:cobbler_intents, [:provider_id, :scope])

    create table(:cobbler_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :claim_slot, :string, null: false, default: "global_active"
      add :active_slot, :string
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      add :intent_id, references(:cobbler_intents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :command_id, :string, null: false
      add :provider_id, :string, null: false
      add :account_id, :string, null: false
      add :scope, :string, null: false
      add :status, :string, null: false, default: "active"
      add :claimed_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec
      add :release_reason, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cobbler_claims, [:active_slot], name: :cobbler_claims_active_slot_index)

    create unique_index(:cobbler_claims, [:claim_slot],
             where: "status = 'active'",
             name: :cobbler_claims_singleton_active_index
           )

    create index(:cobbler_claims, [:goal_id, :intent_id])
    create index(:cobbler_claims, [:status])
  end
end
