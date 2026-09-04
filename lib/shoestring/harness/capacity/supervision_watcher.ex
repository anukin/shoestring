defmodule Shoestring.Harness.Capacity.SupervisionWatcher do
  @moduledoc """
  Emits the observable signal when capacity supervision dies from
  restart-intensity exhaustion (DEF-01b).

  When `Shoestring.Harness.Capacity.Supervisor` exhausts its `3 restarts / 60s`
  intensity it terminates with the bare exit reason `:shutdown` and — as a
  `:transient` child — stays down for the life of the VM. This watcher survives
  that outage (it is a younger sibling under the same parent) and turns the
  otherwise silent death into two observable signals:

    * a `Logger.error` stating that capacity monitoring is disabled until an
      explicit operator restart or redeploy, and
    * a `:telemetry.execute(telemetry_event(), %{count: 1}, metadata)` event,
      where `telemetry_event/0` is
      `[:shoestring, :capacity, :supervisor, :exhausted]`.

  ## Why the signal does NOT false-alarm on graceful shutdown

  Two independent, structural discriminations — no flags, no timing windows:

    1. Exit-reason classes. Genuine intensity exhaustion always exits `:shutdown`
       (bare atom; OTP reports `:reached_max_restart_intensity` only in its log
       report, never in the exit term — both the bare atom and the
       `{:shutdown, _}` tuple are treated as exhaustion defensively). An
       intentional direct stop (`Supervisor.stop/1`, default reason `:normal`)
       exits `:normal` and is ignored. Abnormal exits (`:killed`, crashes) are
       also ignored: a `:transient` parent restarts those, so monitoring
       self-heals and "disabled until operator restart" would be false.
    2. Sibling order. This watcher MUST be started AFTER the capacity
       supervisor under their common parent (see `Shoestring.Application`).
       OTP terminates children in reverse start order, so a graceful parent
       shutdown terminates this watcher BEFORE the capacity supervisor: the
       watcher is already dead when the capacity `:shutdown` exit happens and
       therefore cannot observe it. On genuine exhaustion only the capacity
       supervisor dies, the watcher survives, and the signal fires.

  If the capacity supervisor is ever re-started (operator restart), the watcher
  re-discovers it by name and resumes monitoring with no further signal.
  """

  use GenServer

  require Logger

  alias Shoestring.Harness.Capacity.Supervisor, as: CapacitySupervisor

  @telemetry_event [:shoestring, :capacity, :supervisor, :exhausted]
  @resolve_interval_ms 100

  @doc "Telemetry event emitted when capacity supervision dies from intensity exhaustion."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  Starts the watcher.

  ## Options

    * `:capacity` - the supervised capacity supervisor to monitor, as a
      registered name (preferred, so a restarted supervisor is re-discovered)
      or a pid. Defaults to `Shoestring.Harness.Capacity.Supervisor`.
    * `:name` - GenServer registration name (defaults to `__MODULE__`).
      Pass `nil` for an unnamed watcher.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name_opt, init_opts} = Keyword.pop(opts, :name, __MODULE__)

    case name_opt do
      nil -> GenServer.start_link(__MODULE__, init_opts)
      name -> GenServer.start_link(__MODULE__, init_opts, name: name)
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      capacity: Keyword.get(opts, :capacity, CapacitySupervisor),
      monitor_ref: nil
    }

    {:ok, state, {:continue, :resolve}}
  end

  @impl GenServer
  def handle_continue(:resolve, state), do: {:noreply, resolve(state)}

  @impl GenServer
  def handle_info(:resolve, state), do: {:noreply, resolve(state)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
    state = %{state | monitor_ref: nil}

    case reason do
      :shutdown -> emit_exhaustion(state, reason)
      {:shutdown, _term} -> emit_exhaustion(state, reason)
      _other -> :ok
    end

    {:noreply, schedule_resolve(state)}
  end

  # Not our monitor (stale ref after re-resolve); ignore.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp resolve(%{capacity: capacity} = state) do
    pid =
      cond do
        is_pid(capacity) and Process.alive?(capacity) -> capacity
        is_atom(capacity) -> Process.whereis(capacity)
        true -> nil
      end

    if is_pid(pid) do
      %{state | monitor_ref: Process.monitor(pid)}
    else
      schedule_resolve(state)
    end
  end

  defp schedule_resolve(state) do
    Process.send_after(self(), :resolve, @resolve_interval_ms)
    state
  end

  defp emit_exhaustion(%{capacity: capacity}, reason) do
    Logger.error(
      "Capacity supervisor #{inspect(capacity)} exhausted its restart intensity " <>
        "and is DOWN: capacity monitoring is disabled until an explicit " <>
        "operator restart or redeploy (exit reason: #{inspect(reason)})"
    )

    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      %{supervisor: capacity, reason: reason}
    )
  end
end
