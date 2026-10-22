defmodule Shoestring.Harness.HTTP.Call do
  @moduledoc "Durable once-only inference claim. Restart never grants a replacement call."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "http_call_claims" do
    field :run_id, :binary_id
    field :provider, :string
    field :status, :string
  end
end
