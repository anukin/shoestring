defmodule Shoestring.AgentProfiles.Revision do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "agent_revisions" do
    field :definition_id, :binary_id
    field :number, :integer
    field :configuration, :map
    field :digest, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
