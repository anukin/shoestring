defmodule Shoestring.Elves.Watchdog do
  @moduledoc """
  Periodic evidence sweeps over live Elf runs.

  On every sweep the watchdog collects one `Staleness` evidence packet per
  candidate run and persists it to the trajectory. Collection is strictly
  read-only observation: findings deduplicate through the stable observation
  id, so repeated sweeps — across Oban retries and across application
  restarts — converge instead of spamming the trajectory.

  ## Evidence only, never action

  A timer firing, a quiet heartbeat, or a missing final response must never by
  itself interrupt, replace, or duplicate an Elf that may still be doing
  useful work. This module therefore only observes. Termination stays with the
  explicit human/orchestrator path, and replacement stays behind the
  orchestrator guard, which requires a terminal state or an explicit
  reconciliation first.

  ## Determinism

  Sweeps enumerate candidate runs from durable `RunRecord` state (bounded by
  `:limit`), oldest first, and collect with a fixed `:reason`
  (`"watchdog_sweep"` by default) so the observation id is stable for
  unchanged durable state. One run's failure never aborts the sweep: each
  result is reported per run.
  """

  use GenServer

  import Ecto.Query

  alias Shoestring.Elves.Staleness
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Repo

  @default_interval_ms 60_000
  @default_limit 100
  @default_reason "watchdog_sweep"
  @non_terminal_statuses [
    "requested",
    "starting",
    "running",
    "pausing",
    "suspended",
    "cancelling"
  ]

  @type sweep_result ::
          {:ok, :persisted | :duplicate, run_id :: Ecto.UUID.t()}
          | {:error, term(), Ecto.UUID.t()}

  @doc """
  Starts the watchdog sweep loop.

  ## Options

    * `:interval_ms` — milliseconds between sweeps (default 60 000).
    * `:reason` — staleness reason recorded on each packet.
    * `:limit` — maximum runs per sweep.
    * `:repo`, `:clock` — forwarded to `Staleness.collect/3`.
    * `:name` — GenServer registration (defaults to `__MODULE__`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc "Runs one sweep synchronously and returns the per-run results."
  @spec sweep(GenServer.server(), keyword()) :: [sweep_result()]
  def sweep(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:sweep, opts}, Keyword.get(opts, :timeout, 60_000))
  end

  @doc """
  Collects evidence for every candidate run without needing a live watchdog.
  Deterministic building block for the sweep loop and for tests.
  """
  @spec check_all(keyword()) :: [sweep_result()]
  def check_all(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    limit = Keyword.get(opts, :limit, @default_limit)
    opts = Keyword.put(opts, :repo, repo)

    opts
    |> run_ids(repo, limit)
    |> Enum.map(&check_run(&1, opts))
  end

  @doc "Collects evidence for one run. Read-only observation; never acts."
  @spec check_run(Ecto.UUID.t(), keyword()) :: sweep_result()
  def check_run(run_id, opts \\ []) do
    reason = Keyword.get(opts, :reason, @default_reason)

    case Staleness.collect(run_id, reason, opts) do
      {:ok, outcome, _event} -> {:ok, outcome, run_id}
      {:error, reason} -> {:error, reason, run_id}
    end
  rescue
    error -> {:error, error, run_id}
  catch
    kind, reason -> {:error, {kind, reason}, run_id}
  end

  @impl GenServer
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      reason: Keyword.get(opts, :reason, @default_reason),
      limit: Keyword.get(opts, :limit, @default_limit),
      repo: Keyword.get(opts, :repo, Repo),
      clock: Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
    }

    schedule(state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:sweep, call_opts}, _from, state) do
    opts =
      [reason: state.reason, limit: state.limit, repo: state.repo, clock: state.clock]
      |> Keyword.merge(call_opts)

    {:reply, check_all(opts), state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    _ =
      check_all(reason: state.reason, limit: state.limit, repo: state.repo, clock: state.clock)

    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp run_ids(opts, repo, limit) do
    statuses = Keyword.get(opts, :statuses, @non_terminal_statuses)

    repo.all(
      from run in RunRecord,
        where: run.status in ^statuses,
        order_by: [asc: run.inserted_at],
        limit: ^limit,
        select: run.id
    )
  rescue
    _error -> []
  end

  defp schedule(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end
end
