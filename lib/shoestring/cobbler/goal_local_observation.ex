defmodule Shoestring.Cobbler.GoalLocalObservation do
  @moduledoc """
  Goal-local identity for a capacity observation a Cobbler flow re-records
  under a work goal.

  ## Why this exists

  Three flows take a fresh capacity reading and re-append it as
  `capacity.snapshot_observed` under the WORK goal, because the lease they
  grant, renew or re-grant must chain to a snapshot its own goal owns — the
  locked "Strict Same-Goal Lease Ownership" rule that
  `Shoestring.Harness.Projector` enforces:

    * `Shoestring.Cobbler.Handoffs` (the receiver's fresh admission);
    * `Shoestring.Cobbler.LeaseRenewal` (the Elf's renewal at the safe
      boundary);
    * `Shoestring.Cobbler.Wakeups` (the durable wake's re-observation).

  In production the reading very often already has an owner. The handoff and
  wake probe (`Shoestring.Cobbler.WakeupObserve`) serves snapshots out of the
  `Shoestring.Harness.Observatory` ledger, and the Codex renewal probe
  (`CodexAppServer.probe/1` → `CodexMonitor.observe/1`) returns the reading the
  monitor has already ingested there. Every such snapshot is projected as a
  `CapacitySnapshotRecord` owned by the protected Observatory goal.
  Re-appending it under its ORIGINAL id made the projector find a row owned by
  another goal and fail with `{:capacity_snapshot_not_owned, id}`. The event
  is durable, so the work goal's `harness` projector was left `failed` and
  every later projection re-read the poisoned event: one renewal wedged the
  goal for good (live evidence: `plans/evidence/05-quota-aware-mvp/
  live-production-rerun.md` §3.2).

  ## The rule: re-identification, not relaxation

  Ownership is not weakened anywhere; the projector's check is untouched. The
  goal records its OWN observation of the same reading under an id derived
  from `(flow, goal_id, context_id, observed snapshot_id)`, where `context_id`
  is the flow's durable unit (the handoff id, the lease grant id, the wakeup
  id). Every field of the reading is preserved; only the identity is local.

    * **Deterministic.** The same flow context re-observing the same reading
      derives the same id, so a crash-retry collapses on the existing
      idempotency key instead of appending a second observation. Replay
      behaviour is exactly what it was for a reading nobody else owned.
    * **Unforgeably goal-local.** The id is a function of this goal and this
      context, so it can only ever name a row this goal owns. It cannot
      collide with the Observatory's row, another goal's, or another context's
      in the same goal.
    * **Provenance kept.** The observed id is recorded in the snapshot
      extensions under `cobbler.<flow>:observed_snapshot_id`, so the goal's
      timeline can be joined back to the ledger entry it came from. The
      Observatory's own row is never touched.

  A reading that is already goal-local (a fresh id nobody else owns) is
  re-identified by the same rule. Deriving unconditionally keeps one code
  path and one set of idempotency keys: a rule that fired only when a foreign
  row happened to exist would be a race, not an invariant.
  """

  alias Shoestring.Harness.CapacitySnapshot

  # Flow names are extension namespaces, so they follow
  # `Shoestring.Harness.Contract`'s namespace alphabet (`[a-z0-9.-]`).
  @flows ~w(handoff lease-renewal wakeup)

  @typedoc "The Cobbler flow re-recording the observation."
  @type flow :: String.t()

  @doc """
  Re-identifies `observed` as `goal_id`'s own observation for `flow` in
  `context_id`. Returns `{:ok, snapshot}`; anything but a
  `%CapacitySnapshot{}` is refused as `{:error, {:observation_failed, ...}}`
  so a broken probe contract fails closed instead of crashing mid-flight.
  """
  @spec localize(term(), flow(), Ecto.UUID.t(), String.t()) ::
          {:ok, CapacitySnapshot.t()} | {:error, {:observation_failed, term()}}
  def localize(%CapacitySnapshot{} = observed, flow, goal_id, context_id)
      when flow in @flows and is_binary(goal_id) and is_binary(context_id) do
    local_id = snapshot_id(flow, goal_id, context_id, observed.snapshot_id)

    extensions =
      (observed.extensions || %{})
      |> Map.put(provenance_key(flow), observed.snapshot_id)

    {:ok, %CapacitySnapshot{observed | snapshot_id: local_id, extensions: extensions}}
  end

  def localize(other, _flow, _goal_id, _context_id),
    do: {:error, {:observation_failed, {:unexpected_observe_result, other}}}

  @doc "The snapshot-extension key that carries the observed (source) snapshot id."
  @spec provenance_key(flow()) :: String.t()
  def provenance_key(flow) when flow in @flows, do: "cobbler.#{flow}:observed_snapshot_id"

  @doc """
  The goal-local snapshot id `localize/4` derives: a UUIDv5-shaped digest of
  the identities, formatted with the RFC 4122 version and variant bits so it
  is a well-formed UUID that `Ecto.UUID.cast/1` — which the projector runs on
  the payload — accepts. The `handoff` preimage is byte-identical to the one
  #79 shipped, so a handoff replayed across this change derives the same id.
  """
  @spec snapshot_id(flow(), Ecto.UUID.t(), String.t(), String.t()) :: Ecto.UUID.t()
  def snapshot_id(flow, goal_id, context_id, observed_snapshot_id) when flow in @flows do
    <<head::binary-size(6), version_byte::8, mid::binary-size(1), variant_byte::8,
      tail::binary-size(7), _discard::binary>> =
      :crypto.hash(
        :sha256,
        "#{flow}-observation:#{goal_id}:#{context_id}:#{observed_snapshot_id}"
      )

    raw =
      head <>
        <<Bitwise.bor(0x50, Bitwise.band(version_byte, 0x0F))>> <>
        mid <>
        <<Bitwise.bor(0x80, Bitwise.band(variant_byte, 0x3F))>> <>
        tail

    {:ok, uuid} = Ecto.UUID.load(raw)
    uuid
  end
end
