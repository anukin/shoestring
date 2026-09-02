defmodule Shoestring.Harness.CapacitySnapshot do
  @moduledoc """
  Versioned, provider-neutral capacity observations.

  A snapshot is an observation, never a reservation. In particular, only a
  fresh, complete, compatible proactive observation is eligible. Every other
  state is intentionally fail-closed.
  """

  alias Shoestring.Harness.Contract

  @version 2
  @capacity_states [:observed, :degraded, :refused, :unknown]
  @window_states [:observed, :unknown]
  @confidence [:none, :low, :medium, :high]
  @support_tiers [:proactive, :conservative_partial, :reactive_only, :unsupported]
  @compatibility [:compatible, :degraded, :incompatible]

  @source_events [
    :explicit_read,
    :update_notification,
    :status_line_input,
    :headless_result_error,
    :none
  ]

  @maximum_freshness_seconds 86_400

  @snapshot_keys [
    :version,
    :snapshot_id,
    :capacity_state,
    :windows,
    :observed_at,
    :freshness,
    :source,
    :scope,
    :confidence,
    :support_tier,
    :compatibility_state,
    :reason,
    :extensions
  ]

  @payload_keys [
    "snapshot_id",
    "run_id",
    "contract_version",
    "capacity_state",
    "windows",
    "observed_at",
    "expires_at",
    "freshness",
    "source",
    "scope",
    "confidence",
    "support_tier",
    "compatibility_state",
    "reason",
    "extensions"
  ]

  @enforce_keys [
    :version,
    :snapshot_id,
    :capacity_state,
    :windows,
    :observed_at,
    :expires_at,
    :freshness,
    :source,
    :scope,
    :confidence,
    :support_tier,
    :compatibility_state,
    :reason,
    :extensions
  ]
  defstruct [
    :version,
    :snapshot_id,
    :capacity_state,
    :windows,
    :observed_at,
    :expires_at,
    :freshness,
    :source,
    :scope,
    :confidence,
    :support_tier,
    :compatibility_state,
    :reason,
    :extensions
  ]

  @type window ::
          %{
            kind: String.t(),
            state: :observed,
            used_percent: number(),
            reset_at: DateTime.t() | nil
          }
          | %{kind: String.t(), state: :unknown, reason: String.t()}

  @type freshness :: %{max_age_seconds: pos_integer()}

  @type source :: %{
          adapter_id: String.t(),
          provider_id: String.t(),
          invocation_mode: String.t(),
          event: atom()
        }

  @type t :: %__MODULE__{
          version: 2,
          snapshot_id: Ecto.UUID.t(),
          capacity_state: :observed | :degraded | :refused | :unknown,
          windows: [window()],
          observed_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          freshness: freshness(),
          source: source(),
          scope: String.t(),
          confidence: atom(),
          support_tier: atom(),
          compatibility_state: atom(),
          reason: String.t() | nil,
          extensions: map()
        }

  @spec version() :: 2
  def version, do: @version

  @spec capacity_states() :: [atom()]
  def capacity_states, do: @capacity_states

  @spec window_states() :: [atom()]
  def window_states, do: @window_states

  @spec source_events() :: [atom()]
  def source_events, do: @source_events

  @spec support_tiers() :: [atom()]
  def support_tiers, do: @support_tiers

  @spec maximum_freshness_seconds() :: pos_integer()
  def maximum_freshness_seconds, do: @maximum_freshness_seconds

  @doc "Builds a snapshot, evaluating freshness against the injected clock."
  @spec new(map(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs, opts \\ [])

  def new(attrs, opts) when is_map(attrs) and is_list(opts) do
    with :ok <- ensure_only_keys(attrs, @snapshot_keys, :snapshot),
         {:ok, now} <- now(opts),
         {:ok, version} <- Contract.version(attrs, @version),
         {:ok, snapshot_id} <-
           attrs |> Contract.required(:snapshot_id) |> then(&uuid_result(&1, :snapshot_id)),
         {:ok, capacity_state} <-
           attrs
           |> Contract.required(:capacity_state)
           |> then(&Contract.enum(&1, :capacity_state, @capacity_states)),
         {:ok, windows} <- attrs |> Contract.required(:windows) |> then(&windows/1),
         {:ok, observed_at} <- nullable_required_datetime(attrs, :observed_at),
         {:ok, freshness} <- attrs |> Contract.required(:freshness) |> then(&freshness/1),
         {:ok, source} <- attrs |> Contract.required(:source) |> then(&source/1),
         {:ok, scope} <-
           attrs |> Contract.required(:scope) |> then(&Contract.text(&1, :scope, max: 300)),
         {:ok, confidence} <-
           attrs
           |> Contract.required(:confidence)
           |> then(&Contract.enum(&1, :confidence, @confidence)),
         {:ok, support_tier} <-
           attrs
           |> Contract.required(:support_tier)
           |> then(&Contract.enum(&1, :support_tier, @support_tiers)),
         {:ok, compatibility_state} <-
           attrs
           |> Contract.required(:compatibility_state)
           |> then(&Contract.enum(&1, :compatibility_state, @compatibility)),
         {:ok, reason} <- nullable_text(attrs, :reason, max: 300),
         {:ok, extensions} <-
           attrs |> Contract.optional(:extensions) |> then(&Contract.extensions/1),
         expires_at = expires_at(observed_at, freshness),
         :ok <-
           validate_state(
             capacity_state,
             windows,
             observed_at,
             freshness,
             source,
             confidence,
             compatibility_state,
             reason,
             now
           ) do
      {:ok,
       %__MODULE__{
         version: version,
         snapshot_id: snapshot_id,
         capacity_state: capacity_state,
         windows: windows,
         observed_at: observed_at,
         expires_at: expires_at,
         freshness: freshness,
         source: source,
         scope: scope,
         confidence: confidence,
         support_tier: support_tier,
         compatibility_state: compatibility_state,
         reason: reason,
         extensions: extensions
       }}
    end
  end

  def new(_attrs, _opts), do: Contract.invalid(:base, "must be an object")

  @doc "Decodes and strictly validates the v2 JSON event representation."
  @spec from_payload(map(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def from_payload(payload, opts \\ [])

  def from_payload(payload, opts) when is_map(payload) and is_list(opts) do
    with :ok <- ensure_only_keys(payload, @payload_keys, :capacity_payload),
         {:ok, version} <-
           payload |> fetch_payload("contract_version") |> then(&payload_version/1),
         {:ok, capacity_state} <-
           payload
           |> fetch_payload("capacity_state")
           |> then(&payload_enum(&1, :capacity_state, @capacity_states)),
         {:ok, windows} <- payload |> fetch_payload("windows") |> then(&payload_windows/1),
         {:ok, observed_at} <- payload_nullable_datetime(payload, "observed_at"),
         {:ok, freshness} <- payload |> fetch_payload("freshness") |> then(&payload_freshness/1),
         {:ok, source} <- payload |> fetch_payload("source") |> then(&payload_source/1),
         {:ok, confidence} <-
           payload
           |> fetch_payload("confidence")
           |> then(&payload_enum(&1, :confidence, @confidence)),
         {:ok, support_tier} <-
           payload
           |> fetch_payload("support_tier")
           |> then(&payload_enum(&1, :support_tier, @support_tiers)),
         {:ok, compatibility_state} <-
           payload
           |> fetch_payload("compatibility_state")
           |> then(&payload_enum(&1, :compatibility_state, @compatibility)),
         {:ok, reason} <- payload_nullable_text(payload, "reason", max: 300),
         {:ok, expires_at} <- payload_nullable_datetime(payload, "expires_at"),
         {:ok, snapshot} <-
           new(
             %{
               version: version,
               snapshot_id: payload_value(payload, "snapshot_id"),
               capacity_state: capacity_state,
               windows: windows,
               observed_at: observed_at,
               freshness: freshness,
               source: source,
               scope: payload_value(payload, "scope"),
               confidence: confidence,
               support_tier: support_tier,
               compatibility_state: compatibility_state,
               reason: reason,
               extensions: payload_value(payload, "extensions")
             },
             opts
           ),
         :ok <- validate_expiry(snapshot.expires_at, expires_at) do
      {:ok, snapshot}
    end
  end

  def from_payload(_payload, _opts), do: Contract.invalid(:base, "must be an object")

  @doc "Computes freshness at an injected time; it never treats the future as fresh."
  @spec freshness(t(), DateTime.t()) :: :fresh | :stale | :unknown
  def freshness(%__MODULE__{capacity_state: :unknown}, _now), do: :unknown
  def freshness(%__MODULE__{observed_at: nil}, _now), do: :unknown
  def freshness(%__MODULE__{expires_at: nil}, _now), do: :unknown

  def freshness(%__MODULE__{observed_at: observed_at, expires_at: expires_at}, %DateTime{} = now) do
    cond do
      DateTime.compare(observed_at, now) == :gt -> :unknown
      DateTime.compare(now, expires_at) in [:lt, :eq] -> :fresh
      true -> :stale
    end
  end

  @doc "Only complete, fresh proactive observations are eligible for admission."
  @spec eligible?(t(), DateTime.t()) :: boolean()
  def eligible?(snapshot, now) do
    snapshot.capacity_state == :observed and
      snapshot.confidence == :high and
      snapshot.support_tier == :proactive and
      snapshot.compatibility_state == :compatible and
      all_windows_observed?(snapshot.windows) and
      freshness(snapshot, now) == :fresh
  end

  @spec unknown?(t()) :: boolean()
  def unknown?(%__MODULE__{capacity_state: :unknown}), do: true
  def unknown?(%__MODULE__{}), do: false

  defp now(opts) do
    opts
    |> Keyword.get(:now, DateTime.utc_now())
    |> Contract.datetime(:now)
  end

  defp uuid_result({:ok, value}, field), do: Contract.uuid(value, field)
  defp uuid_result(error, _field), do: error

  defp nullable_required_datetime(attrs, key) do
    case Contract.fetch(attrs, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> Contract.datetime(value, key)
      :error -> Contract.invalid(key, "can't be blank")
    end
  end

  defp nullable_text(attrs, key, opts) do
    case Contract.fetch(attrs, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> Contract.text(value, key, opts)
      :error -> {:ok, nil}
    end
  end

  defp freshness({:ok, value}), do: freshness(value)

  defp freshness(value) when is_map(value) do
    with :ok <- ensure_only_keys(value, [:max_age_seconds], :freshness),
         {:ok, max_age_seconds} <-
           value
           |> Contract.required(:max_age_seconds)
           |> then(&Contract.positive_integer(&1, :max_age_seconds)),
         true <- max_age_seconds <= @maximum_freshness_seconds do
      {:ok, %{max_age_seconds: max_age_seconds}}
    else
      false -> Contract.invalid(:max_age_seconds, "must not exceed #{@maximum_freshness_seconds}")
      error -> error
    end
  end

  defp freshness(_value), do: Contract.invalid(:freshness, "must be an object")

  defp source({:ok, value}), do: source(value)

  defp source(value) when is_map(value) do
    with :ok <-
           ensure_only_keys(value, [:adapter_id, :provider_id, :invocation_mode, :event], :source),
         {:ok, adapter_id} <-
           value
           |> Contract.required(:adapter_id)
           |> then(&Contract.text(&1, :source_adapter_id, max: 200)),
         {:ok, provider_id} <-
           value
           |> Contract.required(:provider_id)
           |> then(&Contract.text(&1, :source_provider_id, max: 100)),
         {:ok, invocation_mode} <-
           value
           |> Contract.required(:invocation_mode)
           |> then(&Contract.text(&1, :source_invocation_mode, max: 100)),
         {:ok, event} <-
           value
           |> Contract.required(:event)
           |> then(&Contract.enum(&1, :source_event, @source_events)) do
      {:ok,
       %{
         adapter_id: adapter_id,
         provider_id: provider_id,
         invocation_mode: invocation_mode,
         event: event
       }}
    end
  end

  defp source(_value), do: Contract.invalid(:source, "must be an object")

  defp windows({:ok, value}), do: windows(value)

  defp windows(value) do
    with {:ok, windows} <- Contract.list(value, :windows, max: 16),
         {:ok, windows} <- parse_windows(windows),
         true <- Enum.uniq_by(windows, & &1.kind) == windows do
      {:ok, windows}
    else
      false -> Contract.invalid(:windows, "window names must be unique")
      error -> error
    end
  end

  defp parse_windows(windows) do
    Enum.reduce_while(windows, {:ok, []}, fn window, {:ok, acc} ->
      case window(window) do
        {:ok, window} -> {:cont, {:ok, [window | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, windows} -> {:ok, Enum.reverse(windows)}
      error -> error
    end
  end

  defp window(value) when is_map(value) do
    with :ok <-
           ensure_only_keys(value, [:kind, :state, :used_percent, :reset_at, :reason], :window),
         {:ok, kind} <-
           value |> Contract.required(:kind) |> then(&Contract.text(&1, :window_kind, max: 100)),
         {:ok, state} <-
           value
           |> Contract.required(:state)
           |> then(&Contract.enum(&1, :window_state, @window_states)) do
      window_for_state(state, kind, value)
    end
  end

  defp window(_value), do: Contract.invalid(:windows, "entries must be objects")

  defp window_for_state(:observed, kind, value) do
    with {:ok, used_percent} <-
           value
           |> Contract.required(:used_percent)
           |> then(&Contract.percentage(&1, :used_percent)),
         {:ok, reset_at} <- optional_datetime(value, :reset_at),
         :ok <- reject_present(value, :reason, :window_reason) do
      {:ok, %{kind: kind, state: :observed, used_percent: used_percent, reset_at: reset_at}}
    end
  end

  defp window_for_state(:unknown, kind, value) do
    with {:ok, reason} <-
           value
           |> Contract.required(:reason)
           |> then(&Contract.text(&1, :window_reason, max: 300)),
         :ok <- reject_present(value, :used_percent, :used_percent),
         :ok <- reject_present(value, :reset_at, :reset_at) do
      {:ok, %{kind: kind, state: :unknown, reason: reason}}
    end
  end

  defp optional_datetime(attrs, key) do
    case Contract.fetch(attrs, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> Contract.datetime(value, key)
      :error -> {:ok, nil}
    end
  end

  defp reject_present(attrs, key, field) do
    case Contract.fetch(attrs, key) do
      {:ok, nil} -> :ok
      :error -> :ok
      {:ok, _value} -> Contract.invalid(field, "is not allowed for this state")
    end
  end

  defp validate_state(
         :observed,
         windows,
         observed_at,
         freshness,
         source,
         :high,
         :compatible,
         nil,
         now
       ) do
    with true <- windows != [] and all_windows_observed?(windows),
         true <- observed_at != nil,
         true <- source.event != :none,
         :fresh <- freshness_for(observed_at, freshness, now) do
      :ok
    else
      false ->
        Contract.invalid(
          :capacity_state,
          "observed capacity requires complete timestamped windows and a source event"
        )

      :stale ->
        Contract.invalid(:capacity_state, "stale capacity must be degraded")

      :future ->
        Contract.invalid(:capacity_state, "future capacity must be unknown")

      :unknown ->
        Contract.invalid(:capacity_state, "timestamp-unknown capacity must be unknown")
    end
  end

  defp validate_state(
         :observed,
         _windows,
         _observed_at,
         _freshness,
         _source,
         _confidence,
         _compatibility,
         _reason,
         _now
       ),
       do:
         Contract.invalid(
           :capacity_state,
           "observed capacity requires high confidence, compatibility, and no reason"
         )

  defp validate_state(
         :degraded,
         windows,
         observed_at,
         freshness,
         _source,
         confidence,
         _compatibility,
         reason,
         now
       ) do
    with true <- Enum.any?(windows, &(&1.state == :observed)),
         true <- observed_at != nil,
         true <- confidence in [:low, :medium, :high],
         true <- is_binary(reason),
         freshness_state <- freshness_for(observed_at, freshness, now),
         true <- freshness_state in [:fresh, :stale] do
      :ok
    else
      false ->
        Contract.invalid(
          :capacity_state,
          "degraded capacity requires a timestamped observed window and reason"
        )

      :future ->
        Contract.invalid(:capacity_state, "future capacity must be unknown")

      :unknown ->
        Contract.invalid(:capacity_state, "timestamp-unknown capacity must be unknown")
    end
  end

  defp validate_state(
         :refused,
         _windows,
         _observed_at,
         _freshness,
         _source,
         _confidence,
         _compatibility,
         reason,
         _now
       )
       when is_binary(reason),
       do: :ok

  defp validate_state(
         :refused,
         _windows,
         _observed_at,
         _freshness,
         _source,
         _confidence,
         _compatibility,
         _reason,
         _now
       ),
       do: Contract.invalid(:reason, "is required when capacity is refused")

  defp validate_state(
         :unknown,
         windows,
         _observed_at,
         _freshness,
         _source,
         :none,
         _compatibility,
         reason,
         _now
       )
       when is_binary(reason) do
    if windows == [] or Enum.all?(windows, &(&1.state == :unknown)) do
      :ok
    else
      Contract.invalid(:capacity_state, "unknown capacity cannot contain observed windows")
    end
  end

  defp validate_state(
         :unknown,
         _windows,
         _observed_at,
         _freshness,
         _source,
         _confidence,
         _compatibility,
         _reason,
         _now
       ),
       do:
         Contract.invalid(
           :capacity_state,
           "unknown capacity requires none confidence and a reason"
         )

  defp freshness_for(nil, _freshness, _now), do: :unknown

  defp freshness_for(observed_at, freshness, now) do
    expires_at = expires_at(observed_at, freshness)

    cond do
      DateTime.compare(observed_at, now) == :gt -> :future
      DateTime.compare(now, expires_at) in [:lt, :eq] -> :fresh
      true -> :stale
    end
  end

  defp expires_at(nil, _freshness), do: nil

  defp expires_at(observed_at, %{max_age_seconds: max_age_seconds}),
    do: DateTime.add(observed_at, max_age_seconds, :second)

  defp all_windows_observed?(windows),
    do: windows != [] and Enum.all?(windows, &(&1.state == :observed))

  defp fetch_payload(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> {:ok, value}
      :error -> Contract.invalid(payload_field(key), "can't be blank")
    end
  end

  defp payload_value(payload, key), do: Map.get(payload, key)

  defp payload_version({:ok, @version}), do: {:ok, @version}

  defp payload_version({:ok, value}),
    do: Contract.invalid(:contract_version, "must equal #{@version}; received #{inspect(value)}")

  defp payload_version(error), do: error

  defp payload_enum({:ok, value}, field, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> Contract.invalid(field, "must be a recognized state")
      atom -> {:ok, atom}
    end
  end

  defp payload_enum({:ok, _value}, field, _allowed),
    do: Contract.invalid(field, "must be a string")

  defp payload_enum(:error, field, _allowed), do: Contract.invalid(field, "can't be blank")

  defp payload_enum(error, _field, _allowed), do: error

  defp payload_windows({:ok, %{"items" => items} = value}) when map_size(value) == 1,
    do: payload_windows(items)

  defp payload_windows({:ok, _value}),
    do: Contract.invalid(:windows, "must contain only an items list")

  defp payload_windows({:error, _changeset} = error), do: error

  defp payload_windows(items) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case payload_window(item) do
        {:ok, window} -> {:cont, {:ok, [window | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, windows} -> {:ok, Enum.reverse(windows)}
      error -> error
    end
  end

  defp payload_windows(_items), do: Contract.invalid(:windows, "items must be a list")

  defp payload_window(value) when is_map(value) do
    with :ok <-
           ensure_only_keys(
             value,
             ["kind", "state", "used_percent", "reset_at", "reason"],
             :window
           ),
         {:ok, state} <- payload_enum(Map.fetch(value, "state"), :window_state, @window_states),
         {:ok, kind} <-
           value |> fetch_payload("kind") |> Contract.text(:window_kind, max: 100) do
      case state do
        :observed ->
          with {:ok, used_percent} <-
                 value |> fetch_payload("used_percent") |> Contract.percentage(:used_percent),
               {:ok, reset_at} <- payload_optional_datetime(value, "reset_at"),
               :ok <- reject_present(value, "reason", :window_reason) do
            {:ok, %{kind: kind, state: :observed, used_percent: used_percent, reset_at: reset_at}}
          end

        :unknown ->
          with {:ok, reason} <-
                 value |> fetch_payload("reason") |> Contract.text(:window_reason, max: 300),
               :ok <- reject_present(value, "used_percent", :used_percent),
               :ok <- reject_present(value, "reset_at", :reset_at) do
            {:ok, %{kind: kind, state: :unknown, reason: reason}}
          end
      end
    end
  end

  defp payload_window(_value), do: Contract.invalid(:windows, "entries must be objects")

  defp payload_freshness({:ok, %{"max_age_seconds" => max_age_seconds} = value})
       when map_size(value) == 1,
       do: freshness(%{max_age_seconds: max_age_seconds})

  defp payload_freshness({:ok, _value}),
    do: Contract.invalid(:freshness, "must contain max_age_seconds")

  defp payload_freshness(error), do: error

  defp payload_source({:ok, value}) when is_map(value) do
    with :ok <-
           ensure_only_keys(
             value,
             ["adapter_id", "provider_id", "invocation_mode", "event"],
             :source
           ),
         {:ok, event} <- payload_enum(Map.fetch(value, "event"), :source_event, @source_events),
         {:ok, adapter_id} <-
           fetch_payload(value, "adapter_id") |> Contract.text(:source_adapter_id, max: 200),
         {:ok, provider_id} <-
           fetch_payload(value, "provider_id") |> Contract.text(:source_provider_id, max: 100),
         {:ok, invocation_mode} <-
           fetch_payload(value, "invocation_mode")
           |> Contract.text(:source_invocation_mode, max: 100) do
      {:ok,
       %{
         adapter_id: adapter_id,
         provider_id: provider_id,
         invocation_mode: invocation_mode,
         event: event
       }}
    end
  end

  defp payload_source({:ok, _value}), do: Contract.invalid(:source, "must be an object")
  defp payload_source(error), do: error

  defp payload_nullable_datetime(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> Contract.datetime(value, payload_field(key))
      :error -> Contract.invalid(payload_field(key), "can't be blank")
    end
  end

  defp payload_optional_datetime(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> Contract.datetime(value, payload_field(key))
      :error -> {:ok, nil}
    end
  end

  defp payload_nullable_text(payload, key, opts) do
    case Map.fetch(payload, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> Contract.text(value, payload_field(key), opts)
      :error -> Contract.invalid(payload_field(key), "can't be blank")
    end
  end

  defp validate_expiry(nil, nil), do: :ok

  defp validate_expiry(%DateTime{} = expected, %DateTime{} = actual) do
    if DateTime.compare(expected, actual) == :eq do
      :ok
    else
      Contract.invalid(:expires_at, "must equal observed_at plus max_age_seconds")
    end
  end

  defp validate_expiry(_expected, _actual),
    do: Contract.invalid(:expires_at, "must equal observed_at plus max_age_seconds")

  defp ensure_only_keys(map, allowed, field) do
    allowed = Enum.map(allowed, &to_string/1)

    if Enum.all?(Map.keys(map), &(to_string(&1) in allowed)) do
      :ok
    else
      Contract.invalid(field, "contains unsupported fields")
    end
  end

  defp payload_field("contract_version"), do: :contract_version
  defp payload_field("capacity_state"), do: :capacity_state
  defp payload_field("observed_at"), do: :observed_at
  defp payload_field("expires_at"), do: :expires_at
  defp payload_field("freshness"), do: :freshness
  defp payload_field("source"), do: :source
  defp payload_field("scope"), do: :scope
  defp payload_field("confidence"), do: :confidence
  defp payload_field("support_tier"), do: :support_tier
  defp payload_field("compatibility_state"), do: :compatibility_state
  defp payload_field("reason"), do: :reason
  defp payload_field("extensions"), do: :extensions
  defp payload_field("snapshot_id"), do: :snapshot_id
  defp payload_field("kind"), do: :window_kind
  defp payload_field("state"), do: :window_state
  defp payload_field("used_percent"), do: :used_percent
  defp payload_field("reset_at"), do: :reset_at
  defp payload_field("adapter_id"), do: :source_adapter_id
  defp payload_field("provider_id"), do: :source_provider_id
  defp payload_field("invocation_mode"), do: :source_invocation_mode
  defp payload_field("event"), do: :source_event
  defp payload_field(_key), do: :base
end
