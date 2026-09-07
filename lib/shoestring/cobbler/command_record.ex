defmodule Shoestring.Cobbler.CommandRecord do
  @moduledoc """
  Durable record of commands submitted to Cobbler.

  Enforces idempotency and conflict detection at the database layer via a
  unique constraint on `[goal_id, command_id]`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ["applied", "rejected"]

  schema "cobbler_commands" do
    field :command_id, :string
    field :intent_id, :binary_id
    field :command_type, :string
    field :payload, :map, default: %{}
    field :payload_hash, :string
    field :status, :string, default: "applied"
    field :result, :map, default: %{}
    field :trajectory_event_id, :binary_id

    belongs_to :goal, Shoestring.Trajectory.Goal

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for recording a command."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(command_record, attrs) do
    command_record
    |> cast(attrs, [
      :command_id,
      :intent_id,
      :command_type,
      :payload,
      :payload_hash,
      :status,
      :result,
      :trajectory_event_id
    ])
    |> validate_required([:command_id, :command_type, :payload, :payload_hash, :status, :result])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:goal_id, :command_id],
      name: :cobbler_commands_goal_id_command_id_index
    )
  end

  @type t :: %__MODULE__{}
end
