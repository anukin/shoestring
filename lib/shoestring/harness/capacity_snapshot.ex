defmodule Shoestring.Harness.CapacitySnapshot do
  @moduledoc "Versioned normalized capacity observation with explicit unknown semantics."

  alias Shoestring.Harness.Contract

  @version 1
  @confidence [:none, :low, :medium, :high]
  @support_tiers [:supported, :partial, :unsupported]
  @compatibility [:compatible, :degraded, :incompatible]

  @enforce_keys [
    :version,
    :snapshot_id,
    :capacity_state,
    :windows,
    :observed_at,
    :expires_at,
    :source,
    :scope,
    :confidence,
    :support_tier,
    :compatibility_state,
    :extensions
  ]
  defstruct [
    :version,
    :snapshot_id,
    :capacity_state,
    :windows,
    :observed_at,
    :expires_at,
    :source,
    :scope,
    :confidence,
    :support_tier,
    :compatibility_state,
    :extensions
  ]

  @type window ::
          %{kind: String.t(), state: :known, used_percent: number(), reset_at: DateTime.t() | nil}
          | %{kind: String.t(), state: :unknown, reason: String.t()}

  @type t :: %__MODULE__{
          version: 1,
          snapshot_id: Ecto.UUID.t(),
          capacity_state: :known | :unknown,
          windows: [window()],
          observed_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          source: %{adapter_id: String.t(), method: String.t()},
          scope: String.t(),
          confidence: atom(),
          support_tier: atom(),
          compatibility_state: atom(),
          extensions: map()
        }

  @spec version() :: 1
  def version, do: @version

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, version} <- Contract.version(attrs, @version),
         {:ok, snapshot_id} <-
           attrs |> Contract.required(:snapshot_id) |> then(&uuid_result(&1, :snapshot_id)),
         {:ok, capacity_state} <-
           attrs
           |> Contract.required(:capacity_state)
           |> then(&Contract.enum(&1, :capacity_state, [:known, :unknown])),
         {:ok, windows} <- attrs |> Contract.required(:windows) |> then(&windows/1),
         {:ok, observed_at} <-
           attrs |> Contract.required(:observed_at) |> then(&datetime_result(&1, :observed_at)),
         {:ok, expires_at} <-
           attrs |> Contract.optional(:expires_at) |> then(&optional_datetime(&1, :expires_at)),
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
         {:ok, extensions} <-
           attrs |> Contract.optional(:extensions) |> then(&Contract.extensions/1),
         :ok <- validate_state(capacity_state, windows, expires_at, confidence) do
      {:ok,
       %__MODULE__{
         version: version,
         snapshot_id: snapshot_id,
         capacity_state: capacity_state,
         windows: windows,
         observed_at: observed_at,
         expires_at: expires_at,
         source: source,
         scope: scope,
         confidence: confidence,
         support_tier: support_tier,
         compatibility_state: compatibility_state,
         extensions: extensions
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:base, "must be an object")

  @doc "Computes capacity freshness at an injected time; unknown remains unknown."
  @spec freshness(t(), DateTime.t()) :: :fresh | :stale | :unknown
  def freshness(%__MODULE__{capacity_state: :unknown}, _now), do: :unknown
  def freshness(%__MODULE__{expires_at: nil}, _now), do: :unknown

  def freshness(%__MODULE__{expires_at: expires_at}, %DateTime{} = now) do
    if DateTime.compare(now, expires_at) in [:lt, :eq], do: :fresh, else: :stale
  end

  @spec eligible?(t(), DateTime.t()) :: boolean()
  def eligible?(snapshot, now),
    do: snapshot.capacity_state == :known and freshness(snapshot, now) == :fresh

  @spec unknown?(t()) :: boolean()
  def unknown?(%__MODULE__{capacity_state: :unknown}), do: true
  def unknown?(%__MODULE__{}), do: false

  defp uuid_result({:ok, value}, field), do: Contract.uuid(value, field)
  defp uuid_result(error, _field), do: error
  defp datetime_result({:ok, value}, field), do: Contract.datetime(value, field)
  defp datetime_result(error, _field), do: error
  defp optional_datetime(nil, _field), do: {:ok, nil}
  defp optional_datetime({:ok, value}, field), do: optional_datetime(value, field)
  defp optional_datetime(value, field), do: Contract.datetime(value, field)

  defp source(value) when is_map(value) do
    with {:ok, adapter_id} <-
           value
           |> Contract.required(:adapter_id)
           |> then(&Contract.text(&1, :source_adapter_id, max: 200)),
         {:ok, method} <-
           value
           |> Contract.required(:method)
           |> then(&Contract.enum(&1, :source_method, ["probe", "status", "vendor_api"])),
         true <- Enum.all?(Map.keys(value), &(to_string(&1) in ["adapter_id", "method"])) do
      {:ok, %{adapter_id: adapter_id, method: method}}
    else
      false -> Contract.invalid(:source, "contains unsupported fields")
      error -> error
    end
  end

  defp source({:ok, value}), do: source(value)

  defp source(_value), do: Contract.invalid(:source, "must be an object")

  defp windows({:ok, value}), do: windows(value)

  defp windows(value) do
    with {:ok, windows} <- Contract.list(value, :windows, max: 16) do
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
  end

  defp window(value) when is_map(value) do
    with {:ok, kind} <-
           value |> Contract.required(:kind) |> then(&Contract.text(&1, :window_kind, max: 100)),
         {:ok, state} <-
           value
           |> Contract.required(:state)
           |> then(&Contract.enum(&1, :window_state, [:known, :unknown])) do
      window_for_state(state, kind, value)
    end
  end

  defp window(_value), do: Contract.invalid(:windows, "entries must be objects")

  defp window_for_state(:known, kind, value) do
    with {:ok, used_percent} <-
           value
           |> Contract.required(:used_percent)
           |> then(&Contract.percentage(&1, :used_percent)),
         {:ok, reset_at} <-
           value |> Contract.optional(:reset_at) |> then(&optional_datetime(&1, :reset_at)) do
      {:ok, %{kind: kind, state: :known, used_percent: used_percent, reset_at: reset_at}}
    end
  end

  defp window_for_state(:unknown, kind, value) do
    with {:ok, reason} <-
           value
           |> Contract.required(:reason)
           |> then(&Contract.text(&1, :window_reason, max: 300)) do
      {:ok, %{kind: kind, state: :unknown, reason: reason}}
    end
  end

  defp validate_state(:known, [], _expires_at, _confidence),
    do: Contract.invalid(:windows, "must include at least one window when known")

  defp validate_state(:known, _windows, nil, _confidence),
    do: Contract.invalid(:expires_at, "is required when capacity is known")

  defp validate_state(:unknown, windows, _expires_at, :none) when windows == [], do: :ok

  defp validate_state(:unknown, _windows, _expires_at, _confidence),
    do:
      Contract.invalid(
        :capacity_state,
        "unknown capacity requires no windows and none confidence"
      )

  defp validate_state(:known, _windows, _expires_at, _confidence), do: :ok
end
