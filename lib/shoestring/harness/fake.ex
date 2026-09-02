defmodule Shoestring.Harness.Fake do
  @moduledoc """
  A deterministic fake harness adapter for offline testing.

  Implements `Shoestring.Harness.Adapter` using a pre-scripted `Scenario`.
  Events are scheduled against an injected clock so no real provider process,
  network, or credentials are required.

  ## Usage

      alias Shoestring.Harness.Fake
      alias Shoestring.Harness.Fake.{RequestLog, Scenario}

      scenario = Scenario.normal_completion()
      {:ok, log} = RequestLog.start()
      opts = %{scenario: scenario, clock: Shoestring.Test.FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      # Prove no raw transcript was passed
      [recorded_request] = RequestLog.all(log)
      refute Map.has_key?(recorded_request, :raw_transcript)

  """

  @behaviour Shoestring.Harness.Adapter

  alias Shoestring.Harness.{
    CapacitySnapshot,
    Clock,
    Error,
    HarnessEvent,
    Identity,
    RunIdentity,
    RunRequest
  }

  alias Shoestring.Harness.Fake.{RequestLog, Scenario}

  @adapter_id "shoestring.harness.fake"
  @adapter_version "1.0.0"

  @impl true
  @spec identity() :: Identity.t()
  def identity do
    {:ok, id} =
      Identity.new(%{
        adapter_id: @adapter_id,
        provider: "fake",
        adapter_version: @adapter_version,
        schema_version: 1,
        invocation_mode: :fake
      })

    id
  end

  @impl true
  @spec capabilities() :: MapSet.t(Shoestring.Harness.Adapter.capability())
  def capabilities, do: MapSet.new([:resume, :send, :cancel, :interactive])

  @impl true
  @spec probe(map()) :: {:ok, CapacitySnapshot.t()} | {:error, Error.t()}
  def probe(opts) do
    case scenario(opts).capacity do
      %CapacitySnapshot{} = snapshot -> {:ok, snapshot}
      nil -> {:error, Error.new(:transport, "fake_no_capacity", "no capacity configured")}
    end
  end

  @impl true
  @spec start(RunRequest.t(), map()) :: {:ok, RunIdentity.t()} | {:error, Error.t()}
  def start(%RunRequest{} = request, opts) do
    record_request(opts, {:start, request})
    s = scenario(opts)

    case s.start_error do
      %Error{} = error ->
        {:error, error}

      nil ->
        {:ok, run_identity(request.dispatch_id, s.provider_session_id)}
    end
  end

  @impl true
  @spec resume(RunIdentity.t(), RunRequest.t(), map()) ::
          {:ok, RunIdentity.t()} | {:error, Error.t()}
  def resume(%RunIdentity{} = _prior, %RunRequest{} = request, opts) do
    record_request(opts, {:resume, request})
    s = scenario(opts)

    case s.resume_error do
      %Error{} = error ->
        {:error, error}

      nil ->
        {:ok, run_identity(request.dispatch_id, s.provider_session_id)}
    end
  end

  @impl true
  @spec send(RunIdentity.t(), String.t(), map()) :: {:ok, :accepted} | {:error, Error.t()}
  def send(%RunIdentity{}, _message, _opts), do: {:ok, :accepted}

  @impl true
  @spec cancel(RunIdentity.t(), map()) :: {:ok, :cancelled} | {:error, Error.t()}
  def cancel(%RunIdentity{} = identity, opts) do
    record_request(opts, {:cancel, identity})
    {:ok, :cancelled}
  end

  @impl true
  @spec status(RunIdentity.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def status(%RunIdentity{} = _identity, _opts), do: {:ok, %{state: :running}}

  @impl true
  @spec stream(RunIdentity.t(), map()) ::
          {:ok, Enumerable.t(HarnessEvent.t())} | {:error, Error.t()}
  def stream(%RunIdentity{} = identity, opts) do
    s = scenario(opts)
    clock = clock_module(opts)
    base_time = Clock.now(clock)

    events =
      s.events
      |> Enum.with_index(1)
      |> Enum.map(fn {spec, ordinal} ->
        build_event(spec, ordinal, identity, base_time)
      end)
      |> apply_delivery_modifier(s.delivery_modifier)

    {:ok, events}
  end

  # -- Private helpers --

  defp scenario(%{scenario: %Scenario{} = s}), do: s
  defp scenario(_opts), do: raise("Fake adapter requires opts[:scenario] as a Scenario struct")

  defp clock_module(%{clock: clock}) when is_atom(clock), do: clock
  defp clock_module(_opts), do: Shoestring.Harness.SystemClock

  defp record_request(%{request_log: pid} = _opts, entry) when is_pid(pid) do
    RequestLog.record(pid, entry)
  end

  defp record_request(_opts, _entry), do: :ok

  defp run_identity(dispatch_id, provider_session_id) do
    %RunIdentity{
      run_id: dispatch_id,
      harness_id: @adapter_id,
      process_id: "fake-pid-#{System.unique_integer([:positive])}",
      provider_session_id: provider_session_id
    }
  end

  defp build_event(spec, ordinal, identity, base_time) do
    occurred_at = DateTime.add(base_time, spec.offset_ms, :millisecond)
    source_event_id = spec.source_event_id || "fake-evt-#{ordinal}"

    capacity_snapshot_id =
      case spec.capacity_snapshot do
        %CapacitySnapshot{} = s -> s.snapshot_id
        nil -> nil
      end

    %HarnessEvent{
      version: 1,
      run_id: identity.run_id,
      source_event_id: source_event_id,
      ordinal: ordinal,
      occurred_at: occurred_at,
      kind: spec.kind,
      process_id: identity.process_id,
      provider_session_id: identity.provider_session_id,
      artifact_id: nil,
      capacity_snapshot_id: capacity_snapshot_id,
      error: spec.error,
      result: spec.result,
      extensions: spec.extensions
    }
  end

  defp apply_delivery_modifier(events, :none), do: events

  defp apply_delivery_modifier(events, :delayed) do
    # Return events in order but mark them as delayed in extensions
    Enum.map(events, fn evt ->
      %{evt | extensions: Map.put(evt.extensions, "shoestring.fake:delayed", true)}
    end)
  end

  defp apply_delivery_modifier(events, :duplicate) do
    # Duplicate the first non-result event
    {before_last, [last]} = Enum.split(events, length(events) - 1)
    first = List.first(before_last)

    if first do
      duplicate = %{first | source_event_id: "#{first.source_event_id}-dup"}
      before_last ++ [duplicate, last]
    else
      events
    end
  end

  defp apply_delivery_modifier(events, :out_of_order) do
    # Swap the second and third events if there are at least 3
    case events do
      [first, second, third | rest] -> [first, third, second | rest]
      other -> other
    end
  end
end
