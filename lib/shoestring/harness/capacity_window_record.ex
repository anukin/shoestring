defmodule Shoestring.Harness.CapacityWindowRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "harness_capacity_windows" do
    field :kind, :string
    field :state, :string, source: :state_v2
    field :legacy_state, :string, source: :state
    field :used_percent, :float
    field :reset_at, :utc_datetime_usec
    field :unknown_reason, :string

    belongs_to :snapshot, Shoestring.Harness.CapacitySnapshotRecord

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(window, attrs) do
    window
    |> cast(attrs, [:kind, :state, :legacy_state, :used_percent, :reset_at, :unknown_reason])
    |> validate_required([:id, :snapshot_id, :kind, :state, :legacy_state])
    |> validate_inclusion(:state, ["observed", "unknown"])
    |> validate_number(:used_percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_window_state()
    |> foreign_key_constraint(:snapshot_id)
    |> unique_constraint(:kind, name: "harness_capacity_windows_snapshot_id_kind_index")
    |> check_constraint(:state, name: "harness_capacity_windows_state_v2_valid")
    |> check_constraint(:legacy_state, name: "harness_capacity_windows_state_valid")
    |> check_constraint(:used_percent, name: "harness_capacity_windows_used_percent_range")
  end

  defp validate_window_state(changeset) do
    case {get_field(changeset, :state), get_field(changeset, :used_percent),
          get_field(changeset, :unknown_reason)} do
      {"observed", used_percent, nil} when is_number(used_percent) ->
        changeset

      {"observed", _used_percent, _reason} ->
        add_error(changeset, :state, "observed windows require usage and no unknown reason")

      {"unknown", nil, reason} when is_binary(reason) ->
        changeset

      {"unknown", _used_percent, _reason} ->
        add_error(changeset, :state, "unknown windows require a reason and no usage")

      _other ->
        changeset
    end
  end

  @type t :: %__MODULE__{}
end
