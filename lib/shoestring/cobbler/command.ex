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

  ## `run.handoff`

  `run.handoff` is the explicit production intent to transfer a run to a
  different provider at a NAMED checkpoint boundary. The command records
  intent only — it observes no capacity, evaluates no admission, grants no
  lease and dispatches nothing. `Shoestring.Cobbler.Handoffs.perform/3` is
  the separate, gated executor; the command row that this module persists
  is the durable intent it replays against, which is what makes a handoff
  retry converge instead of transferring twice.

  The payload names the sender run, the checkpoint boundary the operator is
  transferring at, the decision refs the transfer was authorized against,
  the receiver provider/adapter, a reason, and the attributable
  `requested_by` identity (never silently defaulted — an
  automated caller passes an explicit `system:`-prefixed identity, matching
  the `respond/4` attribution rule).

  It may also carry an optional `confirmation` object — the operator's
  attributable single-decision answer to a confirmation-class admission
  refusal for the named receiver. It is validated here against this same
  payload's receiver and scope, digest-covered like every other field, and
  authorizes nothing by itself: `Shoestring.Cobbler.AdmissionEvaluation`
  re-validates it and can only lift a confirmation-class refusal, never a
  hard stop.

  It may also carry an optional `lease_policy` object — the bounds the
  RECEIVER's own execution lease is proposed under. Absent, the transfer uses
  `Shoestring.Cobbler.HandoffLeasePolicy.default/0`, whose deadline is 2700
  seconds rather than the wake-shaped 300. Present, every field is
  allow-listed and range-bounded there, and an unknown or out-of-range field
  rejects the command instead of being dropped. Like `confirmation` it is
  digest-covered and authorizes nothing: it proposes lease bounds, and
  admission still decides.
  """

  alias Shoestring.Cobbler.HandoffLeasePolicy
  alias Shoestring.Harness.Contract

  @version 1
  @types ["task.claim", "task.release", "run.handoff"]
  @statuses [:pending, :needs_user, :resolved, :rejected]

  # Read from `Shoestring.Harness.Continuation` at compile time rather than
  # restated, so the authorized ref set and what projection can produce
  # cannot drift apart.
  @max_decision_refs Shoestring.Harness.Continuation.max_decision_refs()

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

  defp normalize_payload(raw, "run.handoff") do
    with {:ok, run_id} <- uuid_field(raw, :run_id),
         {:ok, checkpoint_id} <- uuid_field(raw, :checkpoint_id),
         {:ok, decision_refs} <- decision_refs_field(raw),
         {:ok, to_provider_id} <- text_field(raw, :to_provider_id, max: 200),
         {:ok, to_adapter_id} <- text_field(raw, :to_adapter_id, max: 200),
         {:ok, scope} <- text_field(raw, :scope, max: 200),
         {:ok, reason} <- text_field(raw, :reason, max: 500),
         {:ok, requested_by} <- text_field(raw, :requested_by, max: 200),
         {:ok, confirmation} <- confirmation_field(raw),
         {:ok, lease_policy} <- lease_policy_field(raw) do
      payload = %{
        "run_id" => run_id,
        "checkpoint_id" => checkpoint_id,
        "decision_refs" => decision_refs,
        "to_provider_id" => to_provider_id,
        "to_adapter_id" => to_adapter_id,
        "scope" => scope,
        "reason" => reason,
        "requested_by" => requested_by
      }

      # Absent stays absent, for both optional objects: an intent carrying
      # neither keeps exactly the payload shape — and therefore exactly the
      # digest — it had before these fields existed, so an already-submitted
      # command id still replays.
      {:ok,
       payload
       |> put_optional("confirmation", confirmation)
       |> put_optional("lease_policy", lease_policy)}
    end
  end

  defp normalize_payload(raw, "task.release") do
    with {:ok, reason} <- text_field(raw, :reason, max: 500) do
      {:ok, %{"reason" => reason}}
    end
  end

  defp normalize_payload(_raw, _type),
    do: Contract.invalid(:payload, "must match the command type")

  defp put_optional(payload, _key, nil), do: payload
  defp put_optional(payload, key, value), do: Map.put(payload, key, value)

  # The operator's single-decision confirmation, frozen into the durable
  # handoff intent alongside the boundary and the authorized refs.
  #
  # It exists because a receiver whose measured capacity is anything less than
  # automatically safe produces a confirmation-class admission refusal, and
  # `Shoestring.Cobbler.HandoffWorker` — the only production consumer of a
  # handoff intent — has no channel of its own for an operator answer. Without
  # this field, such a transfer is unreachable in production no matter what
  # the operator decides.
  #
  # ## The caller says THAT it confirms, never WHO confirms
  #
  # The payload carries one field, `intent`, and nothing else. `confirmed_by`
  # is deliberately NOT accepted here: a string in a request body is an
  # assertion by the requester, not an authenticated identity, and admission
  # treats `confirmed_by` as attribution that can lift a refusal. Accepting it
  # would let any caller mint an operator — or a `system:` principal — for
  # itself.
  #
  # The attribution is bound in `Shoestring.Cobbler.Commands` from the goal's
  # durable `owner_id`, which `Shoestring.Trajectory.Goal` documents as
  # "supplied by the authenticated application boundary and … not accepted
  # from ordinary user attribute maps". That is the strongest trusted
  # authorization context this application has; it has no accounts domain and
  # no per-request authenticated principal, and a goal with no owner is
  # refused rather than attributed to nobody. The honest limit is recorded in
  # `plans/evidence/05-quota-aware-mvp/live-cross-provider-handoff.md`: this
  # binds to the goal's owner, not to the individual who pressed the button.
  #
  # `target_provider_id` / `target_scope` are likewise not accepted; they are
  # derived from this same payload's receiver and scope, so a confirmation
  # cannot be written to authorize anything other than the transfer it rides
  # on.
  #
  # Fail-closed at request time, so an operator learns immediately rather than
  # at delivery: a non-object, an unknown key, a non-string `intent`, an
  # overlong `intent`, or an `intent` outside the capability vocabulary is a
  # rejected command, not a silently ignored field.
  #
  # It authorizes nothing by itself. `Shoestring.Cobbler.AdmissionEvaluation`
  # re-validates it and can only lift a confirmation-class refusal with it —
  # every hard stop (unsupported capability, incompatible CLI, unsupported
  # tier, scope mismatch, snapshot provider mismatch, active occupancy, hard
  # quota refusal, reserve breach) stays a hard stop.
  @confirmation_keys ~w(intent)

  # The capability vocabulary admission evaluates against
  # (`AdmissionPolicy.supported_capabilities`). An allow-list, so a
  # confirmation can never name a capability the policy does not know.
  @confirmation_intents ~w(supervised_execution read_only)

  @doc "Intents a `run.handoff` confirmation may name."
  @spec confirmation_intents() :: [String.t()]
  def confirmation_intents, do: @confirmation_intents

  defp confirmation_field(raw) do
    case Contract.fetch(raw, :confirmation) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, confirmation} when is_map(confirmation) ->
        normalize_confirmation(confirmation)

      {:ok, _other} ->
        Contract.invalid(:confirmation, "must be an object")
    end
  end

  defp normalize_confirmation(confirmation) do
    with :ok <- reject_unknown_confirmation_keys(confirmation),
         {:ok, intent} <- confirmation_intent(confirmation) do
      {:ok, %{"intent" => intent}}
    end
  end

  # Unknown keys are refused rather than dropped. Dropping is what made the
  # pre-fix behaviour dangerous: the field was accepted and then ignored, so
  # a caller writing `confirmed_by` had no way to learn it carried no weight.
  defp reject_unknown_confirmation_keys(confirmation) do
    unknown =
      confirmation
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in @confirmation_keys))
      |> Enum.sort()

    case unknown do
      [] ->
        :ok

      keys ->
        Contract.invalid(
          :confirmation,
          "contains unsupported fields: #{Enum.join(keys, ", ")}"
        )
    end
  end

  defp confirmation_intent(confirmation) do
    case Contract.fetch(confirmation, :intent) do
      :error ->
        Contract.invalid(:intent, "can't be blank")

      {:ok, nil} ->
        Contract.invalid(:intent, "can't be blank")

      {:ok, value} ->
        with {:ok, text} <- Contract.text(value, :intent, max: 200) do
          Contract.enum(text, :intent, @confirmation_intents)
        end
    end
  end

  # The per-transfer lease bounds the receiver will be granted under, frozen
  # into the durable handoff intent beside the boundary, the authorized refs
  # and the confirmation.
  #
  # It exists because the receiver's lease is minted from the admission
  # decision's `proposed_bounds`, which come off the `AdmissionPolicy`, and
  # `Shoestring.Cobbler.HandoffWorker` passes no policy option — so in
  # production every receiver got the wake-shaped defaults and no operator
  # could say otherwise. In particular the 300-second default deadline
  # expired during harness startup on a cold cross-provider session.
  #
  # Validation (allow-list, bounds, and the reserve-below-budget rule) lives
  # in `Shoestring.Cobbler.HandoffLeasePolicy` next to the documented
  # rationale for each bound. It runs HERE, at request time, so an operator
  # learns about a bad policy immediately rather than at delivery, and so the
  # stored object is already normalized — which matters because the digest
  # covers it and a replay must compare equal.
  #
  # Fail-closed, exactly like `confirmation`: a non-object, an unknown key,
  # a non-integer, an out-of-range bound, or a reserve at or above its budget
  # is a rejected command, never a silently ignored field.
  defp lease_policy_field(raw) do
    case Contract.fetch(raw, :lease_policy) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, lease_policy} when is_map(lease_policy) ->
        case HandoffLeasePolicy.new(lease_policy) do
          {:ok, policy} -> {:ok, HandoffLeasePolicy.to_map(policy)}
          {:error, changeset} -> {:error, changeset}
        end

      {:ok, _other} ->
        Contract.invalid(:lease_policy, "must be an object")
    end
  end

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

  # The decision refs the operator authorized the transfer against, frozen
  # into the durable intent. `Shoestring.Cobbler.Handoffs.perform/3` compares
  # them against the refs projected at perform time and refuses a superseded
  # set, so an admission decided between request and perform cannot be
  # silently carried past. They are digest-covered, so a re-submission under
  # the same command id carrying different refs is a conflict, not a
  # replacement.
  defp decision_refs_field(raw) do
    case Contract.fetch(raw, :decision_refs) do
      {:ok, value} when is_list(value) -> normalize_decision_refs(value)
      {:ok, _other} -> Contract.invalid(:decision_refs, "must be a list")
      :error -> Contract.invalid(:decision_refs, "can't be blank")
    end
  end

  defp normalize_decision_refs(value) when length(value) > @max_decision_refs,
    do: Contract.invalid(:decision_refs, "contains too many entries")

  defp normalize_decision_refs(value) do
    Enum.reduce_while(value, {:ok, []}, fn ref, {:ok, acc} ->
      case Ecto.UUID.cast(ref) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, Contract.invalid(:decision_refs, "must contain only UUIDs")}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end

  defp uuid_field(raw, key) do
    case Contract.fetch(raw, key) do
      {:ok, value} ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> Contract.invalid(key, "must be a UUID")
        end

      :error ->
        Contract.invalid(key, "can't be blank")
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
