defmodule Shoestring.Cobbler do
  @moduledoc """
  Cobbler: Quota-aware admission evaluation, deterministic reserve policies,
  durable admission decision persistence, and the durable command/state/replay
  foundation.

  In Milestone 05 (quota-aware MVP foundation), Cobbler evaluates admission
  requests deterministically against capacity observations, candidate capabilities,
  explicit occupancy evidence, and operator confirmations, persisting durable
  `admission.decided` trajectory events without activating automatic dispatch.

  The command foundation adds durable, goal-scoped command ids with identical
  replay / conflicting-reuse semantics, a validated command state machine with
  recoverable `needs_user` outcomes, an atomic intent/transition/result store,
  trajectory rebuild, and a SQLite-enforced exclusive global MVP task claim.
  The first gated dispatch consumer (`Shoestring.Cobbler.Dispatcher`) reads
  command rows, re-validates admission references and claim ownership, and
  stops at an explicit execution-disabled boundary: nothing is spawned or
  enqueued. Direct run paths accept an opt-in `require_cobbler_command: true`
  guard (`Shoestring.Cobbler.DispatchGate`) that rejects dispatches for
  goals holding no live claim instead of bypassing commands.
  """

  alias Shoestring.Cobbler.{
    AdmissionDecision,
    AdmissionEvaluation,
    AdmissionPolicy,
    Commands,
    DispatchGate,
    Dispatcher,
    GoalLifecycle,
    LeaseBounds,
    LeaseGrant,
    LeaseRenewal,
    Leases
  }

  alias Shoestring.Harness.CapacitySnapshot

  @doc """
  Evaluates admission for a single candidate provider deterministically.

  Requires explicit `:now` DateTime in `opts`.
  """
  @spec evaluate_admission(
          map(),
          map(),
          CapacitySnapshot.t() | map() | nil,
          AdmissionPolicy.t() | nil,
          keyword()
        ) :: {:ok, AdmissionDecision.t()} | {:error, term()}
  def evaluate_admission(request, candidate, snapshot, policy \\ nil, opts \\ []) do
    AdmissionEvaluation.evaluate(request, candidate, snapshot, policy, opts)
  end

  @doc """
  Evaluates admission across multiple candidate providers in deterministic priority order.
  """
  @spec evaluate_candidates(
          map(),
          [map()],
          map(),
          AdmissionPolicy.t() | nil,
          keyword()
        ) ::
          {:ok, %{selected: AdmissionDecision.t(), all: [AdmissionDecision.t()]}}
          | {:error, term()}
  def evaluate_candidates(request, candidates, snapshots_map, policy \\ nil, opts \\ []) do
    AdmissionEvaluation.evaluate_candidates(request, candidates, snapshots_map, policy, opts)
  end

  @doc "Returns the default admission policy."
  @spec default_policy() :: AdmissionPolicy.t()
  def default_policy, do: AdmissionPolicy.default()

  @doc """
  Records a durable command outcome for a goal-scoped command id.

  Identical replay returns the original result without events; conflicting
  reuse of the same command id is rejected. Commands are record-only and
  never execute anything.
  """
  @spec submit_command(Ecto.UUID.t(), map(), keyword()) ::
          {:ok,
           %{
             command: Shoestring.Cobbler.CommandRecord.t(),
             outcome: :recorded | :replayed,
             events: [Shoestring.Trajectory.TrajectoryEvent.t()]
           }}
          | {:error, term()}
  def submit_command(goal_id, attrs, opts \\ []) do
    Commands.submit(goal_id, attrs, opts)
  end

  @doc "Resolves a recoverable `needs_user` command with a validated operator response."
  @spec respond_command(Ecto.UUID.t(), String.t(), map(), keyword()) ::
          {:ok,
           %{
             command: Shoestring.Cobbler.CommandRecord.t(),
             outcome: :recorded | :replayed,
             events: [Shoestring.Trajectory.TrajectoryEvent.t()]
           }}
          | {:error, term()}
  def respond_command(goal_id, command_id, response_attrs, opts \\ []) do
    Commands.respond(goal_id, command_id, response_attrs, opts)
  end

  @doc "Returns the command row for a goal-scoped command id, or nil."
  @spec command(Ecto.UUID.t(), String.t(), keyword()) ::
          Shoestring.Cobbler.CommandRecord.t() | nil
  def command(goal_id, command_id, opts \\ []) do
    Commands.get(goal_id, command_id, opts)
  end

  @doc "Lists command rows for a goal in insertion order."
  @spec list_commands(Ecto.UUID.t(), keyword()) :: [Shoestring.Cobbler.CommandRecord.t()]
  def list_commands(goal_id, opts \\ []) do
    Commands.list(goal_id, opts)
  end

  @doc "Lists pending operator decisions (`needs_user` commands) for a goal."
  @spec pending_commands(Ecto.UUID.t(), keyword()) :: [Shoestring.Cobbler.CommandRecord.t()]
  def pending_commands(goal_id, opts \\ []) do
    Commands.pending(goal_id, opts)
  end

  @doc "Returns the single active global task claim, or nil."
  @spec active_claim(keyword()) :: Shoestring.Cobbler.TaskClaimRecord.t() | nil
  def active_claim(opts \\ []) do
    Commands.active_claim(opts)
  end

  @doc "Rebuilds command and claim state from canonical events; reports divergence."
  @spec rebuild_commands(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             commands: [map()],
             claim: map() | nil,
             consistent?: boolean(),
             divergences: [String.t()]
           }}
          | {:error, term()}
  def rebuild_commands(goal_id, opts \\ []) do
    Commands.rebuild(goal_id, opts)
  end

  @doc "Applies one goal lifecycle event to a goal state (pure; see `GoalLifecycle`)."
  @spec lifecycle_transition(GoalLifecycle.state(), GoalLifecycle.event()) ::
          {:ok, GoalLifecycle.state()} | {:error, term()}
  def lifecycle_transition(state, event) do
    GoalLifecycle.transition(state, event)
  end

  @doc """
  Submits a command and gates its dispatch through the first gated consumer.

  A fully validated claim stops at the explicit execution-disabled boundary
  (`{:error, {:execution_disabled, detail}}`); nothing is spawned or
  enqueued. Identical replays re-gate; conflicting reuse is rejected.
  """
  @spec claim_and_gate(Ecto.UUID.t(), map(), keyword()) :: Dispatcher.gate_result()
  def claim_and_gate(goal_id, attrs, opts \\ []) do
    Dispatcher.claim_and_gate(goal_id, attrs, opts)
  end

  @doc """
  Gates dispatch for an already-recorded command row.

  Only a live, owned, claimed outcome with a valid admission reference
  reaches the execution-disabled boundary; anything else is rejected as
  `{:error, {:no_claimed_command, detail}}`.
  """
  @spec dispatch_command(Ecto.UUID.t(), String.t(), keyword()) :: {:error, term()}
  def dispatch_command(goal_id, command_id, opts \\ []) do
    Dispatcher.dispatch(goal_id, command_id, opts)
  end

  @doc """
  Verifies that a goal holds the exclusive global task claim (read-only).
  """
  @spec authorize_dispatch(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def authorize_dispatch(goal_id, opts \\ []) do
    DispatchGate.authorize(goal_id, opts)
  end

  @doc """
  Builds a pure execution-lease grant from an admitted decision event.

  See `Shoestring.Cobbler.LeaseGrant.build/5`.
  """
  @spec build_lease_grant(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Shoestring.Trajectory.TrajectoryEvent.t(),
          Shoestring.Cobbler.Command.t(),
          keyword()
        ) ::
          {:ok, Shoestring.Harness.ExecutionLease.t()} | {:error, term()}
  def build_lease_grant(goal_id, run_id, event, command, opts \\ []) do
    LeaseGrant.build(goal_id, run_id, event, command, opts)
  end

  @doc """
  Persists `lease.proposed → lease.granted → lease.active` for a built lease.

  See `Shoestring.Cobbler.Leases.grant/3`.
  """
  @spec grant_lease(Ecto.UUID.t(), Shoestring.Harness.ExecutionLease.t(), keyword()) ::
          {:ok, Leases.grant_result()} | {:error, term()}
  def grant_lease(goal_id, lease, opts \\ []) do
    Leases.grant(goal_id, lease, opts)
  end

  @doc """
  Renews (or expires) a lease at the safe boundary.

  See `Shoestring.Cobbler.LeaseRenewal.maybe_renew/3`.
  """
  @spec renew_lease(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, LeaseRenewal.renew_result() | :awaiting_boundary} | {:error, term()}
  def renew_lease(goal_id, grant_id, opts \\ []) do
    LeaseRenewal.maybe_renew(goal_id, grant_id, opts)
  end

  @doc """
  Immediate re-observe + re-evaluate on a Codex `:quota_refused` error.

  See `Shoestring.Cobbler.LeaseRenewal.handle_quota_refusal/3`.
  """
  @spec handle_lease_quota(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, LeaseRenewal.renew_result()} | {:error, term()}
  def handle_lease_quota(goal_id, grant_id, opts \\ []) do
    LeaseRenewal.handle_quota_refusal(goal_id, grant_id, opts)
  end

  @doc """
  Builds bound state for a granted lease.

  See `Shoestring.Cobbler.LeaseBounds.new/1`.
  """
  @spec lease_bounds(Shoestring.Harness.ExecutionLease.t() | map()) :: LeaseBounds.t()
  def lease_bounds(lease) do
    LeaseBounds.new(lease)
  end
end
