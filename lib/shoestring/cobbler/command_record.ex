defmodule Shoestring.Cobbler.CommandRecord do
  @moduledoc """
  Durable row for one goal-scoped Cobbler command.

  The intent (`command_id`, `type`, `payload`, `digest`), the validated state
  transition (`status`), and the recorded `result` are written in a single
  transaction together with the canonical trajectory event, so a persisted
  row always represents a complete command outcome. `status` is never
  `pending` in storage: the pending state is transient and a bare intent
  without a result cannot be persisted.

  Replay semantics are enforced by the `(goal_id, command_id)` unique index
  plus the stored `digest`: an identical re-submission returns the original
  result without appending events, and a conflicting re-submission is
  rejected. This slice is record-only — commands do not execute, spawn, or
  enqueue anything.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cobbler_commands" do
    field :command_id, :string
    field :version, :integer, default: 1
    field :type, :string
    field :payload, :map
    field :digest, :string
    field :status, :string
    field :result, :map
    field :response, :map
    field :response_digest, :string
    # Strict response attribution (nullable per P3: pre-migration rows stay
    # nil and still rebuild). New responses persist the validated
    # confirmed_by identity (+ the confirmed intent where carried) here and
    # inside the digest-covered response map.
    field :confirmed_by, :string
    field :confirmed_intent, :string

    belongs_to :goal, Shoestring.Trajectory.Goal

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds the single, complete record for an accepted command outcome."
  @spec outcome_changeset(
          t() | Ecto.Changeset.t(),
          Ecto.UUID.t(),
          Shoestring.Cobbler.Command.t(),
          String.t(),
          map(),
          DateTime.t()
        ) ::
          Ecto.Changeset.t()
  def outcome_changeset(
        record,
        goal_id,
        %Shoestring.Cobbler.Command{} = command,
        status,
        result,
        now
      ) do
    record
    |> cast(%{}, [])
    |> put_change(:goal_id, goal_id)
    |> put_change(:command_id, command.command_id)
    |> put_change(:version, command.version)
    |> put_change(:type, command.type)
    |> put_change(:payload, command.payload)
    |> put_change(:digest, command.digest)
    |> put_change(:status, status)
    |> put_change(:result, result)
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
    |> foreign_key_constraint(:goal_id)
    |> unique_constraint(:command_id, name: "cobbler_commands_goal_id_command_id_index")
    |> check_constraint(:status, name: "cobbler_commands_status_valid")
    |> check_constraint(:type, name: "cobbler_commands_type_valid")
    |> check_constraint(:version, name: "cobbler_commands_version_positive")
  end

  @doc "Applies a validated user response that resolves a needs_user command."
  @spec response_changeset(t(), map(), String.t(), String.t(), map(), DateTime.t(), map()) ::
          Ecto.Changeset.t()
  def response_changeset(
        %__MODULE__{} = record,
        response,
        response_digest,
        status,
        result,
        now,
        attribution \\ %{}
      ) do
    record
    |> cast(%{}, [])
    |> put_change(:response, response)
    |> put_change(:response_digest, response_digest)
    |> put_change(:status, status)
    |> put_change(:result, result)
    |> put_change(:confirmed_by, attribution_value(attribution, response, :confirmed_by))
    |> put_change(:confirmed_intent, attribution_value(attribution, response, :confirmed_intent))
    |> put_change(:updated_at, now)
    |> foreign_key_constraint(:goal_id)
    |> check_constraint(:status, name: "cobbler_commands_status_valid")
    |> check_constraint(:response_digest, name: "cobbler_commands_response_digest_pair")
  end

  # Attribution is validated fail-closed in Commands.respond/4 before any
  # write; the changeset only persists it. Prefer the explicit attribution
  # map, falling back to the digest-covered response map so legacy callers
  # that embed attribution in the response still persist it.
  defp attribution_value(attribution, response, :confirmed_by) do
    fetch_attribution(attribution, response, [:confirmed_by, "confirmed_by"])
  end

  defp attribution_value(attribution, response, :confirmed_intent) do
    fetch_attribution(attribution, response, [
      :confirmed_intent,
      "confirmed_intent",
      :intent,
      "intent"
    ])
  end

  defp fetch_attribution(attribution, response, keys) do
    Enum.find_value(keys, fn key ->
      case attribution do
        %{^key => value} when is_binary(value) -> value
        _ -> nil
      end
    end) ||
      Enum.find_value(keys, fn key ->
        case response do
          %{^key => value} when is_binary(value) -> value
          _ -> nil
        end
      end)
  end

  @type t :: %__MODULE__{}
end
