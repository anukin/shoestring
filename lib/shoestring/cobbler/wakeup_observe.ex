defmodule Shoestring.Cobbler.WakeupObserve do
  @moduledoc """
  Production fresh-snapshot probe for `Shoestring.Cobbler.WakeupWorker`
  (loop-closure I4, P1).

  At wake time the worker must capacity re-probe through the real Observatory
  path — the durable `Shoestring.Harness.Observatory` ledger that the
  supervised capacity monitors keep ingested — instead of reusing the
  admission-time snapshot or a test `Fake` injection. `observe/0` returns the
  freshest ledger observation across provider/mode/scope targets (ordered by
  provider `observed_at`, never by insertion order).

  Fail-closed contract (mirrors `Wakeups.perform_wakeup/2` observation
  handling):

  - empty ledger → `{:error, :no_observation}` (the intent stays due; the
    worker retries the delivery later);
  - ledger/read crash → `{:error, :observation_unavailable}`.

  Scope note (honest limitation): with several scopes ingested, the freshest
  reading may belong to a different scope than the wake's candidate. The
  downstream `AdmissionEvaluation` still judges freshness, capacity state,
  reserves, and claim occupancy before any `:admit`, and a stale or
  mismatched reading can only defer, require confirmation, or reject — never
  silently admit. Scope-pinned selection is future work, not this slice.

  Wired in `config/runtime.exs` for `:prod` only as the MFA tuple
  `{__MODULE__, :observe, []}` (MFA survives config evaluation; a raw fun
  capture does not belong in config). Test and dev keep explicit `:observe`
  injection; the worker keeps its fail-closed `missing_observe_fun` default
  when nothing is configured.
  """

  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Harness.Observatory

  @epoch ~U[1970-01-01 00:00:00Z]

  @doc """
  Returns the freshest Observatory ledger observation, or a fail-closed
  error when the ledger is empty or unreadable.
  """
  @spec observe() ::
          {:ok, CapacitySnapshot.t()} | {:error, :no_observation | :observation_unavailable}
  def observe do
    case Observatory.latest_observations() do
      [] ->
        {:error, :no_observation}

      snapshots when is_list(snapshots) ->
        {:ok, Enum.max_by(snapshots, &observed_at/1, DateTime)}
    end
  rescue
    _error -> {:error, :observation_unavailable}
  catch
    _kind, _reason -> {:error, :observation_unavailable}
  end

  defp observed_at(%CapacitySnapshot{observed_at: %DateTime{} = at}), do: at
  defp observed_at(_snapshot), do: @epoch
end
