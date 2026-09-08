defmodule Shoestring.Cobbler.Command do
  @moduledoc """
  Pure command model, digest, and state machine for durable Cobbler commands.

  A command is a caller-supplied, goal-scoped durable intent. Re-submitting
  the same command id with an identical digest replays the originally
  recorded result; the same command id with a different digest is rejected as
  a conflict. Commands never execute anything: they record validated intent,
  transition, and result. Execution remains disabled in this slice and no
  code path in this module spawns, enqueues, or dispatches anything.

  Command lifecycle states:

  - `:pending` - transient only. A persisted command row always carries its
    transition and result together, so a bare pending intent is never
    written.
  - `:needs_user` - recoverable. The command recorded why a decision is
    required and which response options exist; a validated response resolves
    it. Pending commands are inert: nothing consumes them automatically.
  - `:resolved` - terminal. The command recorded its outcome.
  - `:rejected` - terminal. The command was invalid or contradicted durable
    state; it cannot be retried under the same command id.

  Legal transitions (invalid ones are always rejected, never coerced):

      pending    -> needs_user | resolved | rejected   (on accept)
      needs_user -> resolved | rejected                (on respond)
      resolved | rejected -> nothing                    (terminal)

  Direct run paths (Elves, harness adapters, dispatch) are not routed through
  commands and gain no protection from this module.
  """

  alias Shoestring.Harness.Contract

  @version 1
  @types ["task.claim", "task.release"]
  @statuses [:pending, :needs_user, :resolved, :rejected]

  @enforce_keys [:version, :command_id, :type, :payload, :digest]
  defstruct [:version, :command_id, :type, :payload, :digest]

  @type t :: %__MODULE__{
          version: 1,
          command_id: String.t(),
          type: String.t(),
          payload: map(),
          digest: String.t()
        }

  @spec version() :: 1
  def version, do: @version

  @spec types() :: [String.t()]
  def types, do: @types

  @spec statuses() :: [:pending | :needs_user | :resolved | :rejected]
  def statuses, do: @statuses

  @doc "Validates and constructs a command, normalizing the payload per type."
  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, version} <-
           validate_version(Map.get(attrs, :version, Map.get(attrs, "version", @version))),
         {:ok, command_id} <- command_id(attrs),
         {:ok, type} <- Contract.enum(Contract.fetch(attrs, :type), :type, @types),
         {:ok, payload} <- normalize_payload(raw_payload(attrs), type) do
      {:ok,
       %__MODULE__{
         version: version,
         command_id: command_id,
         type: type,
         payload: payload,
         digest: digest(type, payload)
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:base, "must be an object")

  @doc "Digests a command type and payload deterministically for replay comparison."
  @spec digest(String.t(), map()) :: String.t()
  def digest(type, payload) when is_binary(type) and is_map(payload) do
    encoded =
      Jason.encode!(%{
        "type" => type,
        "payload" => canonicalize(payload)
      })

    :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  end

  @doc "Digests a response payload deterministically for respond replay comparison."
  @spec response_digest(map()) :: String.t()
  def response_digest(response) when is_map(response) do
    :crypto.hash(:sha256, Jason.encode!(canonicalize(response)))
    |> Base.encode16(case: :lower)
  end

  @doc "Validates a lifecycle transition against the legal transition table."
  @spec transition(atom() | String.t(), :accept | :respond, atom() | String.t()) ::
          :ok | {:error, {:invalid_transition, atom(), atom()}}
  def transition(from, action, to)

  def transition(from, action, to)
      when is_atom(from) and is_atom(to) and action in [:accept, :respond] do
    if legal?(from, action, to) do
      :ok
    else
      {:error, {:invalid_transition, from, to}}
    end
  end

  def transition(from, action, to)
      when is_binary(from) and is_binary(to) and action in [:accept, :respond] do
    transition(String.to_existing_atom(from), action, String.to_existing_atom(to))
  end

  def transition(from, _action, to),
    do: {:error, {:invalid_transition, status_atom(from), status_atom(to)}}

  @doc "Returns true only for terminal command states."
  @spec terminal?(atom() | String.t()) :: boolean()
  def terminal?(status) when status in [:resolved, :rejected], do: true
  def terminal?(status) when is_binary(status), do: terminal?(status_atom(status))
  def terminal?(_status), do: false

  @doc "Maps a persisted status string to its atom, or nil for unknown values."
  @spec status_atom(term()) :: atom() | nil
  def status_atom(status) when status in ["pending", "needs_user", "resolved", "rejected"],
    do: String.to_existing_atom(status)

  def status_atom(status) when status in @statuses, do: status
  def status_atom(_status), do: nil

  @doc "Maps a status atom to its persisted string."
  @spec status_string(atom()) :: String.t() | nil
  def status_string(status) when status in @statuses, do: Atom.to_string(status)
  def status_string(_status), do: nil

  @doc """
  Returns the response options a `needs_user` command offers for its reason,
  or an empty list when the reason offers no recoverable response.
  """
  @spec response_options(String.t()) :: [String.t()]
  def response_options("claim_held"), do: ["abandon"]
  def response_options(_reason), do: []

  @doc """
  Maps a validated response option for a reason to the resolved result kind,
  or an error when the option is not offered.
  """
  @spec resolution(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_response}
  def resolution("claim_held", "abandon"), do: {:ok, "abandoned"}
  def resolution(_reason, _option), do: {:error, :invalid_response}

  # ----------------------------------------------------------------------------
  # Validation
  # ----------------------------------------------------------------------------

  defp validate_version(1), do: {:ok, 1}
  defp validate_version(_), do: Contract.invalid(:version, "must equal #{@version}")

  defp command_id(attrs) do
    case Contract.fetch(attrs, :command_id) do
      {:ok, nil} -> generated_command_id()
      :error -> generated_command_id()
      {:ok, value} when is_binary(value) -> normalize_command_id(value)
      {:ok, _other} -> Contract.invalid(:command_id, "must be a string")
    end
  end

  defp generated_command_id, do: {:ok, "cmd-" <> Ecto.UUID.generate()}

  defp normalize_command_id(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        Contract.invalid(:command_id, "can't be blank")

      String.length(trimmed) > 200 ->
        Contract.invalid(:command_id, "must be at most 200 characters")

      true ->
        {:ok, trimmed}
    end
  end

  defp raw_payload(attrs) do
    case Contract.fetch(attrs, :payload) do
      {:ok, payload} when is_map(payload) -> payload
      _other -> %{}
    end
  end

  defp normalize_payload(raw, "task.claim") do
    with {:ok, intent} <- text_field(raw, :intent, max: 200),
         {:ok, scope} <- text_field(raw, :scope, max: 200),
         {:ok, candidate} <- candidate_field(raw),
         {:ok, admission_event_id} <- admission_event_id_field(raw) do
      {:ok,
       %{
         "intent" => intent,
         "scope" => scope,
         "candidate" => candidate,
         "admission_event_id" => admission_event_id
       }}
    end
  end

  defp normalize_payload(raw, "task.release") do
    with {:ok, reason} <- text_field(raw, :reason, max: 500) do
      {:ok, %{"reason" => reason}}
    end
  end

  defp normalize_payload(_raw, _type),
    do: Contract.invalid(:payload, "must match the command type")

  defp text_field(raw, key, opts) do
    case Contract.fetch(raw, key) do
      {:ok, value} when not is_nil(value) -> Contract.text(value, key, opts)
      {:ok, nil} -> Contract.invalid(key, "can't be blank")
      :error -> Contract.invalid(key, "can't be blank")
    end
  end

  defp candidate_field(raw) do
    case Contract.fetch(raw, :candidate) do
      {:ok, candidate} when is_map(candidate) ->
        with {:ok, provider_id} <- text_field(candidate, :provider_id, max: 200),
             {:ok, adapter_id} <- text_field(candidate, :adapter_id, max: 200) do
          {:ok, %{"provider_id" => provider_id, "adapter_id" => adapter_id}}
        end

      {:ok, _other} ->
        Contract.invalid(:candidate, "must be an object")

      :error ->
        Contract.invalid(:candidate, "can't be blank")
    end
  end

  defp admission_event_id_field(raw) do
    case Contract.fetch(raw, :admission_event_id) do
      {:ok, value} ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> Contract.invalid(:admission_event_id, "must be a UUID")
        end

      :error ->
        Contract.invalid(:admission_event_id, "can't be blank")
    end
  end

  # ----------------------------------------------------------------------------
  # Canonicalization
  # ----------------------------------------------------------------------------

  defp canonicalize(value) when is_map(value) do
    value
    |> Map.new(fn {key, nested} -> {to_string(key), canonicalize(nested)} end)
    |> Enum.sort(fn {left, _}, {right, _} -> left <= right end)
    |> Enum.map(fn {key, nested} -> [key, nested] end)
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value

  # ----------------------------------------------------------------------------
  # Transition table
  # ----------------------------------------------------------------------------

  defp legal?(:pending, :accept, to), do: to in [:needs_user, :resolved, :rejected]
  defp legal?(:needs_user, :respond, to), do: to in [:resolved, :rejected]
  defp legal?(_from, _action, _to), do: false
end
