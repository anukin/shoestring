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

  # Harnesses report more models than people used to type: Claude Code lists
  # 13 and opencode 150 (2026-10-25), so a list holds up to 64.
  @max_models 64
  @max_length 8000

  def model_ids(value), do: String.split(value || "", ~r/\s+/, trim: true) |> Enum.uniq()

  @doc "Whether `model` is an identifier a `provider` list can hold."
  def valid_model?("opencode", model),
    do:
      String.length(model) <= 120 and
        Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._:\/-]*$/, model)

  def valid_model?(_provider, model),
    do: String.length(model) <= 120 and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:\/-]*$/, model)

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:default_agent_id, :refresh_seconds])
    |> cast(attrs, [:claude_models, :codex_models, :opencode_models], empty_values: [])
    |> validate_required([:refresh_seconds, :claude_models, :codex_models])
    |> validate_inclusion(:refresh_seconds, [0, 60, 300])
    |> validate_length(:claude_models, max: @max_length)
    |> validate_length(:codex_models, max: @max_length)
    |> validate_length(:opencode_models, max: @max_length)
    |> validate_change(:claude_models, &validate_models/2)
    |> validate_change(:codex_models, &validate_models/2)
    |> validate_change(:opencode_models, &validate_opencode_models/2)
    |> foreign_key_constraint(:default_agent_id)
  end

  # opencode identifiers are `provider/model`, and the list may be empty: an
  # opencode role needs a model the operator named, never a default.
  defp validate_opencode_models(field, value) do
    ids = model_ids(value)

    if length(ids) <= @max_models and Enum.all?(ids, &valid_model?("opencode", &1)),
      do: [],
      else: [
        {field, "enter up to #{@max_models} provider/model identifiers, separated by whitespace"}
      ]
  end

  defp validate_models(field, value) do
    ids = model_ids(value)

    if length(ids) in 1..@max_models and Enum.all?(ids, &valid_model?("claude", &1)),
      do: [],
      else: [{field, "enter 1–#{@max_models} model identifiers, separated by whitespace"}]
  end
end
