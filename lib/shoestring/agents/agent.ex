defmodule Shoestring.Agents.Agent do
  @moduledoc """
  One reusable agent (iteration 16 package T): a job (`kind`), the model that
  does it and how long one job may take. Teams (`Shoestring.AgentProfiles`)
  compose agents by naming them in their roles.

  `max_minutes` is the most one dispatch of this agent may take; nil is no
  limit of its own (the session's grant still bounds every dispatch). A
  coordinator has none: its limit is the grant's turns.

  `may_propose_lessons` says whether it may propose lessons for the
  repositories it works in (`Shoestring.Lessons`); by default every job but
  the explorer may.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Shoestring.{AgentProfiles, Harnesses}

  @kinds ~w(coordinator explorer implementer reviewer)
  @capability %{
    "coordinator" => :coordinate,
    "explorer" => :explore,
    "implementer" => :implement,
    "reviewer" => :review
  }
  @verbs %{coordinate: "coordinate", explore: "explore", implement: "run tasks", review: "review"}

  def kinds, do: @kinds
  def capability(kind), do: Map.fetch!(@capability, kind)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "agents" do
    field :name, :string
    field :slug, :string
    field :kind, :string
    field :provider, :string
    field :model, :string
    field :effort, :string
    field :notes, :string
    field :max_minutes, :integer
    field :may_propose_lessons, :boolean
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs, catalog) do
    changeset =
      agent
      |> cast(
        attrs,
        [
          :name,
          :slug,
          :kind,
          :provider,
          :model,
          :effort,
          :notes,
          :max_minutes,
          :may_propose_lessons
        ],
        empty_values: [""]
      )
      |> then(fn changeset ->
        if is_nil(get_field(changeset, :may_propose_lessons)),
          do:
            put_change(changeset, :may_propose_lessons, get_field(changeset, :kind) != "explorer"),
          else: changeset
      end)
      |> validate_required([:name, :slug, :kind, :provider, :model])
      |> validate_length(:name, max: 60)
      |> validate_length(:slug, max: 60)
      |> validate_length(:notes, max: 2000)
      |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
        message: "use lowercase letters, numbers and hyphens"
      )
      |> validate_inclusion(:kind, @kinds)
      |> validate_inclusion(:provider, Map.keys(catalog))
      |> validate_number(:max_minutes, greater_than_or_equal_to: 1, less_than_or_equal_to: 240)
      |> unique_constraint(:slug)

    kind = get_field(changeset, :kind)
    provider = get_field(changeset, :provider)
    model = get_field(changeset, :model)

    changeset
    |> validate_inclusion(:effort, AgentProfiles.efforts(provider, model),
      message: "choose an effort this model accepts"
    )
    |> then(fn changeset ->
      cond do
        provider in Map.keys(catalog) and model not in Map.get(catalog, provider, []) ->
          add_error(changeset, :model, "choose a model configured for this provider")

        kind == "coordinator" and get_field(changeset, :max_minutes) ->
          add_error(changeset, :max_minutes, "a coordinator's limit is the grant's turns")

        kind in @kinds and provider in Harnesses.ids() and
            not Harnesses.supports?(provider, capability(kind)) ->
          add_error(
            changeset,
            :provider,
            "#{Harnesses.name(provider)} cannot #{@verbs[capability(kind)]} yet; use " <>
              Harnesses.offering(capability(kind))
          )

        true ->
          changeset
      end
    end)
  end
end
