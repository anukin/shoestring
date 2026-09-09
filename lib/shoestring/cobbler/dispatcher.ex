defmodule Shoestring.Cobbler.Dispatcher do
  @moduledoc """
  First gated dispatch consumer for durable Cobbler commands.

  The consumer reads `cobbler_commands` rows, re-validates the admission
  reference, confirms the exclusive claim is still live and owned by the
  goal, and then dispatches through the durable dispatch pipeline:

  ## Claim + grant + dispatch pipeline (P1)

  After claim and grant, work starts ONLY through
  `Shoestring.Harness.Dispatches.enqueue_for_run/2` (dispatch record + Oban
  job + `dispatch.requested` event), never a direct `Elves.start_run` — intent
  (command + claim + run row + grant) is durable before any delivery exists.
  The Oban `DispatchWorker` performs the effect after
  `Dispatches.prepare_for_effect/2` claims it; the one-Elf invariant is the
  SQLite-enforced exclusive claim (a second concurrent dispatch is refused by
  the claim, visibly, with no second enforcement mechanism).

  Opt-in lease issuance: pass `grant_lease: [...]` (see
  `Shoestring.Cobbler.Leases.issue_for_claim/6`; requires `:task_id`) to
  issue an execution lease on the validated-claim path and enqueue its
  durable delivery. Without the option the consumer stops at the explicit
  execution-disabled boundary below.

  ## Execution-disabled boundary (no `grant_lease:`)

  Submitting, validating, and gating commands never spawns a process,
  enqueues a job, or starts an Elf. A command that is fully validated
  (`resolved` + `claimed` + live owned claim + valid admission reference)
  returns `{:error, {:execution_disabled, detail}}` instead of executing.
  `detail` carries the `goal_id`, `command_id`, `claim_id`, and
  `admission_event_id` that a future enabled execution path must consume, so
  the boundary is explicit and auditable rather than a silent no-op.

  ## Ungated paths are rejected, not bypassed

  `dispatch/3` refuses any command row that is not a live, owned, claimed
  outcome with `{:error, {:no_claimed_command, detail}}`. Direct run paths
  can opt into the same protection via
  `Shoestring.Cobbler.DispatchGate.authorize/2`
  (`require_cobbler_command: true` on `Dispatches.enqueue/3` and
  `Elves.start_run/3`).

  ## Replay and conflict preservation

  The consumer submits through `Shoestring.Cobbler.Commands.submit/3`, so
  identical re-submission replays the recorded outcome (and re-gates it)
  while conflicting reuse of a command id is rejected as
  `{:command_conflict, ...}` — exactly the store semantics, never rewritten
  here.
  """

  alias Shoestring.Cobbler.{Command, Commands, Leases}
  alias Shoestring.Cobbler.CommandRecord
  alias Shoestring.Harness.Dispatches
  alias Shoestring.Repo

  @type gate_result ::
          {:ok,
           %{
             required(:command) => CommandRecord.t(),
             required(:outcome) => :recorded | :replayed,
             required(:disposition) => :awaiting_operator | :command_rejected | :leased,
             required(:detail) => map()
           }}
          | {:ok,
             %{
               required(:command) => CommandRecord.t(),
               required(:outcome) => :recorded | :replayed,
               required(:disposition) => :leased,
               required(:lease_outcome) => :recorded | :replayed,
               required(:run) => Shoestring.Harness.RunRecord.t() | nil,
               required(:lease) => Shoestring.Harness.ExecutionLease.t(),
               required(:grant_id) => Ecto.UUID.t(),
               required(:events) => [Shoestring.Trajectory.TrajectoryEvent.t()],
               required(:claim_id) => Ecto.UUID.t(),
               required(:admission_event_id) => Ecto.UUID.t(),
               required(:dispatch) => Shoestring.Harness.DispatchRecord.t() | nil,
               required(:job) => Oban.Job.t() | nil
             }}
          | {:error, term()}

  @doc """
  Submits a command (performing the exclusive claim atomically in the store)
  and gates its dispatch.

  - `resolved` + `claimed` with `grant_lease:` → `{:ok, %{disposition:
    :leased, ...}}`: the grant is persisted first (WP C), then durable
    delivery is enqueued through `Dispatches.enqueue_for_run/2` (dispatch
    record + Oban job + `dispatch.requested`), never a direct
    `Elves.start_run`. Replays (`lease_outcome: :replayed`) create zero new
    rows and carry `dispatch: nil, job: nil`.
  - `resolved` + `claimed` without `grant_lease:` → `{:error,
    {:execution_disabled, detail}}`.
  - `needs_user` → `{:ok, %{disposition: :awaiting_operator, ...}}`; the
    command stays inert until an operator responds.
  - `rejected` → `{:ok, %{disposition: :command_rejected, ...}}`.
  - Identical re-submission replays (`outcome: :replayed`) and re-gates;
    conflicting reuse returns `{:error, {:command_conflict, ...}}`.

  Opt-in lease issuance: pass `grant_lease: [...]` (see
  `Shoestring.Cobbler.Leases.issue_for_claim/6`; requires `:task_id`) to
  issue an execution lease on the validated-claim path. Without the option
  the behavior is byte-for-byte the execution-disabled boundary above;
  `require_cobbler_command` handling elsewhere is unchanged.
  """
  @spec claim_and_gate(Ecto.UUID.t(), map(), keyword()) :: gate_result()
  def claim_and_gate(goal_id, attrs, opts \\ []) do
    case Commands.submit(goal_id, attrs, opts) do
      {:ok, %{command: command, outcome: outcome}} ->
        gate_recorded(command, outcome, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gates dispatch for an already-recorded command row.

  Returns `{:error, {:execution_disabled, detail}}` only when the row is a
  `resolved` + `claimed` outcome whose claim is still live and owned by the
  goal and whose admission reference still validates. Anything else returns
  `{:error, {:no_claimed_command, detail}}` (or `:command_not_found` when
  the row does not exist). Never spawns, enqueues, or executes.
  """
  @spec dispatch(Ecto.UUID.t(), String.t(), keyword()) ::
          {:error, term()}
  def dispatch(goal_id, command_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case Commands.get(goal_id, command_id, repo: repo) do
      nil ->
        {:error, :command_not_found}

      %CommandRecord{} = row ->
        # `dispatch/3` never issues leases: the post-claim hook is a
        # `claim_and_gate/3` opt-in only, so `grant_lease:` is stripped here
        # and gating keeps its exact execution-disabled semantics.
        gate_recorded(row, :recorded, Keyword.delete(opts, :grant_lease))
        |> case do
          {:error, {:execution_disabled, _detail} = gated} ->
            {:error, gated}

          {:error, reason} ->
            {:error, reason}

          {:ok, %{disposition: disposition, detail: detail}} ->
            {:error, {:no_claimed_command, Map.put(detail, :disposition, disposition)}}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Gating
  # ----------------------------------------------------------------------------

  defp gate_recorded(
         %CommandRecord{status: "resolved", result: %{"kind" => "claimed"}} = row,
         outcome,
         opts
       ) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, command} <- rebuild_command(row),
         {:ok, _decision} <- admission_reference(repo, row, command),
         {:ok, claim} <- live_owned_claim(repo, row) do
      maybe_grant_lease(row, command, claim, outcome, opts)
    end
  end

  defp gate_recorded(%CommandRecord{status: "needs_user", result: result} = row, outcome, _opts) do
    {:ok,
     %{
       command: row,
       outcome: outcome,
       disposition: :awaiting_operator,
       detail: %{reason: result["reason"], options: result["options"]}
     }}
  end

  defp gate_recorded(%CommandRecord{status: "rejected", result: result} = row, outcome, _opts) do
    {:ok,
     %{
       command: row,
       outcome: outcome,
       disposition: :command_rejected,
       detail: %{reason: result["reason"]}
     }}
  end

  defp gate_recorded(%CommandRecord{status: status, result: result} = row, outcome, _opts) do
    {:ok,
     %{
       command: row,
       outcome: outcome,
       disposition: :command_rejected,
       detail: %{status: status, kind: result["kind"]}
     }}
  end

  # ----------------------------------------------------------------------------
  # Post-claim lease hook (opt-in delegation only)
  # ----------------------------------------------------------------------------

  # Without `grant_lease:` opts the validated claim stops at the explicit
  # execution-disabled boundary, exactly as before. With the option, issuance
  # delegates to `Shoestring.Cobbler.Leases.issue_for_claim/6` (persisting
  # the run row and the grant first), and the granted run is then delivered
  # through the durable dispatch pipeline (`Dispatches.enqueue_for_run/2`:
  # dispatch record + Oban job + `dispatch.requested`), never a direct
  # `Elves.start_run` — intent before dispatch. This private hook adds no
  # evaluation or effects of its own.
  defp maybe_grant_lease(row, command, claim, outcome, opts) do
    case Keyword.fetch(opts, :grant_lease) do
      :error ->
        {:error,
         {:execution_disabled,
          %{
            boundary: "execution_disabled",
            goal_id: row.goal_id,
            command_id: row.command_id,
            outcome: outcome,
            claim_id: claim.id,
            admission_event_id: row.payload["admission_event_id"]
          }}}

      {:ok, lease_opts} when is_list(lease_opts) ->
        with {:ok, leased} <-
               Leases.issue_for_claim(row.goal_id, row, command, claim, outcome, lease_opts) do
          dispatch_granted(leased, opts)
        end
    end
  end

  # Enqueues durable delivery for a freshly granted run. Replays carry
  # `run: nil` (zero new rows by contract) and pass through with
  # `dispatch: nil, job: nil` rather than inventing delivery.
  defp dispatch_granted(%{run: nil} = leased, _opts) do
    {:ok, Map.merge(leased, %{dispatch: nil, job: nil})}
  end

  defp dispatch_granted(
         %{run: %Shoestring.Harness.RunRecord{} = run} = leased,
         opts
       ) do
    dispatch_opts = Keyword.take(opts, [:repo, :clock, :writer_opts])

    case Dispatches.enqueue_for_run(run, dispatch_opts) do
      {:ok, dispatch, job} ->
        {:ok, Map.merge(leased, %{dispatch: dispatch, job: job})}

      {:error, reason} ->
        {:error,
         {:dispatch_failed,
          %{
            goal_id: run.goal_id,
            run_id: run.id,
            grant_id: leased.grant_id,
            reason: reason
          }}}
    end
  end

  defp rebuild_command(%CommandRecord{} = row) do
    attrs = %{
      "version" => row.version,
      "command_id" => row.command_id,
      "type" => row.type,
      "payload" => row.payload
    }

    case Command.new(attrs) do
      {:ok, %Command{digest: digest} = command} ->
        if digest == row.digest do
          {:ok, command}
        else
          {:error,
           {:no_claimed_command, %{reason: :command_digest_mismatch, command_id: row.command_id}}}
        end

      {:error, changeset} ->
        {:error,
         {:no_claimed_command,
          %{reason: :command_invalid, command_id: row.command_id, detail: changeset}}}
    end
  end

  defp admission_reference(repo, row, command) do
    case Commands.validate_admission_reference(repo, row.goal_id, command) do
      {:ok, decision} ->
        {:ok, decision}

      {:rejected, reason} ->
        {:error,
         {:no_claimed_command,
          %{
            reason: :admission_reference_invalid,
            admission_reason: reason,
            command_id: row.command_id
          }}}
    end
  end

  defp live_owned_claim(repo, row) do
    case Commands.active_claim(repo: repo) do
      %{goal_id: goal_id, command_id: command_id} = claim
      when goal_id == row.goal_id and command_id == row.command_id ->
        {:ok, claim}

      %{} = claim ->
        {:error,
         {:no_claimed_command,
          %{
            reason: :claim_not_held,
            command_id: row.command_id,
            holder_goal_id: claim.goal_id
          }}}

      nil ->
        {:error, {:no_claimed_command, %{reason: :no_active_claim, command_id: row.command_id}}}
    end
  end
end
