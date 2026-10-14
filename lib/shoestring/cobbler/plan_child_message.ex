defmodule Shoestring.Cobbler.PlanChildMessage do
  @moduledoc "Delivery cache for one canonical child event; no provider payload is copied."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:event_id, :binary_id, autogenerate: false}
  schema "cobbler_plan_child_inbox" do
    field :goal_id, :binary_id
    field :execution_id, :binary_id
    field :plan_task_id, :string
    field :revision_number, :integer
    field :plan_digest, :string
    field :attempt, :integer
    field :root_run_id, :binary_id
    field :run_id, :binary_id
    field :source_sequence, :integer
    field :source_type, :string
    field :message_kind, :string
    field :status, :string, default: "pending"
    field :job_id, :integer
    field :observation_event_id, :binary_id
    field :last_reason, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> change(attrs)
    |> validate_required(
      ~w(event_id goal_id execution_id plan_task_id revision_number plan_digest attempt root_run_id run_id source_sequence source_type message_kind)a
    )
    |> validate_number(:source_sequence, greater_than: 0)
    |> validate_number(:revision_number, greater_than: 0)
    |> validate_number(:attempt, greater_than: 0)
    |> foreign_key_constraint(:event_id)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:root_run_id)
    |> unique_constraint(:event_id, name: "cobbler_plan_child_inbox_pkey")
  end
end
