defmodule Shoestring.Cobbler.Plans do
  @moduledoc """
  Durable, goal-scoped plan revisions and human approval decisions.

  This is the domain entrypoint. Nothing here needs a LiveView, a socket, or
  a running process: a goal can be planned, edited, approved, rejected,
  read, and rebuilt from events entirely through this module, which is what
  lets the eventual UI be a view over the domain rather than the place the
  domain lives.

  ## Boundary semantics

  - **Immutable revisions.** `propose/3` is the only way content enters.
    Editing a plan proposes the NEXT revision with the edited one as its
    parent; no call rewrites a stored revision's content or digest.
  - **Identical replay, conflicting reuse.** A proposal carries a
    goal-scoped `proposal_id`; a decision carries a goal-scoped
    `decision_id`. Re-sending the same id with the same digest returns the
    original row and appends no events. The same id with different content
    is a conflict, never a silent overwrite.
  - **Approval binds a revision AND a digest.** An approval names the
    revision number and the exact content digest it was taken against. A
    digest that does not match the stored revision is stale and is refused,
    so an operator cannot authorize content they never saw.
  - **Human decisions only.** Authors and deciders are `human:`-prefixed
    identities. A planner may be recorded inside the plan as provenance,
    but it cannot author a revision and cannot approve one.
  - **One authority at a time.** A partial unique index allows at most one
    `approved` revision per goal, and a unique index allows at most one
    decision per revision. Two concurrent approvals cannot both commit:
    the loser's whole transaction rolls back on the index, not on a
    read-then-write race.
  - **Supersession is inert.** Approving a newer revision moves the older
    approved revision to `superseded`. That removes its future authority
    and does nothing else: it enqueues nothing, cancels nothing, and
    interrupts nothing. Work already running keeps running; stopping it is
    a separate, explicit decision that this slice does not make.
  - **Approved task identities persist.** A revision that descends from a
    goal whose plan was ever approved must still contain every task id that
    approved lineage introduced. A task that has an identity in approved
    history cannot be made to vanish by editing the plan.
  - **Events are the authority.** `rebuild/2` recomputes revisions,
    decisions, and the active authority purely from canonical
    `cobbler.plan.*` events and reports divergence from stored rows without
    mutating anything.
  - **Contention is a structured outcome.** If SQLite refuses the write
    lock, the whole transaction rolled back and the caller gets
    `{:error, {:database_busy, message}}` rather than an exception. The
    same `proposal_id` or `decision_id` may simply be retried; idempotency
    makes the retry converge.
  - **Proposals are inert.** Nothing in this module spawns a process,
    enqueues a job, grants a lease, observes capacity, or dispatches. A
    proposed plan sits there until a human decides on it, and an approved
    plan sits there until a later execution package reads it.

  ## Not in this slice

  Execution, dispatch, model planning, and amendment orchestration are
  deliberately absent. Two obligations follow for those packages and are
  stated here so they are not rediscovered later:

  1. **Dispatch must bind the authority.** A dispatch has to re-read the
     approved revision and its digest at dispatch time and refuse if the
     authority moved. Holding a revision struct from earlier is not enough.
  2. **Amendment needs a retirement path.** Because this slice refuses to
     drop a task id from approved lineage, a genuine scope reduction has no
     representation yet. The amendment package must add an explicit,
     approval-gated retirement that records why an approved task identity
     is being retired, rather than relaxing the retention rule.

  ## Event appends inside the store transaction

  Like `Shoestring.Cobbler.Commands`, this store constructs trusted event
  identity and sequence fields itself, inside the same immediate write
  transaction as the rows, rather than calling the per-goal
  `Shoestring.Trajectory.Writer` (a separate transaction that would
  deadlock against this one). Payload validation still goes through
  `Shoestring.Trajectory.EventRegistry.validate_payload/4`, which
  re-validates the whole plan contract on every write.
  """

  import Ecto.Query
  require Logger

  alias Shoestring.Cobbler.{PlanContract, PlanDecisionRecord, PlanRevisionRecord}
  alias Shoestring.Harness.Contract
  alias Shoestring.Repo
  alias Shoestring.Trajectory.Goal
  alias Shoestring.Trajectory.{EventRegistry, TrajectoryEvent}

  @actor "cobbler"
  @schema_version 1

  @event_types [
    "cobbler.plan.revision.created",
    "cobbler.plan.approved",
    "cobbler.plan.rejected"
  ]

  @human_identity_pattern ~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,126}\z/
  @max_reason_length 500
  @max_note_length 500

  @type propose_result :: %{
          required(:revision) => PlanRevisionRecord.t(),
          required(:outcome) => :recorded | :replayed,
          required(:events) => [TrajectoryEvent.t()]
        }

  @type decision_result :: %{
          required(:revision) => PlanRevisionRecord.t(),
          required(:decision) => PlanDecisionRecord.t(),
          required(:superseded) => PlanRevisionRecord.t() | nil,
          required(:outcome) => :recorded | :replayed,
          required(:events) => [TrajectoryEvent.t()]
        }

  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  # ----------------------------------------------------------------------------
  # Proposing and editing
  # ----------------------------------------------------------------------------

  @doc """
  Records a new immutable plan revision for a goal.

  `attrs` carries `proposal_id`, `plan`, `authored_by`, and — for every
  revision after the first — `parent_revision_number`. The first revision
  of a goal must not name a parent; every later one must, so the edit
  lineage is durable rather than inferred from numbering.
  """
  @spec propose(Ecto.UUID.t(), map(), keyword()) :: {:ok, propose_result()} | {:error, term()}
  def propose(goal_id, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, proposal_id} <- identifier(attrs, :proposal_id),
         {:ok, authored_by} <- human_identity(attrs, :authored_by),
         {:ok, parent} <- optional_revision_number(attrs, :parent_revision_number),
         {:ok, contract} <- plan_contract(attrs),
         :ok <- ensure_goal(repo, goal_id) do
      repo
      |> run_transaction(fn ->
        propose_transaction(repo, goal_id, proposal_id, authored_by, parent, contract, now(opts))
      end)
      |> publish_result(opts)
    end
  end

  defp propose_transaction(repo, goal_id, proposal_id, authored_by, parent, contract, now) do
    case existing_revision_by_proposal(repo, goal_id, proposal_id) do
      %PlanRevisionRecord{digest: digest} = existing when digest == contract.digest ->
        %{revision: existing, outcome: :replayed, events: []}

      %PlanRevisionRecord{} = existing ->
        repo.rollback(
          {:plan_proposal_conflict,
           %{
             "proposal_id" => proposal_id,
             "existing_digest" => existing.digest,
             "incoming_digest" => contract.digest
           }}
        )

      nil ->
        record_revision(repo, goal_id, proposal_id, authored_by, parent, contract, now)
    end
  end

  defp record_revision(repo, goal_id, proposal_id, authored_by, parent, contract, now) do
    revision_number = next_revision_number(repo, goal_id)

    :ok = check_parent(repo, goal_id, parent, revision_number)
    :ok = check_retained_task_identities(repo, goal_id, contract)

    revision =
      goal_id
      |> PlanRevisionRecord.insert_changeset(
        proposal_id,
        contract,
        revision_number,
        parent,
        authored_by,
        now
      )
      |> repo.insert()
      |> case do
        {:ok, row} -> row
        {:error, changeset} -> repo.rollback({:plan_revision_insert_failed, changeset})
      end

    events =
      append_events(repo, goal_id, [revision_created_event(revision, contract)], now)

    %{revision: revision, outcome: :recorded, events: events}
  end

  # The first revision of a goal stands alone; every later one must name the
  # revision it was edited from, and that parent must belong to this goal.
  defp check_parent(_repo, _goal_id, nil, 1), do: :ok

  defp check_parent(repo, _goal_id, parent, 1) when is_integer(parent),
    do: repo.rollback({:plan_parent_not_found, %{"parent_revision_number" => parent}})

  defp check_parent(repo, _goal_id, nil, revision_number),
    do: repo.rollback({:plan_parent_required, %{"revision_number" => revision_number}})

  defp check_parent(repo, goal_id, parent, _revision_number) do
    if repo.exists?(
         from revision in PlanRevisionRecord,
           where: revision.goal_id == ^goal_id and revision.revision_number == ^parent
       ) do
      :ok
    else
      repo.rollback({:plan_parent_not_found, %{"parent_revision_number" => parent}})
    end
  end

  # Task identities that approved history introduced are stable facts. An
  # edit may change a task's outcome, dependencies, gates, or checkpoint,
  # but it may not make the identity disappear — otherwise completed work
  # would lose the id its evidence was recorded against. Retiring an
  # approved task is a real need and deliberately has no representation
  # here; see the module doc.
  defp check_retained_task_identities(repo, goal_id, contract) do
    approved_ids = approved_lineage_task_ids(repo, goal_id)
    proposed_ids = MapSet.new(PlanContract.task_ids(contract))

    case MapSet.difference(approved_ids, proposed_ids) |> MapSet.to_list() |> Enum.sort() do
      [] ->
        :ok

      missing ->
        repo.rollback({:approved_task_identity_dropped, %{"missing" => missing}})
    end
  end

  defp approved_lineage_task_ids(repo, goal_id) do
    repo.all(
      from revision in PlanRevisionRecord,
        where:
          revision.goal_id == ^goal_id and
            revision.status in ["approved", "superseded"],
        select: revision.content
    )
    |> Enum.flat_map(fn content -> Enum.map(content["tasks"], & &1["id"]) end)
    |> MapSet.new()
  end

  # ----------------------------------------------------------------------------
  # Decisions
  # ----------------------------------------------------------------------------

  @doc """
  Approves one exact plan revision at one exact content digest.

  `attrs` carries `decision_id`, `revision_number`, `digest`, `decided_by`,
  and an optional bounded `note`. A digest that does not match the stored
  revision, a revision that already has a decision, or a revision older
  than the one currently holding authority are all refused.
  """
  @spec approve(Ecto.UUID.t(), map(), keyword()) :: {:ok, decision_result()} | {:error, term()}
  def approve(goal_id, attrs, opts \\ []), do: decide(goal_id, attrs, "approve", opts)

  @doc """
  Rejects one exact plan revision at one exact content digest.

  `attrs` carries `decision_id`, `revision_number`, `digest`, `decided_by`,
  and a required bounded `reason`.
  """
  @spec reject(Ecto.UUID.t(), map(), keyword()) :: {:ok, decision_result()} | {:error, term()}
  def reject(goal_id, attrs, opts \\ []), do: decide(goal_id, attrs, "reject", opts)

  defp decide(goal_id, attrs, kind, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, decision} <- decision_attrs(attrs, kind),
         :ok <- ensure_goal(repo, goal_id) do
      repo
      |> run_transaction(fn -> decide_transaction(repo, goal_id, decision, now(opts)) end)
      |> publish_result(opts)
    end
  end

  defp decide_transaction(repo, goal_id, decision, now) do
    case existing_decision(repo, goal_id, decision.decision_id) do
      %PlanDecisionRecord{} = existing ->
        replay_decision(repo, goal_id, existing, decision)

      nil ->
        record_decision(repo, goal_id, decision, now)
    end
  end

  # A replayed decision must agree on all three bindings. Agreeing on the id
  # alone would let a second, different decision ride in on a retried
  # request.
  defp replay_decision(repo, goal_id, existing, decision) do
    if existing.kind == decision.kind and
         existing.revision_number == decision.revision_number and
         existing.bound_digest == decision.digest do
      %{
        revision: fetch_revision!(repo, goal_id, decision.revision_number),
        decision: existing,
        superseded: nil,
        outcome: :replayed,
        events: []
      }
    else
      repo.rollback(
        {:plan_decision_conflict,
         %{
           "decision_id" => decision.decision_id,
           "existing" => %{
             "kind" => existing.kind,
             "revision_number" => existing.revision_number,
             "digest" => existing.bound_digest
           },
           "incoming" => %{
             "kind" => decision.kind,
             "revision_number" => decision.revision_number,
             "digest" => decision.digest
           }
         }}
      )
    end
  end

  defp record_decision(repo, goal_id, decision, now) do
    revision = load_decidable_revision(repo, goal_id, decision)
    superseded = supersede_for(repo, goal_id, decision, revision, now)

    decision_row =
      goal_id
      |> PlanDecisionRecord.insert_changeset(revision, decision, now)
      |> repo.insert()
      |> case do
        {:ok, row} -> row
        {:error, changeset} -> repo.rollback({:plan_decision_insert_failed, changeset})
      end

    next_status = if decision.kind == "approve", do: "approved", else: "rejected"

    decided_revision =
      revision
      |> PlanRevisionRecord.status_changeset(next_status, now)
      |> repo.update()
      |> case do
        {:ok, row} -> row
        {:error, changeset} -> repo.rollback({:plan_revision_status_failed, changeset})
      end

    events =
      append_events(
        repo,
        goal_id,
        [decision_event(decision, decided_revision, superseded, now)],
        now
      )

    %{
      revision: decided_revision,
      decision: decision_row,
      superseded: superseded,
      outcome: :recorded,
      events: events
    }
  end

  # Cross-goal references die here: the lookup is goal-scoped, so a revision
  # number that exists under a different goal is simply not found.
  defp load_decidable_revision(repo, goal_id, decision) do
    case get_revision_row(repo, goal_id, decision.revision_number) do
      nil ->
        repo.rollback(
          {:plan_revision_not_found, %{"revision_number" => decision.revision_number}}
        )

      %PlanRevisionRecord{digest: digest} = revision when digest == decision.digest ->
        if revision.status == "proposed" do
          revision
        else
          repo.rollback(
            {:plan_revision_not_pending,
             %{"revision_number" => revision.revision_number, "status" => revision.status}}
          )
        end

      %PlanRevisionRecord{} = revision ->
        repo.rollback(
          {:plan_digest_mismatch,
           %{
             "revision_number" => revision.revision_number,
             "expected" => revision.digest,
             "provided" => decision.digest
           }}
        )
    end
  end

  defp supersede_for(_repo, _goal_id, %{kind: "reject"}, _revision, _now), do: nil

  defp supersede_for(repo, goal_id, _decision, revision, now) do
    case approved_revision_row(repo, goal_id) do
      nil ->
        nil

      %PlanRevisionRecord{revision_number: approved} when approved > revision.revision_number ->
        repo.rollback(
          {:plan_revision_stale,
           %{
             "approved_revision_number" => approved,
             "requested_revision_number" => revision.revision_number
           }}
        )

      %PlanRevisionRecord{} = current ->
        current
        |> PlanRevisionRecord.status_changeset("superseded", now)
        |> repo.update()
        |> case do
          {:ok, row} -> row
          {:error, changeset} -> repo.rollback({:plan_supersede_failed, changeset})
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Reads
  # ----------------------------------------------------------------------------

  @doc "Returns one revision row for a goal, or nil."
  @spec get_revision(Ecto.UUID.t(), pos_integer(), keyword()) :: PlanRevisionRecord.t() | nil
  def get_revision(goal_id, revision_number, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case cast_goal_id(goal_id) do
      {:ok, goal_id} -> get_revision_row(repo, goal_id, revision_number)
      {:error, _reason} -> nil
    end
  end

  @doc "Lists every revision for a goal in revision order."
  @spec list_revisions(Ecto.UUID.t(), keyword()) :: [PlanRevisionRecord.t()]
  def list_revisions(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case cast_goal_id(goal_id) do
      {:ok, goal_id} ->
        repo.all(
          from revision in PlanRevisionRecord,
            where: revision.goal_id == ^goal_id,
            order_by: [asc: revision.revision_number]
        )

      {:error, _reason} ->
        []
    end
  end

  @doc "Lists every decision for a goal in decision order."
  @spec list_decisions(Ecto.UUID.t(), keyword()) :: [PlanDecisionRecord.t()]
  def list_decisions(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case cast_goal_id(goal_id) do
      {:ok, goal_id} ->
        repo.all(
          from decision in PlanDecisionRecord,
            where: decision.goal_id == ^goal_id,
            order_by: [asc: decision.revision_number, asc: decision.inserted_at]
        )

      {:error, _reason} ->
        []
    end
  end

  @doc """
  The one revision currently holding authority for a goal, or nil.

  Only an `approved` revision is authority. A proposed revision has not been
  decided, a rejected one was refused, and a superseded one has been
  displaced — none of them can authorize anything.
  """
  @spec authority(Ecto.UUID.t(), keyword()) ::
          %{
            revision: PlanRevisionRecord.t(),
            digest: String.t(),
            revision_number: pos_integer(),
            ordered_task_ids: [String.t()]
          }
          | nil
  def authority(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         %PlanRevisionRecord{} = revision <- approved_revision_row(repo, goal_id),
         {:ok, contract} <- PlanContract.new(revision.content) do
      %{
        revision: revision,
        digest: revision.digest,
        revision_number: revision.revision_number,
        ordered_task_ids: contract.ordered_task_ids
      }
    else
      _other -> nil
    end
  end

  # ----------------------------------------------------------------------------
  # Rebuild from canonical events
  # ----------------------------------------------------------------------------

  @doc """
  Recomputes plan state purely from canonical `cobbler.plan.*` events.

  Returns revisions, decisions, the active authority, and any divergence
  from stored rows. This reads and compares; it never writes, so a
  divergence is reported rather than papered over.
  """
  @spec rebuild(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             revisions: [map()],
             decisions: [map()],
             authority: map() | nil,
             consistent?: boolean(),
             divergences: [String.t()]
           }}
          | {:error, term()}
  def rebuild(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         events <- fetch_plan_events(repo, goal_id),
         :ok <- validate_history(events),
         {:ok, state} <- fold_events(events) do
      revisions = state.revisions |> Map.values() |> Enum.sort_by(& &1["revision_number"])
      decisions = state.decisions |> Enum.sort_by(& &1["revision_number"])
      authority = Enum.find(revisions, &(&1["status"] == "approved"))

      divergences =
        divergences(revisions, decisions, authority, goal_id, opts)

      {:ok,
       %{
         revisions: revisions,
         decisions: decisions,
         authority: authority,
         consistent?: divergences == [],
         divergences: divergences
       }}
    end
  end

  defp fetch_plan_events(repo, goal_id) do
    repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type in @event_types,
        order_by: [asc: event.sequence]
    )
  end

  defp validate_history(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case EventRegistry.validate(event_attributes(event)) do
        {:ok, _validated} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp fold_events(events) do
    Enum.reduce_while(events, {:ok, %{revisions: %{}, decisions: []}}, fn event, {:ok, state} ->
      case fold_event(state, event) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fold_event(state, %TrajectoryEvent{type: "cobbler.plan.revision.created"} = event) do
    payload = event.payload
    number = payload["revision_number"]

    # Re-deriving the contract from the stored canonical rendering is the
    # point of replay: the digest below is computed, not copied, so a
    # rebuilt authority proves its content rather than restating it.
    case PlanContract.from_canonical_json(payload["plan_content"]) do
      {:ok, contract} ->
        revision = %{
          "revision_number" => number,
          "proposal_id" => payload["proposal_id"],
          "parent_revision_number" => payload["parent_revision_number"],
          "plan_version" => payload["plan_version"],
          "digest" => contract.digest,
          "declared_digest" => payload["plan_digest"],
          "content" => contract.content,
          "ordered_task_ids" => contract.ordered_task_ids,
          "authored_by" => payload["authored_by"],
          "author_kind" => payload["author_kind"],
          "status" => "proposed"
        }

        {:ok, put_in(state, [:revisions, number], revision)}

      {:error, reason} ->
        {:error, {:rebuild_plan_invalid, event.sequence, reason}}
    end
  end

  defp fold_event(state, %TrajectoryEvent{type: "cobbler.plan.approved"} = event) do
    payload = event.payload

    with {:ok, state} <- transition_revision(state, payload["revision_number"], "approved", event),
         {:ok, state} <- maybe_supersede(state, payload["superseded_revision_number"], event) do
      {:ok, %{state | decisions: state.decisions ++ [rebuilt_decision(payload, "approve")]}}
    end
  end

  defp fold_event(state, %TrajectoryEvent{type: "cobbler.plan.rejected"} = event) do
    payload = event.payload

    with {:ok, state} <- transition_revision(state, payload["revision_number"], "rejected", event) do
      {:ok, %{state | decisions: state.decisions ++ [rebuilt_decision(payload, "reject")]}}
    end
  end

  defp transition_revision(state, number, status, event) do
    case Map.fetch(state.revisions, number) do
      {:ok, %{"status" => "proposed"} = revision} ->
        {:ok, put_in(state, [:revisions, number], Map.put(revision, "status", status))}

      {:ok, %{"status" => current}} ->
        {:error, {:rebuild_revision_not_pending, event.sequence, number, current}}

      :error ->
        {:error, {:rebuild_decision_without_revision, event.sequence, number}}
    end
  end

  defp maybe_supersede(state, nil, _event), do: {:ok, state}

  defp maybe_supersede(state, number, event) do
    case Map.fetch(state.revisions, number) do
      {:ok, %{"status" => "approved"} = revision} ->
        {:ok, put_in(state, [:revisions, number], Map.put(revision, "status", "superseded"))}

      {:ok, %{"status" => current}} ->
        {:error, {:rebuild_supersede_without_authority, event.sequence, number, current}}

      :error ->
        {:error, {:rebuild_supersede_without_revision, event.sequence, number}}
    end
  end

  defp rebuilt_decision(payload, kind) do
    %{
      "decision_id" => payload["decision_id"],
      "kind" => kind,
      "revision_number" => payload["revision_number"],
      "digest" => payload["plan_digest"],
      "decided_by" => payload["decided_by"],
      "reason" => payload["reason"],
      "note" => payload["note"]
    }
  end

  defp divergences(revisions, decisions, authority, goal_id, opts) do
    stored_revisions = list_revisions(goal_id, opts)
    stored_decisions = list_decisions(goal_id, opts)
    stored_authority = authority(goal_id, opts)

    revision_divergences(revisions, stored_revisions) ++
      decision_divergences(decisions, stored_decisions) ++
      authority_divergence(authority, stored_authority)
  end

  defp revision_divergences(rebuilt, stored) do
    missing =
      for row <- stored,
          not Enum.any?(rebuilt, &(&1["revision_number"] == row.revision_number)),
          do: "revision #{row.revision_number} is stored but absent from events"

    mismatched =
      for row <- stored,
          revision = Enum.find(rebuilt, &(&1["revision_number"] == row.revision_number)),
          revision != nil,
          detail <- revision_mismatch(revision, row),
          do: detail

    extra =
      for revision <- rebuilt,
          not Enum.any?(stored, &(&1.revision_number == revision["revision_number"])),
          do: "revision #{revision["revision_number"]} is in events but not stored"

    missing ++ mismatched ++ extra
  end

  defp revision_mismatch(revision, row) do
    [
      {revision["digest"] != row.digest, "revision #{row.revision_number} digest diverges"},
      {revision["declared_digest"] != row.digest,
       "revision #{row.revision_number} declared digest diverges"},
      {revision["status"] != row.status, "revision #{row.revision_number} status diverges"},
      {revision["content"] != row.content, "revision #{row.revision_number} content diverges"},
      {revision["authored_by"] != row.authored_by,
       "revision #{row.revision_number} author diverges"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp decision_divergences(rebuilt, stored) do
    missing =
      for row <- stored,
          not Enum.any?(rebuilt, &(&1["decision_id"] == row.decision_id)),
          do: "decision #{row.decision_id} is stored but absent from events"

    mismatched =
      for row <- stored,
          decision = Enum.find(rebuilt, &(&1["decision_id"] == row.decision_id)),
          decision != nil,
          decision["kind"] != row.kind or decision["revision_number"] != row.revision_number or
            decision["digest"] != row.bound_digest,
          do: "decision #{row.decision_id} diverges"

    extra =
      for decision <- rebuilt,
          not Enum.any?(stored, &(&1.decision_id == decision["decision_id"])),
          do: "decision #{decision["decision_id"]} is in events but not stored"

    missing ++ mismatched ++ extra
  end

  defp authority_divergence(nil, nil), do: []

  defp authority_divergence(nil, %{revision_number: number}),
    do: ["authority #{number} is stored but events grant none"]

  defp authority_divergence(%{"revision_number" => number}, nil),
    do: ["events grant authority to revision #{number} but none is stored"]

  defp authority_divergence(%{"revision_number" => rebuilt, "digest" => digest}, stored) do
    cond do
      rebuilt != stored.revision_number ->
        ["authority diverges: events #{rebuilt}, stored #{stored.revision_number}"]

      digest != stored.digest ->
        ["authority digest diverges for revision #{rebuilt}"]

      true ->
        []
    end
  end

  # ----------------------------------------------------------------------------
  # Event construction
  # ----------------------------------------------------------------------------

  defp revision_created_event(revision, contract) do
    payload =
      %{
        "plan_revision_id" => revision.id,
        "proposal_id" => revision.proposal_id,
        "revision_number" => revision.revision_number,
        "plan_version" => contract.version,
        "plan_digest" => contract.digest,
        "plan_content" => PlanContract.canonical_json(contract),
        "authored_by" => revision.authored_by,
        "author_kind" => revision.author_kind,
        "task_count" => revision.task_count,
        "ordered_task_ids" => contract.ordered_task_ids
      }
      |> maybe_put("parent_revision_number", revision.parent_revision_number)

    %{"type" => "cobbler.plan.revision.created", "payload" => payload}
  end

  defp decision_event(%{kind: "approve"} = decision, revision, superseded, now) do
    payload =
      %{
        "plan_revision_id" => revision.id,
        "revision_number" => revision.revision_number,
        "decision_id" => decision.decision_id,
        "plan_digest" => revision.digest,
        "decided_by" => decision.decided_by,
        "decided_at" => DateTime.to_iso8601(now)
      }
      |> maybe_put("note", Map.get(decision, :note))
      |> maybe_put("superseded_revision_id", superseded && superseded.id)
      |> maybe_put("superseded_revision_number", superseded && superseded.revision_number)

    %{"type" => "cobbler.plan.approved", "payload" => payload}
  end

  defp decision_event(%{kind: "reject"} = decision, revision, _superseded, now) do
    payload = %{
      "plan_revision_id" => revision.id,
      "revision_number" => revision.revision_number,
      "decision_id" => decision.decision_id,
      "plan_digest" => revision.digest,
      "decided_by" => decision.decided_by,
      "decided_at" => DateTime.to_iso8601(now),
      "reason" => decision.reason
    }

    %{"type" => "cobbler.plan.rejected", "payload" => payload}
  end

  defp append_events(repo, goal_id, inputs, now) do
    base = next_sequence(repo, goal_id)

    Enum.with_index(inputs, fn input, index ->
      append_one_event(repo, goal_id, input, base + index, now)
    end)
  end

  defp append_one_event(repo, goal_id, input, sequence, now) do
    try do
      with {:ok, payload} <-
             EventRegistry.validate_payload(input["type"], @schema_version, input["payload"],
               now: now
             ),
           {:ok, event} <- insert_event(repo, goal_id, input, payload, sequence, now) do
        event
      else
        {:error, reason} -> repo.rollback({:event_append_failed, input["type"], reason})
      end
    rescue
      # SQLite reports unnamed FOREIGN KEY violations with a nil constraint
      # name that Ecto cannot map to a changeset error; catch the raise so
      # the whole store transaction still rolls back with a clean reason.
      error in [Ecto.ConstraintError] ->
        repo.rollback({:event_append_failed, input["type"], error})
    end
  end

  defp insert_event(repo, goal_id, input, payload, sequence, now) do
    %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: goal_id,
      task_id: nil,
      run_id: nil,
      sequence: sequence,
      parent_event_id: nil,
      type: input["type"],
      actor: @actor,
      occurred_at: now,
      schema_version: @schema_version,
      payload: payload,
      idempotency_key: nil
    }
    |> TrajectoryEvent.changeset(%{})
    |> repo.insert()
  end

  defp next_sequence(repo, goal_id) do
    last =
      repo.one(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal_id,
          select: max(event.sequence)
      ) || 0

    last + 1
  end

  # ----------------------------------------------------------------------------
  # Attribute validation
  # ----------------------------------------------------------------------------

  defp plan_contract(attrs) do
    case Contract.fetch(attrs, :plan) do
      {:ok, plan} -> PlanContract.new(plan)
      :error -> {:error, {:invalid_plan_request, :plan, "can't be blank"}}
    end
  end

  defp decision_attrs(attrs, kind) do
    with {:ok, decision_id} <- identifier(attrs, :decision_id),
         {:ok, decided_by} <- human_identity(attrs, :decided_by),
         {:ok, revision_number} <- required_revision_number(attrs, :revision_number),
         {:ok, digest} <- digest(attrs),
         {:ok, reason} <- reason(attrs, kind),
         {:ok, note} <- note(attrs, kind) do
      {:ok,
       %{
         decision_id: decision_id,
         decided_by: decided_by,
         revision_number: revision_number,
         digest: digest,
         kind: kind,
         reason: reason,
         note: note
       }}
    end
  end

  defp identifier(attrs, field) do
    case Contract.fetch(attrs, field) do
      {:ok, value} when is_binary(value) ->
        if Regex.match?(@id_pattern, value) do
          {:ok, value}
        else
          {:error, {:invalid_plan_request, field, "must be a bounded identifier"}}
        end

      _other ->
        {:error, {:invalid_plan_request, field, "can't be blank"}}
    end
  end

  # Only a human authors a revision and only a human decides on one. A
  # planner identity is recorded inside the plan as provenance and is
  # refused here, which is what makes "the planner cannot approve itself"
  # a property of the API rather than a convention.
  defp human_identity(attrs, field) do
    case Contract.fetch(attrs, field) do
      {:ok, value} when is_binary(value) ->
        if Regex.match?(@human_identity_pattern, value) do
          {:ok, value}
        else
          {:error, {:non_human_identity, %{"field" => field, "value" => value}}}
        end

      _other ->
        {:error, {:invalid_plan_request, field, "can't be blank"}}
    end
  end

  defp required_revision_number(attrs, field) do
    case Contract.fetch(attrs, field) do
      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      _other ->
        {:error, {:invalid_plan_request, field, "must be a positive integer"}}
    end
  end

  defp optional_revision_number(attrs, field) do
    case Contract.fetch(attrs, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:invalid_plan_request, field, "must be a positive integer"}}
    end
  end

  defp digest(attrs) do
    case Contract.fetch(attrs, :digest) do
      {:ok, value} when is_binary(value) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, value) do
          {:ok, value}
        else
          {:error, {:invalid_plan_request, :digest, "must be a sha256 hex digest"}}
        end

      _other ->
        {:error, {:invalid_plan_request, :digest, "can't be blank"}}
    end
  end

  defp reason(attrs, "approve"), do: {:ok, nil} |> ignore_unless_present(attrs, :reason)

  defp reason(attrs, "reject") do
    case Contract.fetch(attrs, :reason) do
      {:ok, value} when is_binary(value) ->
        case Contract.text(value, :reason, max: @max_reason_length) do
          {:ok, text} ->
            {:ok, text}

          {:error, _changeset} ->
            {:error, {:invalid_plan_request, :reason, "is not bounded text"}}
        end

      _other ->
        {:error, {:invalid_plan_request, :reason, "can't be blank"}}
    end
  end

  defp note(attrs, "reject"), do: {:ok, nil} |> ignore_unless_present(attrs, :note)

  defp note(attrs, "approve") do
    case Contract.fetch(attrs, :note) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        case Contract.text(value, :note, max: @max_note_length) do
          {:ok, text} -> {:ok, text}
          {:error, _changeset} -> {:error, {:invalid_plan_request, :note, "is not bounded text"}}
        end

      _other ->
        {:error, {:invalid_plan_request, :note, "must be a string"}}
    end
  end

  # A field that belongs to the other decision kind is refused rather than
  # dropped: silently ignoring a `reason` on an approval would let an
  # operator believe a rationale was recorded when nothing was.
  defp ignore_unless_present({:ok, nil}, attrs, field) do
    case Contract.fetch(attrs, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> {:error, {:invalid_plan_request, field, "does not apply to this decision"}}
    end
  end

  # ----------------------------------------------------------------------------
  # Shared helpers
  # ----------------------------------------------------------------------------

  defp ensure_goal(repo, goal_id) do
    if repo.exists?(from goal in Goal, where: goal.id == ^goal_id) do
      :ok
    else
      {:error, :goal_not_found}
    end
  end

  defp existing_revision_by_proposal(repo, goal_id, proposal_id) do
    repo.one(
      from revision in PlanRevisionRecord,
        where: revision.goal_id == ^goal_id and revision.proposal_id == ^proposal_id
    )
  end

  defp existing_decision(repo, goal_id, decision_id) do
    repo.one(
      from decision in PlanDecisionRecord,
        where: decision.goal_id == ^goal_id and decision.decision_id == ^decision_id
    )
  end

  defp get_revision_row(repo, goal_id, revision_number) do
    repo.one(
      from revision in PlanRevisionRecord,
        where: revision.goal_id == ^goal_id and revision.revision_number == ^revision_number
    )
  end

  defp fetch_revision!(repo, goal_id, revision_number),
    do: get_revision_row(repo, goal_id, revision_number)

  defp approved_revision_row(repo, goal_id) do
    repo.one(
      from revision in PlanRevisionRecord,
        where: revision.goal_id == ^goal_id and revision.status == "approved"
    )
  end

  defp next_revision_number(repo, goal_id) do
    last =
      repo.one(
        from revision in PlanRevisionRecord,
          where: revision.goal_id == ^goal_id,
          select: max(revision.revision_number)
      ) || 0

    last + 1
  end

  # `mode: :immediate` takes SQLite's write lock at BEGIN, where the
  # connection's `busy_timeout` applies. Under heavy contention that lock
  # can still be refused, and Exqlite raises rather than returning. Every
  # error leaving this module is a structured tuple, so the raise is
  # converted here instead of escaping as an exception. The whole
  # transaction rolled back, so a caller may safely retry the same
  # `proposal_id` or `decision_id`: idempotency makes the retry converge.
  defp run_transaction(repo, fun) do
    repo.transaction(fun, mode: :immediate)
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      {:error, {:database_busy, Exception.message(error)}}
  end

  defp publish_result({:ok, %{events: events} = result}, opts) do
    publish(events, opts)
    {:ok, result}
  end

  defp publish_result({:error, reason}, _opts), do: {:error, reason}

  defp publish(events, opts) do
    publish_fun = Keyword.get(opts, :publish_fun, &default_publish/1)
    Enum.each(events, publish_fun)
  end

  defp default_publish(event) do
    Phoenix.PubSub.broadcast(
      Shoestring.PubSub,
      Shoestring.Trajectory.topic(event.goal_id),
      {:trajectory_event_committed, event}
    )
  rescue
    error ->
      # The revision and its events are already durably committed; a PubSub
      # hiccup must not fail the recorded outcome.
      Logger.warning("cobbler plan event publish failed: #{Exception.message(error)}")
  end

  defp event_attributes(event) do
    %{
      id: event.id,
      goal_id: event.goal_id,
      task_id: event.task_id,
      run_id: event.run_id,
      sequence: event.sequence,
      parent_event_id: event.parent_event_id,
      type: event.type,
      actor: event.actor,
      occurred_at: event.occurred_at,
      schema_version: event.schema_version,
      payload: event.payload,
      idempotency_key: event.idempotency_key
    }
  end

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> DateTime.truncate(now, :microsecond)
      _other -> DateTime.truncate(DateTime.utc_now(), :microsecond)
    end
  end

  defp cast_goal_id(goal_id) do
    case Ecto.UUID.cast(goal_id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_goal_id, goal_id}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
