defmodule Shoestring.AgentProfiles.Role do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field :name, :string
    field :provider, :string
    field :model, :string
    field :effort, :string
    # The agent that fills the role (`Shoestring.Agents`); its model and
    # effort are the role's. `agent_kind` is that agent's job, for the check.
    field :agent_id, :binary_id
    field :agent_kind, :string, virtual: true
  end

  def changeset(role, attrs, catalog) do
    changeset =
      role
      |> cast(attrs, [:name, :provider, :model, :effort, :agent_id, :agent_kind],
        empty_values: [""]
      )
      |> validate_required([:name, :provider, :model])
      |> validate_length(:name, max: 50)
      |> validate_agent()

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

  # A role named for a job takes an agent of that job.
  defp validate_agent(changeset) do
    name = get_field(changeset, :name)
    kind = get_field(changeset, :agent_kind)

    cond do
      not is_nil(get_field(changeset, :agent_id)) and is_nil(kind) ->
        add_error(changeset, :agent_id, "choose an existing agent")

      not is_nil(kind) and name in ~w(Coordinator Explorer Worker Implementer Reviewer) and
          Shoestring.Agents.kind_of(name) != kind ->
        add_error(
          changeset,
          :agent_id,
          "choose #{article(Shoestring.Agents.kind_of(name))} " <>
            "#{Shoestring.Agents.label(Shoestring.Agents.kind_of(name))} agent"
        )

      true ->
        changeset
    end
  end

  defp article("explorer"), do: "an"
  defp article("implementer"), do: "an"
  defp article(_kind), do: "a"
end
