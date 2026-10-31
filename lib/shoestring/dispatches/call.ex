defmodule Shoestring.Dispatches.Call do
  @moduledoc """
  The one model call of an EXPLORE or REVIEW dispatch (`Shoestring.Dispatches.Calls`):
  its state, the admission decision and confirmation that let it run, its
  immutable input and its validated result.

  States: `pending` (waits for admission), `held` (its provider's remaining
  usage could not be confirmed), `waiting` (deferred until `defer_until`),
  `running`, `completed`, `failed` (`error_code` says why) and `cancelled`.
  """
  use Ecto.Schema

  @states ~w(pending held waiting running completed failed cancelled)

  def states, do: @states

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "coordinator_dispatch_calls" do
    field :dispatch_id, :binary_id
    field :target_dispatch_id, :binary_id
    field :state, :string
    field :admission, :map
    field :defer_until, :utc_datetime_usec
    field :confirmed_by, :string
    field :confirmed_at, :utc_datetime_usec
    field :input_json, :string
    field :input_digest, :string
    field :workdir, :string
    field :report_json, :string
    field :report_digest, :string
    field :error_code, :string
    field :output_tokens, :integer
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    # An EXPLORE's last steps while it ran: %{"steps" => [%{"at", "line"}], "total" => n}.
    field :progress, :map
    timestamps(type: :utc_datetime_usec)
  end
end
