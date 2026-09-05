defmodule Shoestring.Elves.DispatchEffect do
  @moduledoc """
  `Shoestring.Harness.Dispatch.Effect` implementation that delivers one
  durable dispatch attempt as a supervised Elf run.

  The Oban `DispatchWorker` calls `perform/2` only after
  `Dispatches.prepare_for_effect/2` has reconciled and claimed the dispatch,
  so this effect never launches blindly: it rebuilds the run request from the
  durable `RunRecord`, starts (or attaches to) the single Elf for the run, and
  waits for its terminal state.

  ## No local timers (locked decision)

  This effect waits for the Elf's terminal state with no timeout. A timer,
  expired lease, quiet heartbeat, or missing final response must never by
  itself interrupt, replace, or duplicate an Elf that may still be doing
  useful work (see `plans/milestones/04-single-elf.md`, locked decisions):
  cancellation may only come from an explicit user/orchestrator request
  (`Shoestring.Elves.cancel_dispatch/2`, `Shoestring.Elves.cancel_run/2`) or
  from Oban worker termination (the `{:EXIT, _, _}` path below), never from a
  local monitor interval. Suspected staleness is reported as evidence via
  `Shoestring.Elves.Staleness`, and the orchestrator decides.

  ## Oban cancellation

  Job cancellation alone is not a terminal run event. This effect traps exits
  while waiting so that worker shutdown (Oban timeout/cancel) terminates the
  owned process group through `Shoestring.Elves.cancel_run/2` before the
  worker dies. The reliable cancellation entrypoint remains explicit
  `cancel_dispatch`/`cancel_run` — the trap is best-effort cover for the
  shutdown path, documented honestly: a `:kill` exit cannot run cleanup, and
  recovery (`Shoestring.Elves.reconcile/2`) owns whatever remains.

  ## Configuration

  Effect options come from `Application.get_env(:shoestring, :elf_dispatch_opts)`
  merged with per-call opts (per-call wins): `:adapter`, `:scenario`,
  `:command`, `:env`, `:runner_opts`, `:supervisor`,
  `:clock`, `:repo`, `:event_interval_ms`. The `:scenario`/`:command` entries
  select the Fake scenario and the trivial OS command for hermetic runs; Work
  Package C replaces them with provider adapter selection.
  """

  @behaviour Shoestring.Harness.Dispatch.Effect

  alias Shoestring.Elves
  alias Shoestring.Harness.{DispatchRecord, RunRecord}

  @impl true
  @spec perform(RunRecord.t(), DispatchRecord.t()) :: :ok | {:ok, term()} | {:error, term()}
  def perform(%RunRecord{} = run, %DispatchRecord{} = dispatch, opts \\ []) do
    opts = Keyword.merge(Application.get_env(:shoestring, :elf_dispatch_opts, []), opts)
    repo = Keyword.get(opts, :repo, Shoestring.Repo)
    opts = Keyword.put(opts, :repo, repo)

    with {:ok, request} <- Elves.request_from_run(run) do
      wait_for_terminal(request, dispatch, run, opts)
    end
  end

  # -- Private helpers --

  defp wait_for_terminal(request, dispatch, run, opts) do
    Process.flag(:trap_exit, true)

    case Elves.start_elf(request, dispatch, opts) do
      {:ok, pid} ->
        monitor_elf(pid, run, opts)

      {:ok, :already_running, pid} ->
        monitor_elf(pid, run, opts)

      {:error, reason} ->
        {:error, {:elf_start_failed, reason}}
    end
  end

  # No `after` clause by design: only the Elf's terminal DOWN message or an
  # Oban worker shutdown EXIT may end this wait — never a local timer.
  defp monitor_elf(pid, run, opts) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        Process.demonitor(ref, [:flush])
        terminal_outcome(run, opts)

      {:EXIT, _from, reason} ->
        _ = Elves.cancel_run(run.id, opts)
        exit(reason)
    end
  end

  defp terminal_outcome(run, opts) do
    case Elves.terminal_of(run.id, opts) do
      {:ok, %{class: :completed}} -> :ok
      {:ok, %{class: :interrupted}} -> :ok
      {:ok, %{class: :cancelled}} -> :ok
      {:ok, %{class: :failed, payload: payload}} -> {:error, {:elf_failed, payload}}
      {:ok, nil} -> {:error, :elf_terminal_unknown}
      {:error, reason} -> {:error, reason}
    end
  end
end
