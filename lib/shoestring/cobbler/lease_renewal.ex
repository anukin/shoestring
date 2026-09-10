defmodule Shoestring.Cobbler.LeaseRenewal do
  @moduledoc """
  Lease renewal at the safe boundary (Milestone 05, work package C).

  On renewal-due or deadline, renewal proceeds only after the safe stop was
  already requested and the in-flight item reached its `item.completed`
  boundary:

  - `stop: :already_requested` is required. This module never requests a stop
    itself (no restop, no session handle, no timer): anything else returns
    `{:error, :safe_stop_not_requested}` before any event is appended.
  - `boundary: :item_completed` is required. Anything else returns
    `{:ok, :awaiting_boundary}` with zero appends — the caller waits for the
    boundary and retries.
  - The capacity snapshot is always fetched fresh through the caller-supplied
    `:observe` zero-arity function (`{:ok, snapshot} | {:error, reason}`).
    The admitted snapshot is never reused. A missing `:observe` fun or a
    failed observation fails closed into the expire path.
  - Re-evaluation uses `Shoestring.Cobbler.AdmissionEvaluation.evaluate/5`
    with an explicit `:now` and claim occupancy (`:occupancy`, default
    `false`). Request and candidate are reconstructed from the original
    admission decision so renewal judges the same intent/scope/candidate.

  Outcomes (appended through `Shoestring.Cobbler.Leases.transition/4`,
  `LeaseStateMachine`-validated):

  - `:admit` → `lease.renewed`, chained to the fresh `admitted_snapshot_id`
    via `Leases.chain_snapshot/3` (the `lease.renewed` payload carries only
    the grant id per the registry schema). A lease in `:active` is
    normalized through `lease.renewal_due` first so the audit trail shows
    due before renewed.
  - anything else → `lease.expired` → `lease.checkpoint_required`
    (transitions only — checkpoint contents are work package T3's; the
    ordering assumption is that T3 consumes `checkpoint_required` and writes
    the checkpoint before any further grant).

  Quota fast path: `handle_quota_refusal/3` re-observes and re-evaluates
  immediately on a Codex `:quota_refused` error (no stop/boundary wait — the
  provider already halted the turn) with zero spend: bound counters are never
  touched here (spend accounting lives in `Shoestring.Cobbler.LeaseBounds`).

  `LeaseWatcher`, `LeaseBoundary`, and session semantics are untouched.
  """

  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionEvaluation, AdmissionPolicy, Leases}
  alias Shoestring.Harness.{CapacitySnapshot, ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  @renewable_statuses ["active", "renewal_due", "renewed"]

  @type renew_result :: %{
          required(:outcome) => :renewed | :expired,
          required(:grant_id) => Ecto.UUID.t(),
          required(:decision) => AdmissionDecision.t() | nil,
          required(:events) => [TrajectoryEvent.t()],
          optional(:admitted_snapshot_id) => Ecto.UUID.t(),
          optional(:reason) => term()
        }

  @doc """
  Renews (or expires) a lease at the safe boundary.

  Options: `:repo`, `:now` (required `%DateTime{}`, explicit), `stop:`
  (`:already_requested` required), `:boundary` (`:item_completed` required),
  `:observe` (required zero-arity fresh-snapshot fun), `:policy` (default
  `AdmissionPolicy.default/0`), `:occupancy` (default `false`),
  `:writer_opts`.
  """
  @spec maybe_renew(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, renew_result() | :awaiting_boundary} | {:error, term()}
  def maybe_renew(goal_id, grant_id, opts \\ []) do
    with {:ok, lease, run} <- load(goal_id, grant_id, opts),
         :ok <- stop_requested(opts),
         :ok <- boundary_reached(opts) do
      resolve(goal_id, lease, run, opts)
    else
      {:awaiting_boundary} -> {:ok, :awaiting_boundary}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Immediate re-observe + re-evaluate on a Codex `:quota_refused` error.

  Skips the stop/boundary wait (the provider already halted the turn) and
  spends nothing. Options are the same as `maybe_renew/3` minus
  `:stop`/`:boundary`.
  """
  @spec handle_quota_refusal(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, renew_result()} | {:error, term()}
  def handle_quota_refusal(goal_id, grant_id, opts \\ []) do
    with {:ok, lease, run} <- load(goal_id, grant_id, opts) do
      resolve(goal_id, lease, run, opts)
    end
  end

  # ----------------------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------------------

  defp load(goal_id, grant_id, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(ExecutionLeaseRecord, grant_id) do
      nil ->
        {:error, {:lease_not_found, grant_id}}

      %ExecutionLeaseRecord{goal_id: ^goal_id} = lease ->
        if lease.status in @renewable_statuses do
          {:ok, lease, repo.get_by(RunRecord, id: lease.run_id, goal_id: goal_id)}
        else
          {:error, {:lease_not_renewable, lease.status}}
        end

      %ExecutionLeaseRecord{} ->
        {:error, {:lease_not_owned, grant_id}}
    end
  end

  defp stop_requested(opts) do
    if Keyword.get(opts, :stop) == :already_requested do
      :ok
    else
      {:error, :safe_stop_not_requested}
    end
  end

  defp boundary_reached(opts) do
    if Keyword.get(opts, :boundary) == :item_completed do
      :ok
    else
      {:awaiting_boundary}
    end
  end

  defp resolve(goal_id, lease, run, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, decision_event} <- admission_event(repo, lease),
         {:ok, decision} <- admission_decision(decision_event),
         {:ok, snapshot} <- observe(opts),
         {:ok, evaluation} <- evaluate(goal_id, lease, run, decision, snapshot, opts) do
      settle(goal_id, lease, evaluation, snapshot, opts)
    else
      {:error, {:observation_failed, _reason} = reason} ->
        expire_closed(goal_id, lease, nil, reason, opts)

      {:error, {:evaluation_failed, _reason} = reason} ->
        expire_closed(goal_id, lease, nil, reason, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp admission_event(repo, lease) do
    event_id = (lease.extensions || %{})["cobbler.lease:admission_event_id"]

    case repo.get(TrajectoryEvent, event_id) do
      %TrajectoryEvent{goal_id: goal_id} = event when goal_id == lease.goal_id -> {:ok, event}
      _other -> {:error, {:lease_invalid, :admission_event_not_found}}
    end
  end

  defp admission_decision(event) do
    case AdmissionDecision.from_payload(event.payload) do
      {:ok, decision} -> {:ok, decision}
      {:error, changeset} -> {:error, {:lease_invalid, changeset}}
    end
  end

  defp observe(opts) do
    case Keyword.fetch(opts, :observe) do
      {:ok, observe_fun} when is_function(observe_fun, 0) ->
        case observe_fun.() do
          {:ok, %CapacitySnapshot{} = snapshot} -> {:ok, snapshot}
          {:error, reason} -> {:error, {:observation_failed, reason}}
          _other -> {:error, {:observation_failed, :unexpected_observe_result}}
        end

      _missing ->
        {:error, {:observation_failed, :missing_observe_fun}}
    end
  end

  defp evaluate(goal_id, lease, run, decision, snapshot, opts) do
    policy = Keyword.get(opts, :policy, AdmissionPolicy.default())
    occupancy = Keyword.get(opts, :occupancy, false)

    case Keyword.fetch(opts, :now) do
      {:ok, %DateTime{} = _now} ->
        case AdmissionEvaluation.evaluate(
               renewal_request(goal_id, lease, run, decision),
               renewal_candidate(decision),
               snapshot,
               policy,
               now: Keyword.fetch!(opts, :now),
               occupancy: occupancy
             ) do
          {:ok, evaluation} -> {:ok, evaluation}
          {:error, reason} -> {:error, {:evaluation_failed, reason}}
        end

      _missing ->
        {:error, {:evaluation_failed, :missing_now}}
    end
  end

  defp renewal_request(goal_id, lease, run, decision) do
    %{
      requested_capability: decision.requested_capability,
      scope: decision.scope,
      goal_id: goal_id,
      task_id: task_id(run, lease),
      run_id: lease.run_id
    }
  end

  defp task_id(%RunRecord{task_id: task_id}, _lease), do: task_id
  defp task_id(_run, _lease), do: nil

  defp renewal_candidate(decision) do
    %{
      provider_id: decision.candidate.provider_id,
      adapter_id: decision.candidate.adapter_id,
      support_tier: decision.candidate.support_tier,
      compatibility_state: decision.candidate.compatibility_state,
      scope: decision.scope,
      capabilities: [decision.requested_capability]
    }
  end

  defp settle(goal_id, lease, %AdmissionDecision{result: :admit} = evaluation, snapshot, opts) do
    renew_opts = Keyword.put(opts, :from, :renewal_due)

    with {:ok, due_events} <- ensure_due(goal_id, lease, opts),
         {:ok, %{event: renewed}} <- Leases.transition(goal_id, lease.id, :renew, renew_opts),
         {:ok, _record} <- Leases.chain_snapshot(lease.id, snapshot.snapshot_id, opts) do
      {:ok,
       %{
         outcome: :renewed,
         grant_id: lease.id,
         decision: evaluation,
         events: due_events ++ [renewed],
         admitted_snapshot_id: snapshot.snapshot_id
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle(goal_id, lease, %AdmissionDecision{} = evaluation, _snapshot, opts) do
    expire_closed(goal_id, lease, evaluation, evaluation.reason_code, opts)
  end

  defp ensure_due(_goal_id, %ExecutionLeaseRecord{status: "renewal_due"}, _opts), do: {:ok, []}

  defp ensure_due(goal_id, %ExecutionLeaseRecord{status: status} = lease, opts)
       when status in ["active", "renewed"] do
    case Leases.transition(goal_id, lease.id, :renewal_due, opts) do
      {:ok, %{event: event}} -> {:ok, [event]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expire_closed(goal_id, lease, evaluation, reason, opts) do
    checkpoint_opts = Keyword.put(opts, :from, :expired)

    with {:ok, %{event: expired}} <- Leases.transition(goal_id, lease.id, :expire, opts),
         {:ok, %{event: checkpoint}} <-
           Leases.transition(goal_id, lease.id, :require_checkpoint, checkpoint_opts) do
      {:ok,
       %{
         outcome: :expired,
         grant_id: lease.id,
         decision: evaluation,
         events: [expired, checkpoint],
         reason: reason
       }}
    end
  end
end
