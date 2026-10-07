defmodule Shoestring.AgentProfiles.Role do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field :name, :string
    field :provider, :string
    field :model, :string
  end

  def changeset(role, attrs, catalog) do
    changeset =
      role
      |> cast(attrs, [:name, :provider, :model])
      |> validate_required([:name, :provider, :model])
      |> validate_length(:name, max: 50)

    provider = get_field(changeset, :provider)
    model = get_field(changeset, :model)
    changeset = validate_inclusion(changeset, :provider, Map.keys(catalog))

    if model in Map.get(catalog, provider, []),
      do: changeset,
      else: add_error(changeset, :model, "choose a model configured for this provider")
  end
end
