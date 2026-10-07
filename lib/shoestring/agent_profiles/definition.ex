defmodule Shoestring.AgentProfiles.Definition do
  use Ecto.Schema
  import Ecto.Changeset
  alias Shoestring.AgentProfiles.Role
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "agent_definitions" do
    field :name, :string
    field :slug, :string
    field :purpose, :string
    field :instructions, :string
    field :revision, :integer, default: 1
    embeds_many :roles, Role, on_replace: :delete
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs, catalog) do
    changeset =
      agent
      |> cast(attrs, [:name, :slug, :purpose, :instructions])
      |> validate_required([:name, :slug, :purpose, :instructions])
      |> validate_length(:name, max: 60)
      |> validate_length(:slug, max: 60)
      |> validate_length(:purpose, max: 180)
      |> validate_length(:instructions, max: 6000)
      |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
        message: "use lowercase letters, numbers and hyphens"
      )
      |> cast_embed(:roles, with: &Role.changeset(&1, &2, catalog))
      |> unique_constraint(:slug)

    roles = get_field(changeset, :roles) || []

    cond do
      length(roles) not in 1..6 ->
        add_error(changeset, :roles, "add a coordinator and up to five team roles")

      hd(roles).name != "Coordinator" ->
        add_error(changeset, :roles, "the first role must be Coordinator")

      length(Enum.uniq_by(roles, & &1.name)) != length(roles) ->
        add_error(changeset, :roles, "use a different name for each role")

      Enum.any?(roles, &(&1.model not in Map.get(catalog, &1.provider, []))) ->
        add_error(changeset, :roles, "choose models from the current provider configuration")

      true ->
        changeset
    end
  end
end
