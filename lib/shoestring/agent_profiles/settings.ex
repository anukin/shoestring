defmodule Shoestring.AgentProfiles.Settings do
  use Ecto.Schema
  import Ecto.Changeset

  schema "agent_settings" do
    field :default_agent_id, :binary_id
    field :refresh_seconds, :integer, default: 60
    field :claude_models, :string, default: "default"
    field :codex_models, :string, default: "default"
    field :opencode_models, :string, default: ""
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  @opencode_model ~r/^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._:\/-]*$/

  def model_ids(value), do: String.split(value || "", ~r/\s+/, trim: true) |> Enum.uniq()

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:default_agent_id, :refresh_seconds])
    |> cast(attrs, [:claude_models, :codex_models, :opencode_models], empty_values: [])
    |> validate_required([:refresh_seconds, :claude_models, :codex_models])
    |> validate_inclusion(:refresh_seconds, [0, 60, 300])
    |> validate_length(:claude_models, max: 2000)
    |> validate_length(:codex_models, max: 2000)
    |> validate_length(:opencode_models, max: 2000)
    |> validate_change(:claude_models, &validate_models/2)
    |> validate_change(:codex_models, &validate_models/2)
    |> validate_change(:opencode_models, &validate_opencode_models/2)
    |> foreign_key_constraint(:default_agent_id)
  end

  # opencode identifiers are `provider/model`, and the list may be empty: an
  # opencode role needs a model the operator named, never a default.
  defp validate_opencode_models(field, value) do
    ids = model_ids(value)

    if length(ids) <= 16 and
         Enum.all?(ids, &(String.length(&1) <= 120 and Regex.match?(@opencode_model, &1))),
       do: [],
       else: [{field, "enter up to 16 provider/model identifiers, separated by whitespace"}]
  end

  defp validate_models(field, value) do
    ids = model_ids(value)

    if length(ids) in 1..16 and
         Enum.all?(
           ids,
           &(String.length(&1) <= 120 and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:\/-]*$/, &1))
         ), do: [], else: [{field, "enter 1–16 model identifiers, separated by whitespace"}]
  end
end
