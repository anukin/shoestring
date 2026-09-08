defmodule Shoestring.Cobbler.CommandRecord do
  @moduledoc """
  Durable row for one goal-scoped Cobbler command.

  The intent (`command_id`, `type`, `payload`, `digest`), the validated state
  transition (`status`), and the recorded `result` are written in a single
  transaction together with the canonical trajectory event, so a persisted
  row always represents a complete command outcome. `status` is never
  `pending` in storage: the pending state is transient and a bare intent
  without a result cannot be persisted.

  Replay semantics are enforced by the `(goal_id, command_id)` unique index
  plus the stored `digest`: an identical re-submission returns the original
  result without appending events, and a conflicting re-submission is
  rejected. This slice is record-only — commands do not execute, spawn, or
  enqueue anything.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cobbler_commands" do
    field :command_id, :string
    field :version, :integer, default: 1
    field :type, :string
    field :payload, :map
    field :digest, :string
    field :status, :string
    field :result, :map
    field :response, :map
    field :response_digest, :string

    belongs_to :goal, Shoestring.Trajectory.Goal

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds the single, complete record for an accepted command outcome."
  @spec outcome_changeset(
          t() | Ecto.Changeset.t(),
          Ecto.UUID.t(),
          Shoestring.Cobbler.Command.t(),
          String.t(),
          map(),
          DateTime.t()
        ) ::
          Ecto.Changeset.t()
  def outcome_changeset(
        record,
        goal_id,
        %Shoestring.Cobbler.Command{} = command,
        status,
        result,
        now
      ) do
    record
    |> cast(%{}, [])
    |> put_change(:goal_id, goal_id)
    |> put_change(:command_id, command.command_id)
    |> put_change(:version, command.version)
    |> put_change(:type, command.type)
    |> put_change(:payload, command.payload)
    |> put_change(:digest, command.digest)
    |> put_change(:status, status)
    |> put_change(:result, result)
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
    |> foreign_key_constraint(:goal_id)
    |> unique_constraint(:command_id, name: "cobbler_commands_goal_id_command_id_index")
    |> check_constraint(:status, name: "cobbler_commands_status_valid")
    |> check_constraint(:type, name: "cobbler_commands_type_valid")
    |> check_constraint(:version, name: "cobbler_commands_version_positive")
  end

  @doc "Applies a validated user response that resolves a needs_user command."
  @spec response_changeset(t(), map(), String.t(), String.t(), map(), DateTime.t()) ::
          Ecto.Changeset.t()
  def response_changeset(%__MODULE__{} = record, response, response_digest, status, result, now) do
    record
    |> cast(%{}, [])
    |> put_change(:response, response)
    |> put_change(:response_digest, response_digest)
    |> put_change(:status, status)
    |> put_change(:result, result)
    |> put_change(:updated_at, now)
    |> foreign_key_constraint(:goal_id)
    |> check_constraint(:status, name: "cobbler_commands_status_valid")
    |> check_constraint(:response_digest, name: "cobbler_commands_response_digest_pair")
  end

  @type t :: %__MODULE__{}
end
