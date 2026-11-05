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

  `read_paths`, `write_paths` and `network_hosts` are what the person lets an
  implementer do beyond its sandbox (`Shoestring.Agents.Permissions`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Shoestring.{AgentProfiles, Harnesses, ModelCatalog}

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
    # What the person added beyond the sandbox (`Shoestring.Agents.Permissions`).
    field :read_paths, {:array, :string}, default: []
    field :write_paths, {:array, :string}, default: []
    field :network_hosts, {:array, :string}, default: []
    # Whether its worker may ask the person, mid-run, for more.
    field :may_ask, :boolean, default: true
    # Exact commands its workers may run outside the sandbox without asking
    # again ("allow for this agent", `Shoestring.Agents.Permissions`).
    field :allowed_commands, {:array, :string}, default: []
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs, catalog) do
    changeset =
      agent
      |> cast(
        Shoestring.Agents.Permissions.normalize(attrs),
        [
          :name,
          :slug,
          :kind,
          :provider,
          :model,
          :effort,
          :notes,
          :max_minutes,
          :may_propose_lessons,
          :read_paths,
          :write_paths,
          :network_hosts,
          :may_ask,
          :allowed_commands
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
      |> Shoestring.Agents.Permissions.validate()

    kind = get_field(changeset, :kind)
    provider = get_field(changeset, :provider)
    model = get_field(changeset, :model)

    changeset
    |> validate_inclusion(:effort, AgentProfiles.efforts(provider, model),
      message: "choose an effort this model accepts"
    )
    |> then(fn changeset ->
      cond do
        (changed?(changeset, :provider) or changed?(changeset, :model)) and
            match?(%{available: false}, ModelCatalog.entry(provider, model)) ->
          add_error(
            changeset,
            :model,
            "this model is no longer reported; refresh or choose another model"
          )

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
