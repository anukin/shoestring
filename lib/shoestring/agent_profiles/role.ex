defmodule Shoestring.AgentProfiles.Role do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field :name, :string
    field :provider, :string
    field :model, :string
    field :effort, :string
  end

  def changeset(role, attrs, catalog) do
    changeset =
      role
      |> cast(attrs, [:name, :provider, :model, :effort], empty_values: [""])
      |> validate_required([:name, :provider, :model])
      |> validate_length(:name, max: 50)

    provider = get_field(changeset, :provider)
    model = get_field(changeset, :model)

    changeset =
      changeset
      |> validate_inclusion(:provider, Map.keys(catalog))
      |> validate_inclusion(:effort, Shoestring.AgentProfiles.efforts(provider, model),
        message: "choose an effort this model accepts"
      )

    if model in Map.get(catalog, provider, []),
      do: changeset,
      else: add_error(changeset, :model, "choose a model configured for this provider")
  end
end
