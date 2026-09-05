defmodule Shoestring.Elves.LeaseWatcher do
  @moduledoc """
  Polls one session's lease deadline and enforces the safe-boundary stop once.

  The watcher performs exactly one effect, through
  `Shoestring.Elves.LeaseBoundary.enforce/3`: after the deadline it requests
  the safe-boundary stop (the in-flight item still completes first) and then
  stops itself. While the deadline is in the future it only polls. It carries
  no other capability: it cannot terminate, replace, or duplicate anything,
  and explicit human/orchestrator action remains the only termination path.
  """

  use GenServer

  alias Shoestring.Elves.LeaseBoundary

  @default_interval_ms 1_000

  @doc """
  Starts watching `session` against `deadline`.

  ## Options

    * `:interval_ms` — poll cadence (default 1 000).
    * `:run_id` — forwarded for evidence recording on enforcement.
    * `:reason` — staleness reason override for the evidence packet.
    * `:now_fun` — zero-arity clock override for deterministic tests.
    * `:name` — GenServer registration (default: unregistered).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)

    case name do
      nil -> GenServer.start_link(__MODULE__, init_opts)
      name -> GenServer.start_link(__MODULE__, init_opts, name: name)
    end
  end

  @doc "Runs one deadline check synchronously."
  @spec check(GenServer.server(), keyword()) ::
          {:ok, :within_lease | :stop_requested} | {:error, term()}
  def check(server, opts \\ []) do
    GenServer.call(server, {:check, opts}, Keyword.get(opts, :timeout, 30_000))
  end

  @impl GenServer
  def init(opts) do
    state = %{
      session: Keyword.fetch!(opts, :session),
      deadline: Keyword.fetch!(opts, :deadline),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      run_id: Keyword.get(opts, :run_id),
      reason: Keyword.get(opts, :reason, "lease_expired"),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      enforce_opts:
        Keyword.take(opts, [:repo, :clock, :writer_opts, :dispatch_fun, :call_timeout])
    }

    schedule(state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:check, call_opts}, _from, state) do
    case do_check(state, call_opts) do
      {:ok, :stop_requested} = reply -> {:stop, :normal, reply, state}
      reply -> {:reply, reply, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    case do_check(state, []) do
      {:ok, :stop_requested} -> {:stop, :normal, state}
      _within_or_error -> {:noreply, schedule_next(state)}
    end
  end

  defp do_check(state, call_opts) do
    opts =
      [now: state.now_fun.(), reason: state.reason]
      |> Keyword.merge(state.enforce_opts)
      |> Keyword.merge(call_opts)
      |> maybe_put_run_id(state.run_id)

    LeaseBoundary.enforce(state.session, state.deadline, opts)
  end

  defp maybe_put_run_id(opts, nil), do: opts
  defp maybe_put_run_id(opts, run_id), do: Keyword.put(opts, :run_id, run_id)

  defp schedule_next(state) do
    schedule(state.interval_ms)
    state
  end

  defp schedule(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
