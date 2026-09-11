defmodule Shoestring.Cobbler.Leases do
  @moduledoc """
  Transactional execution-lease store (Milestone 05, work package C).

  The Cobbler accountant for leases: a context (no new process) that persists
  `lease.*` trajectory transitions and relies on the harness projector for
  `harness_execution_leases` rows. Every transition is pre-validated through
  `Shoestring.Harness.LeaseStateMachine`, payloads are built with
  `Shoestring.Harness.EventPayload.execution_lease/1`, and contracts with
  `Shoestring.Harness.ExecutionLease.new/1`.

  Ordering contract (D2): the run row is created via `Shoestring.Harness.Runs`
  before any grant append (`persist_lease :propose` requires the run row and
  the same-goal admitted snapshot row, otherwise projection fails with
  `{:lease_dependency_not_found, grant_id}`).

  Replay protection (D1): `grant/3` looks up an existing grant for
  `(goal_id, admission decision_id)` and returns it with `outcome: :replayed`
  and no new events. `issue_for_claim/6` checks replay before creating the
  run row, so replays create zero rows. A refused grant creates zero rows:
  the pure `Shoestring.Cobbler.LeaseGrant.build/5` check runs against a
  provisional run id before `Runs.request/3` is called.

  `LeaseWatcher`, `LeaseBoundary`, and session semantics are untouched.
  """

  import Ecto.Query

  alias Shoestring.Cobbler.{AdmissionDecision, Command, CommandRecord, LeaseGrant}
  alias Shoestring.Harness.{EventPayload, ExecutionLease, Fake, LeaseStateMachine, RunRequest}
  alias Shoestring.Harness.{ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Harness.Runs
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @actor "cobbler"
  @schema_version 1

  @transition_types %{
    renewal_due: "lease.renewal_due",
    renew: "lease.renewed",
    expire: "lease.expired",
    revoke: "lease.revoked",
    require_checkpoint: "lease.checkpoint_required"
  }

  @type grant_result :: %{
          required(:grant_id) => Ecto.UUID.t(),
          required(:outcome) => :recorded | :replayed,
          required(:events) => [TrajectoryEvent.t()],
          required(:lease) => ExecutionLease.t()
        }

  @doc """
  Persists `lease.proposed → lease.granted → lease.active` for a built lease.

  Returns `{:ok, grant_result()}` with `outcome: :replayed` (no new events)
  when a grant already exists for the same `(goal_id, admission decision_id)`.
  The lookup reads canonical `lease.proposed` events first, so replays are
  recognized even before projection runs; projected rows are the fallback.
  """
  @spec grant(Ecto.UUID.t(), ExecutionLease.t(), keyword()) ::
          {:ok, grant_result()} | {:error, term()}
  def grant(goal_id, %ExecutionLease{} = lease, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case replay_grant(repo, goal_id, decision_id(lease)) do
      {:ok, %{grant_id: grant_id, lease: existing}} ->
        {:ok, %{grant_id: grant_id, outcome: :replayed, events: [], lease: existing}}

      :fresh ->
        record_grant(goal_id, lease, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns the lease row for a grant id, or nil."
  @spec get(module(), Ecto.UUID.t()) :: ExecutionLeaseRecord.t() | nil
  def get(repo \\ Repo, grant_id), do: repo.get(ExecutionLeaseRecord, grant_id)

  @doc """
  Looks up the existing grant for `(goal_id, admission decision_id)`.

  Linear scan over the goal's leases; acceptable for the MVP single-claim
  regime and documented as such.
  """
  @spec find_by_decision(module(), Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          ExecutionLeaseRecord.t() | nil
  def find_by_decision(_repo, _goal_id, nil), do: nil

  def find_by_decision(repo, goal_id, decision_id) do
    repo.all(
      from lease in ExecutionLeaseRecord,
        where: lease.goal_id == ^goal_id,
        order_by: [asc: lease.inserted_at, asc: lease.id]
    )
    |> Enum.find(fn lease ->
      extensions(lease)["cobbler.lease:admission_decision_id"] == decision_id
    end)
  end

  # Canonical replay source: the first `lease.proposed` event carrying the
  # decision ref. Events are committed synchronously by the trajectory writer,
  # so this recognizes replays even before projection has run. Projected rows
  # are the fallback for history written by other means.
  # Returns `{:ok, %{grant_id, lease}}`, `:fresh`, or `{:error, reason}`.
  defp replay_grant(_repo, _goal_id, nil), do: :fresh

  defp replay_grant(repo, goal_id, decision_id) do
    case proposed_event(repo, goal_id, decision_id) do
      %TrajectoryEvent{payload: payload} ->
        case lease_from_payload(payload) do
          {:ok, lease} -> {:ok, %{grant_id: payload["grant_id"], lease: lease}}
          {:error, reason} -> {:error, {:lease_invalid, reason}}
        end

      nil ->
        case find_by_decision(repo, goal_id, decision_id) do
          %ExecutionLeaseRecord{} = record ->
            {:ok, %{grant_id: record.id, lease: from_record!(record)}}

          nil ->
            :fresh
        end
    end
  end

  defp proposed_event(repo, goal_id, decision_id) do
    repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == "lease.proposed",
        order_by: [asc: event.sequence]
    )
    |> Enum.find(fn event ->
      get_in(event.payload, ["extensions", "cobbler.lease:admission_decision_id"]) == decision_id
    end)
  end

  defp lease_from_payload(payload) when is_map(payload) do
    ExecutionLease.new(%{
      version: payload["contract_version"],
      grant_id: payload["grant_id"],
      run_id: payload["run_id"],
      admitted_snapshot_id: payload["admitted_snapshot_id"],
      reserves: %{
        response: get_in(payload, ["reserves", "response"]),
        tool: get_in(payload, ["reserves", "tool"])
      },
      response_budget: payload["response_budget"],
      tool_budget: payload["tool_budget"],
      deadline: payload["deadline"],
      checkpoint_cadence: payload["checkpoint_cadence"],
      renewal_state: renewal_state(payload["renewal_state"]),
      extensions: payload["extensions"] || %{}
    })
  end

  defp renewal_state(state) when is_binary(state) do
    String.to_existing_atom(state)
  rescue
    ArgumentError -> state
  end

  defp renewal_state(state), do: state

  @doc """
  Appends one lease lifecycle transition after `LeaseStateMachine`
  pre-validation against the stored status.

  `action` is one of `:renewal_due | :renew | :expire | :revoke |
  :require_checkpoint`. Returns `{:ok, %{event: event, state: state}}`.

  Chained appends within one flow pass `:from` with the logical predecessor
  state (projection lags appends, so the stored row still shows the older
  status until `Projector.project/2` runs).
  """
  @spec transition(Ecto.UUID.t(), Ecto.UUID.t(), atom(), keyword()) ::
          {:ok, %{event: TrajectoryEvent.t(), state: atom()}} | {:error, term()}
  def transition(goal_id, grant_id, action, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, type} <- transition_type(action),
         %ExecutionLeaseRecord{} = lease <-
           repo.get(ExecutionLeaseRecord, grant_id) || {:error, {:lease_not_found, grant_id}},
         true <- lease.goal_id == goal_id || {:error, {:lease_not_owned, grant_id}},
         {:ok, valid} <- validate_transition(lease, action, opts),
         {:ok, event} <-
           append(goal_id, lease.run_id, type, %{"grant_id" => grant_id}, grant_id, opts) do
      {:ok, %{event: event, state: valid.state}}
    else
      false -> {:error, {:lease_not_owned, grant_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_transition(lease, action, opts) do
    current = Keyword.get(opts, :from, String.to_atom(lease.status))
    LeaseStateMachine.transition(current, action)
  end

  @doc """
  Re-chains a (renewed) lease row to its fresh admitted snapshot.

  The `lease.renewed` event carries only the grant id (registry schema), so
  the snapshot chain is updated on the row after the transition appends.
  The fresh snapshot row must already be projected (`Projector.project/2`)
  before chaining; otherwise the foreign key fails and the error is returned
  explicitly. Events are canonical: on a chain-update failure the transitions
  stand and the caller must project the snapshot, then retry
  `chain_snapshot/3` (never swallowed).
  """
  @spec chain_snapshot(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ExecutionLeaseRecord.t()} | {:error, term()}
  def chain_snapshot(grant_id, snapshot_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(ExecutionLeaseRecord, grant_id) do
      nil ->
        {:error, {:lease_not_found, grant_id}}

      %ExecutionLeaseRecord{} = lease ->
        lease
        |> Ecto.Changeset.change(%{admitted_snapshot_id: snapshot_id})
        |> Ecto.Changeset.foreign_key_constraint(:admitted_snapshot_id,
          name: :harness_execution_leases_admitted_snapshot_id_fkey
        )
        |> repo.update()
    end
  end

  @doc """
  Post-claim lease issuance for the dispatcher hook.

  Loads the admission event referenced by the claimed command, short-circuits
  replays (zero new rows, `run: nil`), builds the pure grant against a
  provisional run id (refusals create zero rows), creates the run row via
  `Runs.request/3`, then persists the grant. Returns:

  - `{:ok, %{command:, outcome:, disposition: :leased, lease_outcome:,
    run:, lease:, grant_id:, events:, claim_id:, admission_event_id:}}`
  - `{:error, {:lease_refused, detail}}` when the decision does not admit
  - `{:error, {:lease_run_failed, reason}}` when the run row cannot be created
  - `{:error, {:lease_append_failed, type, reason}}` when a grant append fails

  `opts` (all under the dispatcher's `:grant_lease` key): `:task_id`
  (required), `:identity` (default `Fake.identity/0` — hermetic, never a
  provider CLI), `:dispatch_id`, `:run_id`, `:workspace_ref`, `:prompt`,
  `:policy`, `:requested_capabilities`, `:grant_id`, `:now`, `:clock`,
  `:identifier`, `:repo`, `:writer_opts`.
  """
  @spec issue_for_claim(Ecto.UUID.t(), CommandRecord.t(), Command.t(), map(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def issue_for_claim(
        goal_id,
        %CommandRecord{} = row,
        %Command{} = command,
        claim,
        outcome,
        opts \\ []
      ) do
    repo = Keyword.get(opts, :repo, Repo)
    event_id = row.payload["admission_event_id"]

    with {:ok, event} <- claim_event(repo, goal_id, event_id),
         {:ok, decision} <- issue_decision(event) do
      case issue_replay(goal_id, row, claim, outcome, event_id, decision, repo) do
        {:replay, result} -> {:ok, result}
        {:ok, :fresh} -> issue_fresh(goal_id, row, command, claim, outcome, event, decision, opts)
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Private: grant path
  # ----------------------------------------------------------------------------

  defp record_grant(goal_id, %ExecutionLease{} = lease, opts) do
    with {:ok, _valid} <- LeaseStateMachine.transition(:proposed, :propose),
         {:ok, proposed} <-
           append(
             goal_id,
             lease.run_id,
             "lease.proposed",
             EventPayload.execution_lease(lease),
             lease.grant_id,
             Keyword.put(opts, :idempotency_key, "lease-proposed:#{lease.grant_id}")
           ),
         {:ok, granted} <-
           append(
             goal_id,
             lease.run_id,
             "lease.granted",
             %{"grant_id" => lease.grant_id},
             lease.grant_id,
             opts
           ),
         {:ok, active} <-
           append(
             goal_id,
             lease.run_id,
             "lease.active",
             %{"grant_id" => lease.grant_id},
             lease.grant_id,
             opts
           ) do
      {:ok,
       %{
         grant_id: lease.grant_id,
         outcome: :recorded,
         events: [proposed, granted, active],
         lease: lease
       }}
    end
  end

  defp append(goal_id, run_id, type, payload, grant_id, opts) do
    key = Keyword.get(opts, :idempotency_key, default_key(type, grant_id))

    attrs = %{
      "type" => type,
      "schema_version" => @schema_version,
      "actor" => @actor,
      "occurred_at" => now(opts),
      "idempotency_key" => key,
      "payload" => payload
    }

    case Trajectory.append(goal_id, attrs,
           trusted: [run_id: run_id],
           writer_opts: Keyword.get(opts, :writer_opts, [])
         ) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, {:lease_append_failed, type, reason}}
    end
  end

  defp default_key("lease.proposed", grant_id), do: "lease-proposed:#{grant_id}"
  defp default_key("lease.granted", grant_id), do: "lease-granted:#{grant_id}"
  defp default_key("lease.active", grant_id), do: "lease-active:#{grant_id}"
  defp default_key("lease.renewal_due", grant_id), do: "lease-renewal-due:#{grant_id}"
  defp default_key("lease.renewed", grant_id), do: "lease-renewed:#{grant_id}"
  defp default_key("lease.expired", grant_id), do: "lease-expired:#{grant_id}"
  defp default_key("lease.revoked", grant_id), do: "lease-revoked:#{grant_id}"

  defp default_key("lease.checkpoint_required", grant_id),
    do: "lease-checkpoint-required:#{grant_id}"

  defp transition_type(action) do
    case Map.fetch(@transition_types, action) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, {:unknown_lease_action, action}}
    end
  end

  defp decision_id(%ExecutionLease{extensions: extensions}) do
    extensions["cobbler.lease:admission_decision_id"]
  end

  defp extensions(%ExecutionLeaseRecord{extensions: nil}), do: %{}
  defp extensions(%ExecutionLeaseRecord{extensions: extensions}), do: extensions

  defp from_record!(%ExecutionLeaseRecord{} = record) do
    attrs = %{
      version: record.contract_version,
      grant_id: record.id,
      run_id: record.run_id,
      admitted_snapshot_id: record.admitted_snapshot_id,
      reserves: %{response: record.response_reserve, tool: record.tool_reserve},
      response_budget: record.response_budget,
      tool_budget: record.tool_budget,
      deadline: record.deadline,
      checkpoint_cadence: record.checkpoint_cadence,
      renewal_state: String.to_existing_atom(record.renewal_state),
      extensions: extensions(record)
    }

    case ExecutionLease.new(attrs) do
      {:ok, lease} ->
        lease

      {:error, changeset} ->
        raise "stored lease #{record.id} fails contract: #{inspect(changeset.errors)}"
    end
  end

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> DateTime.truncate(now, :microsecond)
      _other -> DateTime.truncate(DateTime.utc_now(), :microsecond)
    end
  end

  # ----------------------------------------------------------------------------
  # Private: issue_for_claim path
  # ----------------------------------------------------------------------------

  defp claim_event(repo, goal_id, event_id) do
    case repo.get(TrajectoryEvent, event_id) do
      %TrajectoryEvent{goal_id: ^goal_id} = event ->
        {:ok, event}

      _other ->
        {:error,
         {:lease_refused, %{reason: "admission_event_not_found", admission_event_id: event_id}}}
    end
  end

  defp issue_decision(event) do
    case AdmissionDecision.from_payload(event.payload) do
      {:ok, decision} ->
        {:ok, decision}

      {:error, _changeset} ->
        {:error,
         {:lease_refused, %{reason: "admission_decision_invalid", admission_event_id: event.id}}}
    end
  end

  defp issue_replay(goal_id, row, claim, outcome, event_id, decision, repo) do
    case replay_grant(repo, goal_id, decision.decision_id) do
      :fresh ->
        {:ok, :fresh}

      {:error, reason} ->
        {:error, reason}

      {:ok, %{grant_id: grant_id, lease: lease}} ->
        {:replay,
         %{
           command: row,
           outcome: outcome,
           disposition: :leased,
           lease_outcome: :replayed,
           run: nil,
           lease: lease,
           grant_id: grant_id,
           events: [],
           claim_id: claim.id,
           admission_event_id: event_id
         }}
    end
  end

  defp issue_fresh(goal_id, row, command, claim, outcome, event, decision, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    run_id = Keyword.get(opts, :run_id, Ecto.UUID.generate())

    with {:ok, request} <- issue_request(goal_id, decision, opts),
         {:ok, lease} <-
           LeaseGrant.build(
             goal_id,
             run_id,
             event,
             command,
             Keyword.merge(opts,
               repo: repo,
               grant_id: Keyword.get(opts, :grant_id, Ecto.UUID.generate())
             )
           ),
         {:ok, run} <- issue_run(request, run_id, opts),
         {:ok, granted} <- grant(goal_id, lease, opts) do
      {:ok,
       %{
         command: row,
         outcome: outcome,
         disposition: :leased,
         lease_outcome: granted.outcome,
         run: run,
         lease: granted.lease,
         grant_id: granted.grant_id,
         events: granted.events,
         claim_id: claim.id,
         admission_event_id: event.id
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_request(goal_id, decision, opts) do
    with {:ok, task_id} <- issue_task_id(opts) do
      attrs = %{
        version: 1,
        goal_id: goal_id,
        task_id: task_id,
        workspace_ref: Keyword.get(opts, :workspace_ref, "cobbler/lease"),
        prompt:
          Keyword.get(
            opts,
            :prompt,
            "Cobbler leased execution (#{decision.requested_capability})"
          ),
        continuation: nil,
        policy: Keyword.get(opts, :policy, %{mode: "supervised"}),
        requested_capabilities: Keyword.get(opts, :requested_capabilities, []),
        dispatch_id: Keyword.get(opts, :dispatch_id, Ecto.UUID.generate()),
        extensions: Keyword.get(opts, :extensions, %{})
      }

      case RunRequest.new(attrs) do
        {:ok, request} -> {:ok, request}
        {:error, changeset} -> {:error, {:lease_run_failed, changeset}}
      end
    end
  end

  defp issue_task_id(opts) do
    case Keyword.fetch(opts, :task_id) do
      {:ok, task_id} -> {:ok, task_id}
      :error -> {:error, {:lease_invalid, :missing_task_id}}
    end
  end

  defp issue_run(request, run_id, opts) do
    identity = Keyword.get(opts, :identity, Fake.identity())

    run_opts =
      opts
      |> Keyword.take([:repo, :clock, :identifier, :writer_opts])
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put_new(:clock, Shoestring.Harness.SystemClock)

    case Runs.request(request, identity, run_opts) do
      {:ok, %RunRecord{} = run} -> {:ok, run}
      {:error, reason} -> {:error, {:lease_run_failed, reason}}
    end
  end
end
