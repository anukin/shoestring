defmodule Shoestring.Cobbler.PlannerRequestRecord do
  @moduledoc """
  Durable row for one bounded planner request.

  The row is the idempotency token and the attempt budget. It is claimed
  (`in_progress`) before any planner invocation, every invocation increments
  `attempts_used`, and the check constraint caps invocations at two for the
  life of the row. Terminal rows (`proposed`, `manual_required`, `failed`,
  `cancelled`) never move again; only `in_progress` rows settle, which is
  what makes retry, replay, and restart converge instead of duplicating
  invocations or resetting the budget.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(in_progress proposed manual_required failed cancelled)
  @terminal_statuses ~w(proposed manual_required failed cancelled)

  schema "cobbler_planner_requests" do
    field :request_id, :string
    field :requested_by, :string
    field :status, :string
    field :attempts_used, :integer, default: 0
    field :max_attempts, :integer, default: 2
    field :planner_identity, :string
    field :planner_version, :string
    field :planner_model, :string
    field :input_digest, :string
    field :goal_statement, :string
    field :base_revision, :string
    field :source_context_refs, :map, default: %{}
    field :proposal_id, :string
    field :revision_number, :integer
    field :plan_digest, :string
    field :error_kind, :string
    field :error_detail, :map
    field :admission_decision_ids, :map, default: %{}

    belongs_to :goal, Shoestring.Trajectory.Goal

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The statuses a settled request may carry."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @doc "True when the row has settled and must never move again."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  @doc "Builds the single insert that claims a request before any invocation."
  @spec claim_changeset(Ecto.UUID.t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def claim_changeset(goal_id, attrs, now) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :request_id,
      :requested_by,
      :planner_identity,
      :planner_version,
      :planner_model,
      :input_digest,
      :goal_statement,
      :base_revision,
      :source_context_refs,
      :proposal_id
    ])
    |> put_change(:goal_id, goal_id)
    |> put_change(:status, "in_progress")
    |> put_change(:attempts_used, 0)
    |> put_change(:max_attempts, 2)
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
    |> validate_required([
      :request_id,
      :requested_by,
      :planner_identity,
      :planner_version,
      :planner_model,
      :input_digest,
      :goal_statement,
      :base_revision,
      :proposal_id
    ])
    |> foreign_key_constraint(:goal_id)
    |> unique_constraint(:request_id,
      name: "cobbler_planner_requests_goal_id_request_id_index"
    )
    |> check_constraint(:status, name: "cobbler_planner_requests_status_valid")
    |> check_constraint(:attempts_used,
      name: "cobbler_planner_requests_attempts_used_bounded"
    )
  end

  @doc """
  Records one admitted invocation against the budget.

  Only an `in_progress` row with remaining budget may consume an attempt;
  anything else is a programming error and fails the changeset rather than
  silently spending quota that no longer exists.
  """
  @spec consume_attempt_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def consume_attempt_changeset(%__MODULE__{} = record, now) do
    record
    |> cast(%{}, [])
    |> put_change(:attempts_used, record.attempts_used + 1)
    |> put_change(:updated_at, now)
    |> validate_attempt_available()
    |> check_constraint(:attempts_used,
      name: "cobbler_planner_requests_attempts_used_bounded"
    )
  end

  @doc """
  Settles an `in_progress` row into its terminal state.

  `attrs` carries the terminal `status` plus the settlement fields for that
  status: `proposal_id`/`revision_number`/`plan_digest` for `proposed`, or
  `error_kind`/`error_detail` otherwise. Settling a row that already settled
  is refused: terminal rows never move.
  """
  @spec settle_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def settle_changeset(%__MODULE__{} = record, attrs, now) when is_map(attrs) do
    record
    |> cast(attrs, [
      :status,
      :proposal_id,
      :revision_number,
      :plan_digest,
      :error_kind,
      :error_detail,
      :admission_decision_ids
    ])
    |> put_change(:updated_at, now)
    |> validate_inclusion(:status, @statuses)
    |> validate_terminal_settlement()
  end

  defp validate_attempt_available(changeset) do
    record = changeset.data

    cond do
      terminal?(record) ->
        add_error(changeset, :status, "is already settled")

      record.attempts_used >= record.max_attempts ->
        add_error(changeset, :attempts_used, "has no remaining attempts")

      true ->
        changeset
    end
  end

  defp validate_terminal_settlement(changeset) do
    record = changeset.data

    if terminal?(record) do
      add_error(changeset, :status, "is already settled")
    else
      changeset
    end
  end
end
