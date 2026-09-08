defmodule Shoestring.Cobbler.AdmissionDecision do
  @moduledoc """
  Versioned representation of an admission decision.

  An admission decision records the evaluation of a candidate provider against
  an admission request, incorporating capacity observations, reserve policies,
  scope occupancy, and explicit override confirmations.

  Results:
  - `:admit` - Eligible for execution (automatic or confirmed)
  - `:defer_until` - Temporarily blocked (reserve breach, active occupancy, or rate limit);
    deferred until a reset timestamp or delayed recheck
  - `:require_confirmation` - Requires attributable single-decision operator confirmation
    (e.g., stale observation, reactive-only/conservative-partial tier, unknown capacity)
  - `:reject` - Permanently refused for this candidate (unsupported capability,
    incompatible CLI, or scope mismatch; cannot be bypassed)
  """

  alias Shoestring.Harness.Contract

  @version 1
  @results [:admit, :defer_until, :require_confirmation, :reject]
  @result_strings Enum.map(@results, &Atom.to_string/1)

  @enforce_keys [
    :version,
    :decision_id,
    :result,
    :reason_code,
    :explanation,
    :requested_capability,
    :candidate,
    :scope,
    :observation,
    :policy,
    :proposed_bounds,
    :reobservation_required,
    :evaluated_at
  ]
  defstruct [
    :version,
    :decision_id,
    :run_id,
    :goal_id,
    :task_id,
    :result,
    :reason_code,
    :explanation,
    :requested_capability,
    :candidate,
    :scope,
    :observation,
    :policy,
    :override,
    :proposed_bounds,
    :defer_until,
    :reobservation_required,
    :evaluated_at,
    extensions: %{}
  ]

  @type candidate :: %{
          provider_id: String.t(),
          adapter_id: String.t(),
          support_tier: atom() | String.t(),
          compatibility_state: atom() | String.t()
        }

  @type t :: %__MODULE__{
          version: 1,
          decision_id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t() | nil,
          goal_id: Ecto.UUID.t() | nil,
          task_id: Ecto.UUID.t() | nil,
          result: :admit | :defer_until | :require_confirmation | :reject,
          reason_code: String.t(),
          explanation: String.t(),
          requested_capability: String.t(),
          candidate: candidate(),
          scope: String.t(),
          observation: map(),
          policy: map(),
          override: map() | nil,
          proposed_bounds: map(),
          defer_until: DateTime.t() | nil,
          reobservation_required: boolean(),
          evaluated_at: DateTime.t(),
          extensions: map()
        }

  @spec version() :: 1
  def version, do: @version

  @spec results() :: [atom()]
  def results, do: @results

  @doc "Validates and constructs an AdmissionDecision struct."
  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, version} <-
           validate_version(Map.get(attrs, :version, Map.get(attrs, "version", @version))),
         {:ok, decision_id} <- fetch_uuid(attrs, :decision_id),
         {:ok, result} <- fetch_result(attrs),
         {:ok, reason_code} <- fetch_string(attrs, :reason_code),
         {:ok, explanation} <- fetch_string(attrs, :explanation),
         {:ok, capability} <- fetch_string(attrs, :requested_capability),
         {:ok, candidate} <- fetch_candidate(attrs),
         {:ok, scope} <- fetch_string(attrs, :scope),
         {:ok, observation} <- fetch_observation(attrs),
         {:ok, policy} <- fetch_map(attrs, :policy),
         {:ok, proposed_bounds} <- fetch_map(attrs, :proposed_bounds),
         {:ok, evaluated_at} <- fetch_datetime(attrs, :evaluated_at),
         reobservation_req = get_boolean(attrs, :reobservation_required, false),
         run_id = get_optional_uuid(attrs, :run_id),
         goal_id = get_optional_uuid(attrs, :goal_id),
         task_id = get_optional_uuid(attrs, :task_id),
         defer_until = get_optional_datetime(attrs, :defer_until),
         override = get_optional_map(attrs, :override),
         extensions = Map.get(attrs, :extensions, Map.get(attrs, "extensions", %{})) do
      {:ok,
       %__MODULE__{
         version: version,
         decision_id: decision_id,
         run_id: run_id,
         goal_id: goal_id,
         task_id: task_id,
         result: result,
         reason_code: reason_code,
         explanation: explanation,
         requested_capability: capability,
         candidate: candidate,
         scope: scope,
         observation: observation,
         policy: policy,
         override: override,
         proposed_bounds: proposed_bounds,
         defer_until: defer_until,
         reobservation_required: reobservation_req,
         evaluated_at: evaluated_at,
         extensions: extensions
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:base, "must be an object")

  @doc "Converts an AdmissionDecision to a durable payload map with string keys."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = d) do
    payload = %{
      "decision_id" => d.decision_id,
      "result" => to_string(d.result),
      "reason_code" => d.reason_code,
      "explanation" => d.explanation,
      "requested_capability" => d.requested_capability,
      "candidate" => stringify_keys(d.candidate),
      "scope" => d.scope,
      "observation" => stringify_keys(d.observation),
      "policy" => stringify_keys(d.policy),
      "proposed_bounds" => stringify_keys(d.proposed_bounds),
      "reobservation_required" => d.reobservation_required,
      "evaluated_at" => DateTime.to_iso8601(d.evaluated_at),
      "extensions" => d.extensions || %{}
    }

    payload =
      if d.run_id, do: Map.put(payload, "run_id", d.run_id), else: payload

    payload =
      if d.defer_until,
        do: Map.put(payload, "defer_until", DateTime.to_iso8601(d.defer_until)),
        else: payload

    payload =
      if d.override,
        do: Map.put(payload, "override", stringify_keys(d.override)),
        else: payload

    payload
  end

  @doc "Parses and validates an AdmissionDecision from a durable payload map."
  @spec from_payload(map(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def from_payload(payload, opts \\ [])

  def from_payload(payload, _opts) when is_map(payload) do
    new(payload)
  end

  def from_payload(_payload, _opts), do: Contract.invalid(:base, "must be an object")

  defp validate_version(1), do: {:ok, 1}
  defp validate_version(_), do: Contract.invalid(:version, "must equal #{@version}")

  defp fetch_result(attrs) do
    val = Map.get(attrs, :result, Map.get(attrs, "result"))

    cond do
      val in @results ->
        {:ok, val}

      is_binary(val) and val in @result_strings ->
        {:ok, String.to_existing_atom(val)}

      true ->
        Contract.invalid(:result, "must be one of #{Enum.join(@result_strings, ", ")}")
    end
  end

  defp fetch_uuid(attrs, key) do
    val = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    case Ecto.UUID.cast(val) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> Contract.invalid(key, "must be a valid UUID")
    end
  end

  defp get_optional_uuid(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil ->
        nil

      val ->
        case Ecto.UUID.cast(val) do
          {:ok, uuid} -> uuid
          :error -> nil
        end
    end
  end

  defp fetch_string(attrs, key) do
    val = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    if is_binary(val) and String.trim(val) != "" do
      {:ok, val}
    else
      Contract.invalid(key, "can't be blank")
    end
  end

  defp fetch_candidate(attrs) do
    val = Map.get(attrs, :candidate, Map.get(attrs, "candidate"))

    cond do
      is_map(val) ->
        provider_id = Map.get(val, :provider_id, Map.get(val, "provider_id"))
        adapter_id = Map.get(val, :adapter_id, Map.get(val, "adapter_id"))
        tier = Map.get(val, :support_tier, Map.get(val, "support_tier"))
        compat = Map.get(val, :compatibility_state, Map.get(val, "compatibility_state"))

        if is_binary(provider_id) and is_binary(adapter_id) and tier != nil and compat != nil do
          {:ok,
           %{
             provider_id: provider_id,
             adapter_id: adapter_id,
             support_tier: normalize_atom(tier),
             compatibility_state: normalize_atom(compat)
           }}
        else
          Contract.invalid(
            :candidate,
            "must specify provider_id, adapter_id, support_tier, and compatibility_state"
          )
        end

      true ->
        Contract.invalid(:candidate, "must be an object")
    end
  end

  defp fetch_observation(attrs) do
    val = Map.get(attrs, :observation, Map.get(attrs, "observation"))

    cond do
      is_map(val) ->
        {:ok, stringify_keys(val)}

      true ->
        Contract.invalid(:observation, "must be an object")
    end
  end

  defp fetch_map(attrs, key) do
    val = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    cond do
      is_map(val) ->
        {:ok, stringify_keys(val)}

      true ->
        Contract.invalid(key, "must be an object")
    end
  end

  defp get_optional_map(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil -> nil
      map when is_map(map) -> stringify_keys(map)
      _ -> nil
    end
  end

  defp fetch_datetime(attrs, key) do
    val = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    case val do
      %DateTime{} = dt ->
        {:ok, DateTime.truncate(dt, :microsecond)}

      str when is_binary(str) ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :microsecond)}
          _ -> Contract.invalid(key, "must be an ISO8601 datetime string")
        end

      _ ->
        Contract.invalid(key, "must be a datetime")
    end
  end

  defp get_optional_datetime(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil ->
        nil

      %DateTime{} = dt ->
        DateTime.truncate(dt, :microsecond)

      str when is_binary(str) ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp get_boolean(attrs, key, default) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default)) do
      val when is_boolean(val) -> val
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp normalize_atom(val) when is_atom(val), do: val

  defp normalize_atom(val) when is_binary(val) do
    try do
      String.to_existing_atom(val)
    rescue
      ArgumentError -> String.to_atom(val)
    end
  end

  defp normalize_atom(val), do: val

  defp stringify_keys(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp stringify_keys(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> stringify_keys()

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)

  defp stringify_keys(val) when is_atom(val) and not is_nil(val) and not is_boolean(val),
    do: Atom.to_string(val)

  defp stringify_keys(val), do: val
end
