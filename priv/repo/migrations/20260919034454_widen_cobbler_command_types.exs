defmodule Shoestring.Repo.Migrations.WidenCobblerCommandTypes do
  use Ecto.Migration

  # `run.handoff` joins the durable Cobbler command types: the explicit
  # production intent to transfer a run to another provider at a named
  # checkpoint boundary (see `Shoestring.Cobbler.Handoffs`).
  #
  # SQLite cannot alter a CHECK constraint in place, so the table is rebuilt
  # and its rows copied. Every other column, constraint and index is
  # reproduced from `20260907234724_add_cobbler_commands.exs` plus the
  # attribution columns added by
  # `20260909035800_add_response_attribution_to_cobbler_commands.exs`; only
  # the `cobbler_commands_type_valid` expression widens. The rebuild runs
  # inside the migration transaction, so a failure leaves the original table
  # untouched, and `down/0` narrows it back (rows of the new type would then
  # violate the narrowed check — none exist pre-MVP).

  @old_types "type IN ('task.claim', 'task.release')"
  @new_types "type IN ('task.claim', 'task.release', 'run.handoff')"

  def up, do: rebuild(@new_types)

  def down, do: rebuild(@old_types)

  defp rebuild(type_expr) do
    create table(:cobbler_commands_rebuild, primary_key: false) do
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
        check: %{name: "cobbler_commands_type_valid", expr: type_expr}

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

      add :confirmed_by, :string
      add :confirmed_intent, :string

      timestamps(type: :utc_datetime_usec)
    end

    execute """
    INSERT INTO cobbler_commands_rebuild
      (id, goal_id, command_id, version, type, payload, digest, status, result,
       response, response_digest, confirmed_by, confirmed_intent, inserted_at, updated_at)
    SELECT
       id, goal_id, command_id, version, type, payload, digest, status, result,
       response, response_digest, confirmed_by, confirmed_intent, inserted_at, updated_at
    FROM cobbler_commands
    """

    drop table(:cobbler_commands)
    rename table(:cobbler_commands_rebuild), to: table(:cobbler_commands)

    create unique_index(:cobbler_commands, [:goal_id, :command_id])
    create index(:cobbler_commands, [:goal_id, :status])
    create index(:cobbler_commands, [:type, :status])
  end
end
