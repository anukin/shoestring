defmodule Shoestring.Harness.DispatchRecord do
  @moduledoc "Durable delivery intent whose state, not an Oban job, governs external effects."

  use Ecto.Schema

  import Ecto.Changeset

  alias Shoestring.Harness.RunRecord

  @primary_key {:dispatch_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @statuses [
    "requested",
    "effect_started",
    "effect_failed",
    "effect_unknown",
    "effect_completed",
    "cancelled"
  ]

  schema "harness_dispatches" do
    field :request_version, :integer
    field :status, :string, default: "requested"
    field :job_id, :integer
    field :outcome_code, :string
    field :outcome_at, :utc_datetime_usec

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :task, Shoestring.Trajectory.Task
    belongs_to :run, RunRecord

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec intent_changeset(t(), RunRecord.t(), DateTime.t()) :: Ecto.Changeset.t()
  def intent_changeset(dispatch, run, now) do
    dispatch
    |> cast(%{}, [])
    |> put_change(:dispatch_id, run.dispatch_id)
    |> put_change(:goal_id, run.goal_id)
    |> put_change(:task_id, run.task_id)
    |> put_change(:run_id, run.id)
    |> put_change(:request_version, run.request_version)
    |> put_change(:status, "requested")
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
    |> validate_required([:dispatch_id, :goal_id, :task_id, :run_id, :request_version, :status])
    |> validate_number(:request_version, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:dispatch_id, name: "harness_dispatches_dispatch_id_index")
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:request_version, name: "harness_dispatches_request_version_positive")
    |> check_constraint(:status, name: "harness_dispatches_status_valid")
  end

  @spec job_changeset(t(), pos_integer(), DateTime.t()) :: Ecto.Changeset.t()
  def job_changeset(dispatch, job_id, now) do
    dispatch
    |> change(job_id: job_id, updated_at: now)
    |> foreign_key_constraint(:job_id)
    |> unique_constraint(:job_id)
  end

  @spec status_changeset(t(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def status_changeset(dispatch, status, now) do
    dispatch
    |> change(status: status, updated_at: now)
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: "harness_dispatches_status_valid")
  end

  @spec outcome_changeset(t(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def outcome_changeset(dispatch, status, now)
      when status in ["effect_failed", "effect_unknown"] do
    dispatch
    |> change(status: status, outcome_code: status, outcome_at: now, updated_at: now)
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: "harness_dispatches_status_valid")
  end

  @type t :: %__MODULE__{}
end
