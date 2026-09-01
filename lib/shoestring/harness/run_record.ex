defmodule Shoestring.Harness.RunRecord do
  @moduledoc "Durable non-derived run identity plus rebuildable lifecycle projection fields."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "harness_runs" do
    field :dispatch_id, :binary_id
    field :provider_id, :string
    field :workspace_ref, :string
    field :request_version, :integer
    field :prompt, :string
    field :continuation, :map
    field :policy, :map
    field :requested_capabilities, :map
    field :status, :string, default: "requested"
    field :provider_session_id, :string
    field :projection_sequence, :integer, default: 0

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :task, Shoestring.Trajectory.Task
    has_many :execution_leases, Shoestring.Harness.ExecutionLeaseRecord, foreign_key: :run_id
    has_many :checkpoints, Shoestring.Harness.CheckpointRecord, foreign_key: :run_id
    has_many :capacity_snapshots, Shoestring.Harness.CapacitySnapshotRecord, foreign_key: :run_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Only contract-derived fields may create a durable run identity."
  @spec intent_changeset(t(), Shoestring.Harness.RunRequest.t(), String.t(), DateTime.t()) ::
          Ecto.Changeset.t()
  def intent_changeset(run, request, provider_id, now) do
    run
    |> cast(%{}, [])
    |> put_change(:id, run.id)
    |> put_change(:goal_id, request.goal_id)
    |> put_change(:task_id, request.task_id)
    |> put_change(:dispatch_id, request.dispatch_id)
    |> put_change(:provider_id, provider_id)
    |> put_change(:workspace_ref, request.workspace_ref)
    |> put_change(:request_version, request.version)
    |> put_change(:prompt, request.prompt)
    |> put_change(:continuation, request.continuation)
    |> put_change(:policy, request.policy)
    |> put_change(:requested_capabilities, %{items: request.requested_capabilities})
    |> put_change(:status, "requested")
    |> put_change(:projection_sequence, 0)
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
    |> validate_required([
      :id,
      :goal_id,
      :task_id,
      :dispatch_id,
      :provider_id,
      :workspace_ref,
      :request_version,
      :prompt,
      :policy,
      :requested_capabilities
    ])
    |> validate_inclusion(:status, [
      "requested",
      "starting",
      "running",
      "pausing",
      "suspended",
      "completed",
      "failed",
      "cancelling",
      "cancelled"
    ])
    |> unique_constraint(:dispatch_id, name: "harness_runs_dispatch_id_index")
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:task_id)
    |> check_constraint(:request_version, name: "harness_runs_request_version_positive")
    |> check_constraint(:status, name: "harness_runs_status_valid")
  end

  @spec projection_changeset(t(), map()) :: Ecto.Changeset.t()
  def projection_changeset(run, attrs) do
    run
    |> cast(attrs, [:status, :provider_session_id, :projection_sequence, :updated_at])
    |> validate_required([:status, :projection_sequence])
    |> validate_inclusion(:status, [
      "requested",
      "starting",
      "running",
      "pausing",
      "suspended",
      "completed",
      "failed",
      "cancelling",
      "cancelled"
    ])
    |> validate_number(:projection_sequence, greater_than_or_equal_to: 0)
    |> check_constraint(:status, name: "harness_runs_status_valid")
    |> check_constraint(:projection_sequence,
      name: "harness_runs_projection_sequence_nonnegative"
    )
  end

  @type t :: %__MODULE__{}
end
