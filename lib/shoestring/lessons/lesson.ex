defmodule Shoestring.Lessons.Lesson do
  @moduledoc """
  One lesson (iteration 16 B): a short rule for one repository, where it came
  from, who proposed it and who decided. `state`: `proposed`, `approved`,
  `rejected` or `retired`.

  This struct is the value every lesson store returns
  (`Shoestring.Lessons.Store`); it is also the default store's schema.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "lessons" do
    field :code, :string
    field :repository_root, :string
    field :text, :string
    field :state, :string
    # `dispatch` (a dispatch of the proposing session) or `person` (the
    # person's own words in that session's chat, quoted in `source_quote`).
    field :source_kind, :string
    field :source_ref, :string
    field :source_quote, :string
    field :why, :string
    field :session_id, :string
    field :proposed_by, :string
    field :proposer_role, :string
    field :proposer_agent, :string
    field :origin_key, :string
    # Codes of lessons of the same repository with much the same words.
    field :similar_to, {:array, :string}, default: []
    field :decided_by, :string
    field :decided_at, :utc_datetime_usec
    field :decision_note, :string
    field :retired_by, :string
    field :retired_at, :utc_datetime_usec
    field :cite_count, :integer, default: 0
    field :last_cited_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
