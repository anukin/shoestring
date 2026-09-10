defmodule Shoestring.Cobbler.WakeupObserve do
  @moduledoc """
  Production fresh-snapshot probe for `Shoestring.Cobbler.WakeupWorker`
  (loop-closure I4, P1; provider/scope binding W1).

  At wake time the worker must capacity re-probe through the real Observatory
  path — the durable `Shoestring.Harness.Observatory` ledger that the
  supervised capacity monitors keep ingested — instead of reusing the
  admission-time snapshot or a test `Fake` injection. `observe/1` takes the
  run's provider/scope identity (`%{provider_id: ..., scope: ...}`, atom or
  string keys) and returns the freshest ledger observation recorded FOR THAT
  provider/scope (ordered by provider `observed_at`, never by insertion
  order). It never falls back to another provider's snapshot: a wake
  admission decided on a foreign snapshot's allowance would be fail-open on
  deployment shape.

  Identity compared (exact string equality, both sides stringified):

  - snapshot `source.provider_id` vs scoping `provider_id`;
  - snapshot `scope` vs scoping `scope`.

  The snapshot `source.adapter_id` / `invocation_mode` are provenance, not
  quota identity: the newest observation wins across invocation modes for the
  same provider/scope. Defense in depth: `AdmissionEvaluation` additionally
  hard-stops (`snapshot_provider_mismatch`, unbypassable like
  `scope_mismatch`) when a handed snapshot's recorded provider/scope
  disagrees with the candidate's.

  Fail-closed contract (mirrors `Wakeups.perform_wakeup/2` observation
  handling):

  - empty ledger → `{:error, :no_observation}`;
  - ledger holds observations but none for this provider/scope →
    `{:error, :no_observation_for_provider}` (the intent stays due; the
    worker retries the delivery later);
  - ledger/read crash → `{:error, :observation_unavailable}`.

  Wired in `config/runtime.exs` for `:prod` only as the MFA tuple
  `{__MODULE__, :observe, []}` (MFA survives config evaluation; a raw fun
  capture does not belong in config): `WakeupWorker` appends the
  run/decision-derived scoping map to the MFA args at perform time, so the
  configured entry point is `observe/1`. Test and dev keep explicit
  `:observe` injection (arity 0 legacy or arity 1 scoped); the worker keeps
  its fail-closed `missing_observe_fun` default when nothing is configured.
  """

  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Harness.Observatory

  @epoch ~U[1970-01-01 00:00:00Z]

  @doc """
  Returns the freshest Observatory ledger observation recorded for the given
  provider/scope identity, or a fail-closed error when the ledger is empty,
  holds nothing for that identity, or is unreadable.
  """
  @spec observe(%{provider_id: String.t(), scope: String.t()}) ::
          {:ok, CapacitySnapshot.t()}
          | {:error, :no_observation | :no_observation_for_provider | :observation_unavailable}
  def observe(%{} = scoping) do
    provider_id = scoping_string(scoping, :provider_id)
    scope = scoping_string(scoping, :scope)

    case Observatory.latest_observations() do
      [] ->
        {:error, :no_observation}

      snapshots when is_list(snapshots) ->
        case Enum.filter(snapshots, &matches_identity?(&1, provider_id, scope)) do
          [] -> {:error, :no_observation_for_provider}
          matches -> {:ok, Enum.max_by(matches, &observed_at/1, DateTime)}
        end
    end
  rescue
    _error -> {:error, :observation_unavailable}
  catch
    _kind, _reason -> {:error, :observation_unavailable}
  end

  defp scoping_string(scoping, key) do
    value = Map.get(scoping, key, Map.get(scoping, to_string(key)))

    if is_nil(value), do: nil, else: to_string(value)
  end

  defp matches_identity?(%CapacitySnapshot{} = snapshot, provider_id, scope) do
    snapshot_provider(snapshot) == provider_id and snapshot_scope(snapshot) == scope and
      not is_nil(provider_id) and not is_nil(scope)
  end

  defp matches_identity?(_snapshot, _provider_id, _scope), do: false

  defp snapshot_provider(%CapacitySnapshot{source: %{provider_id: provider_id}}),
    do: to_string(provider_id)

  defp snapshot_provider(%CapacitySnapshot{source: %{"provider_id" => provider_id}}),
    do: to_string(provider_id)

  defp snapshot_provider(_snapshot), do: nil

  defp snapshot_scope(%CapacitySnapshot{scope: scope}) when is_binary(scope), do: scope

  defp snapshot_scope(%CapacitySnapshot{scope: scope}) when not is_nil(scope),
    do: to_string(scope)

  defp snapshot_scope(_snapshot), do: nil

  defp observed_at(%CapacitySnapshot{observed_at: %DateTime{} = at}), do: at
  defp observed_at(_snapshot), do: @epoch
end
