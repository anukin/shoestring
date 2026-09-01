defmodule Shoestring.Harness.CapacitySnapshotRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "harness_capacity_snapshots" do
    field :contract_version, :integer
    field :capacity_state, :string, source: :capacity_state_v2
    field :legacy_capacity_state, :string, source: :capacity_state
    field :observed_at, :utc_datetime_usec, source: :observed_at_v2
    field :legacy_observed_at, :utc_datetime_usec, source: :observed_at
    field :expires_at, :utc_datetime_usec
    field :freshness_max_age_seconds, :integer
    field :source_adapter_id, :string
    field :source_method, :string
    field :source_provider_id, :string
    field :source_invocation_mode, :string
    field :source_event, :string
    field :scope, :string
    field :confidence, :string
    field :support_tier, :string
    field :compatibility_state, :string
    field :reason, :string
    field :extensions, :map
    field :projection_sequence, :integer

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :run, Shoestring.Harness.RunRecord
    has_many :windows, Shoestring.Harness.CapacityWindowRecord, foreign_key: :snapshot_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :contract_version,
      :capacity_state,
      :legacy_capacity_state,
      :observed_at,
      :legacy_observed_at,
      :expires_at,
      :freshness_max_age_seconds,
      :source_adapter_id,
      :source_method,
      :source_provider_id,
      :source_invocation_mode,
      :source_event,
      :scope,
      :confidence,
      :support_tier,
      :compatibility_state,
      :reason,
      :extensions,
      :projection_sequence
    ])
    |> validate_required([
      :id,
      :goal_id,
      :contract_version,
      :capacity_state,
      :legacy_capacity_state,
      :legacy_observed_at,
      :freshness_max_age_seconds,
      :source_adapter_id,
      :source_method,
      :source_provider_id,
      :source_invocation_mode,
      :source_event,
      :scope,
      :confidence,
      :support_tier,
      :compatibility_state,
      :extensions,
      :projection_sequence
    ])
    |> validate_number(:contract_version, greater_than: 0)
    |> validate_number(:freshness_max_age_seconds,
      greater_than: 0,
      less_than_or_equal_to: 86_400
    )
    |> validate_inclusion(:capacity_state, ["observed", "degraded", "refused", "unknown"])
    |> validate_inclusion(:confidence, ["none", "low", "medium", "high"])
    |> validate_inclusion(:support_tier, [
      "proactive",
      "conservative_partial",
      "reactive_only",
      "unsupported"
    ])
    |> validate_inclusion(:compatibility_state, ["compatible", "degraded", "incompatible"])
    |> validate_inclusion(:source_event, [
      "explicit_read",
      "update_notification",
      "status_line_input",
      "headless_result_error",
      "none"
    ])
    |> validate_capacity_state()
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:contract_version, name: "harness_capacity_snapshots_version_positive")
    |> check_constraint(:capacity_state, name: "harness_capacity_snapshots_state_v2_valid")
    |> check_constraint(:freshness_max_age_seconds,
      name: "harness_capacity_snapshots_freshness_positive"
    )
    |> check_constraint(:source_event, name: "harness_capacity_snapshots_source_event_valid")
  end

  defp validate_capacity_state(changeset) do
    case {get_field(changeset, :capacity_state), get_field(changeset, :reason)} do
      {"observed", nil} ->
        changeset

      {"observed", _reason} ->
        add_error(changeset, :reason, "must be blank when capacity is observed")

      {state, reason} when state in ["degraded", "refused", "unknown"] and is_binary(reason) ->
        changeset

      {state, _reason} when state in ["degraded", "refused", "unknown"] ->
        add_error(changeset, :reason, "is required for this capacity state")

      _other ->
        changeset
    end
  end

  @type t :: %__MODULE__{}
end
