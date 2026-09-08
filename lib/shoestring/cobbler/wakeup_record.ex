defmodule Shoestring.Cobbler.WakeupRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ["scheduled", "due", "woken", "cancelled"]

  schema "cobbler_wakeups" do
    field :command_id, :string
    field :wake_at, :utc_datetime_usec
    field :reason, :string
    field :status, :string, default: "scheduled"
    field :idempotency_key, :string

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :run, Shoestring.Harness.RunRecord

    timestamps(type: :utc_datetime_usec)
  end

  @doc "All durable wakeup statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(wakeup, attrs) do
    wakeup
    |> cast(attrs, [
      :goal_id,
      :run_id,
      :command_id,
      :wake_at,
      :reason,
      :status,
      :idempotency_key,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([:goal_id, :wake_at, :reason, :status, :idempotency_key])
    |> validate_length(:reason, min: 1, max: 300)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:run_id)
    |> unique_constraint(:idempotency_key, name: :cobbler_wakeups_idempotency_key_index)
    |> check_constraint(:status, name: "cobbler_wakeups_status_valid")
  end

  @type t :: %__MODULE__{}
end
