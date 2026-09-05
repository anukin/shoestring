defmodule Shoestring.Elves.Orchestrator do
  @moduledoc """
  Evidence seam between quiet Elf runs and the LLM orchestrator.

  The orchestrator consumes a bounded packet built from durable trajectory
  state and chooses among `wait`, `request_status`, `resolve_approval`,
  `synthesize_completion`, `checkpoint`, `resume`, `handoff`, `replace`,
  `escalate`, `cancel`, and the operator-level `reconcile` (an explicit
  hands-on verification that a stuck prior run was dealt with outside the
  loop). Every recovery choice is recorded in the
  trajectory with its evidence references, rationale, requested action, and
  outcome, so later review can replay exactly what was known and decided.

  ## What this seam does not do

  It never interrupts, replaces, or duplicates a run on its own. In
  particular, `request_replacement/2` refuses while the prior run is still
  active: a replacement may launch only after the prior run reached a
  terminal state or was explicitly reconciled. The decision *policy* — which
  choice fits which evidence — is a documented follow-up; this module ships
  the evidence packet plus faithful recording, and no automatic action under
  any circumstances.
  """

  import Ecto.Query

  alias Shoestring.Harness.RunRecord
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Redaction, TrajectoryEvent}

  @choices ~w(
    wait
    request_status
    resolve_approval
    synthesize_completion
    checkpoint
    resume
    handoff
    replace
    escalate
    cancel
    reconcile
  )

  @max_observations 5
  @max_evidence_refs 20
  @max_list_items 50

  @doc "The recovery actions the orchestrator may choose among."
  @spec choices() :: [String.t()]
  def choices, do: @choices

  @doc """
  Derives a stable decision id from `(run_id, action, observation_id)`.

  Pass the result as `:decision_id` when recording the choice it was
  derived for: retries and application restarts that respond to the same
  observation with the same action then share one idempotency key and
  deduplicate instead of duplicating the decision.
  """
  @spec decision_id(Ecto.UUID.t(), String.t(), String.t() | nil) :: String.t()
  def decision_id(run_id, action, observation_id) do
    digest =
      :crypto.hash(:sha256, "#{run_id}:#{action}:#{observation_id}")
      |> Base.encode16(case: :lower)

    binary_part(digest, 0, 16)
  end

  @doc """
  Builds the bounded evidence packet the orchestrator decides from.

  Reads the latest `elf.staleness_observed` packets plus the run's progress
  signals (terminal state, completed commands/tests, final-response state).
  Returns `evidence: nil` when nothing has been observed yet — the caller
  should collect evidence first rather than act blind.
  """
  @spec summarize(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def summarize(run_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, run} <- fetch_run(run_id, repo) do
      observations = latest_observations(run, repo)
      latest = List.first(observations)
      evidence = latest && latest.payload["evidence"]

      {:ok,
       %{
         run_id: run.id,
         run_status: run.status,
         terminal: terminal_class(run, repo),
         evidence: bounded_evidence(evidence),
         evidence_refs: evidence_refs(observations),
         observed_at: latest && latest.payload["observed_at"],
         progress: progress_signals(run, repo, evidence),
         choices: @choices,
         decision_policy:
           "deferred: the orchestrator or operator chooses; this seam records the choice but takes no automatic action"
       }}
    end
  end

  @doc """
  Records one recovery choice in the trajectory as `elf.recovery_decided`.

  Required attributes: `:action` (one of `choices/0`), `:rationale`, and
  `:decision_id` — a stable caller-owned idempotency key (see
  `decision_id/3`). There is deliberately no generated default: a random
  fallback would silently mint a fresh key on every retry and defeat
  deduplication across restarts.
  Optional: `:evidence_refs` (observation ids consumed), `:observation_id`
  (the primary observation), `:outcome` (what the requested action produced;
  `"pending"` unless stated).

  Recording `action: "replace"` additionally claims the exclusive
  replacement (see `request_replacement/2`) and fails with
  `:prior_run_active` while the prior run is still active — a replace
  decision can never be recorded over a live run.

  Recording never acts on the run: it is the audit trail the decision policy
  will later be judged against.
  """
  @spec record_choice(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, TrajectoryEvent.t()} | {:error, term()}
  def record_choice(run_id, attrs, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, run} <- fetch_run(run_id, repo),
         {:ok, action} <- cast_action(attrs),
         {:ok, rationale} <- cast_rationale(attrs),
         {:ok, decision_id} <- cast_decision_id(attrs),
         :ok <- claim_for_replace(run, action, decision_id, opts) do
      clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

      payload =
        %{
          "run_id" => run.id,
          "decision_id" => decision_id,
          "action" => action,
          "observation_id" => observation_id(attrs),
          "evidence_refs" => evidence_refs_attr(attrs),
          "rationale" => Redaction.redact(rationale),
          "outcome" => outcome(attrs)
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      append_attrs = %{
        "type" => "elf.recovery_decided",
        "schema_version" => 1,
        "actor" => "orchestrator",
        "occurred_at" => Shoestring.Harness.Clock.now(clock),
        "idempotency_key" => "elf-recovery:#{decision_id}",
        "payload" => payload
      }

      Trajectory.append(run.goal_id, append_attrs,
        trusted: [task_id: run.task_id, run_id: run.id]
      )
    end
  end

  @doc """
  Replacement guard: reports whether a replacement run may launch.

  True only when the prior run already reached a terminal state or was
  explicitly reconciled (a recorded `reconcile` choice with outcome
  `"reconciled"`). Anything else — including a quiet heartbeat, an expired
  lease, or a missing final response — keeps returning false.
  """
  @spec can_replace?(Ecto.UUID.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def can_replace?(run_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, run} <- fetch_run(run_id, repo) do
      cond do
        terminal_event(run, repo) != nil -> {:ok, true}
        reconciled?(run, repo) -> {:ok, true}
        true -> {:ok, false}
      end
    end
  end

  @doc """
  Authorizes a replacement launch by recording one exclusive per-run claim.

  Returns `{:ok, :allowed}` when the guard passes and this caller won the
  claim; `{:error, :prior_run_active}` while the prior run is still active;
  `{:error, :replacement_already_claimed}` when a different decision already
  claimed the replacement for this run. Retrying with the same
  `:decision_id` is idempotent and returns `:allowed` again, so a crash
  between the claim and the launch cannot wedge the run, while two
  concurrent claimants (an Oban retry racing the orchestrator loop) cannot
  both dispatch duplicate work: the claim is a uniquely-keyed trajectory
  event, and the trajectory writer serializes appends per goal, so exactly
  one decision wins and the loser observes the winner.

  This function records the claim; it never launches anything itself.
  """
  @spec request_replacement(Ecto.UUID.t(), keyword()) ::
          {:ok, :allowed} | {:error, term()}
  def request_replacement(run_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, run} <- fetch_run(run_id, repo),
         {:ok, true} <- guard_allows(run, repo),
         {:ok, decision_id} <- cast_decision_id(opts) do
      claim_replacement(run, decision_id, rationale_opt(opts), opts)
    end
  end

  defp guard_allows(run, repo) do
    cond do
      terminal_event(run, repo) != nil -> {:ok, true}
      reconciled?(run, repo) -> {:ok, true}
      true -> {:error, :prior_run_active}
    end
  end

  defp claim_replacement(run, decision_id, rationale, opts) do
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

    payload =
      %{
        "run_id" => run.id,
        "decision_id" => decision_id,
        "rationale" => rationale && Redaction.redact(rationale)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    append_attrs = %{
      "type" => "elf.replacement_claimed",
      "schema_version" => 1,
      "actor" => "orchestrator",
      "occurred_at" => Shoestring.Harness.Clock.now(clock),
      "idempotency_key" => "elf-replacement:#{run.id}",
      "payload" => payload
    }

    # The writer serializes appends per goal and returns the winning event
    # on an idempotency conflict, so comparing the winner's decision id is
    # the race-safe verdict: same decision means our own retry, anything
    # else means a rival claim won.
    case Trajectory.append(run.goal_id, append_attrs,
           trusted: [task_id: run.task_id, run_id: run.id]
         ) do
      {:ok, %TrajectoryEvent{payload: %{"decision_id" => ^decision_id}}} ->
        {:ok, :allowed}

      {:ok, %TrajectoryEvent{}} ->
        {:error, :replacement_already_claimed}

      {:error, _reason} = error ->
        error
    end
  end

  defp claim_for_replace(run, "replace", decision_id, opts) do
    case request_replacement(run.id, Keyword.put(opts, :decision_id, decision_id)) do
      {:ok, :allowed} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp claim_for_replace(_run, _action, _decision_id, _opts), do: :ok

  defp rationale_opt(opts) do
    case Keyword.get(opts, :rationale) do
      rationale when is_binary(rationale) -> rationale
      _other -> nil
    end
  end

  defp fetch_run(run_id, repo) do
    case repo.get(RunRecord, run_id) do
      %RunRecord{} = run -> {:ok, run}
      nil -> {:error, :run_not_found}
    end
  end

  defp latest_observations(run, repo) do
    repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^run.goal_id and event.run_id == ^run.id and
            event.type == "elf.staleness_observed",
        order_by: [desc: event.sequence],
        limit: @max_observations
    )
  end

  defp terminal_event(run, repo) do
    repo.one(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^run.goal_id and event.run_id == ^run.id and
            event.type in ["run.completed", "run.failed", "run.interrupted", "run.cancelled"],
        order_by: [desc: event.sequence],
        limit: 1
    )
  end

  defp terminal_class(run, repo) do
    case terminal_event(run, repo) do
      %TrajectoryEvent{type: "run.completed"} -> "completed"
      %TrajectoryEvent{type: "run.failed"} -> "failed"
      %TrajectoryEvent{type: "run.interrupted"} -> "interrupted"
      %TrajectoryEvent{type: "run.cancelled"} -> "cancelled"
      nil -> nil
    end
  end

  defp reconciled?(run, repo) do
    repo.exists?(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^run.goal_id and event.run_id == ^run.id and
            event.type == "elf.recovery_decided" and
            fragment("(? ->> ?) = ?", event.payload, "action", "reconcile") and
            fragment("(? ->> ?) = ?", event.payload, "outcome", "reconciled")
    )
  end

  defp bounded_evidence(nil), do: nil

  defp bounded_evidence(evidence) when is_map(evidence) do
    evidence
    |> Map.take([
      "reason",
      "run_status",
      "prior_observations",
      "last_event_at",
      "last_event_sequence",
      "last_event_type",
      "heartbeat_age_seconds",
      "os_process_group",
      "provider_session_id",
      "safe_boundary",
      "oban_attempt",
      "worktree",
      "final_response",
      "pending_approval"
    ])
    |> Map.put(
      "completed_commands",
      Enum.take(evidence["completed_commands"] || [], @max_list_items)
    )
    |> Map.put("completed_tests", Enum.take(evidence["completed_tests"] || [], @max_list_items))
  end

  defp evidence_refs(observations) do
    observations
    |> Enum.map(& &1.payload["observation_id"])
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_evidence_refs)
  end

  defp progress_signals(run, repo, evidence) do
    base = %{
      terminal: terminal_class(run, repo),
      completed_commands: [],
      completed_tests: [],
      final_response_state: "unknown"
    }

    if is_map(evidence) do
      %{
        base
        | completed_commands: Enum.take(evidence["completed_commands"] || [], @max_list_items),
          completed_tests: Enum.take(evidence["completed_tests"] || [], @max_list_items),
          final_response_state: get_in(evidence, ["final_response", "state"]) || "unknown"
      }
    else
      base
    end
  end

  defp cast_action(%{"action" => action}), do: cast_action_value(action)
  defp cast_action(%{action: action}), do: cast_action_value(action)
  defp cast_action(_attrs), do: {:error, {:missing_action, "recovery choice requires an action"}}

  defp cast_action_value(action) when action in @choices, do: {:ok, action}
  defp cast_action_value(action), do: {:error, {:unknown_action, action}}

  defp cast_rationale(%{"rationale" => rationale}) when is_binary(rationale), do: {:ok, rationale}
  defp cast_rationale(%{rationale: rationale}) when is_binary(rationale), do: {:ok, rationale}

  defp cast_rationale(_attrs),
    do: {:error, {:missing_rationale, "recovery choice requires a rationale"}}

  defp cast_decision_id(attrs) when is_list(attrs) do
    attrs |> Map.new() |> cast_decision_id()
  end

  defp cast_decision_id(%{"decision_id" => id}) when is_binary(id), do: {:ok, id}
  defp cast_decision_id(%{decision_id: id}) when is_binary(id), do: {:ok, id}

  defp cast_decision_id(_attrs),
    do:
      {:error,
       {:missing_decision_id,
        "recovery choice requires a stable decision_id (see decision_id/3); generated ids defeat cross-restart deduplication"}}

  defp observation_id(%{"observation_id" => id}) when is_binary(id), do: id
  defp observation_id(%{observation_id: id}) when is_binary(id), do: id
  defp observation_id(_attrs), do: nil

  defp evidence_refs_attr(%{"evidence_refs" => refs}) when is_list(refs) do
    refs |> Enum.filter(&is_binary/1) |> Enum.take(@max_evidence_refs)
  end

  defp evidence_refs_attr(%{evidence_refs: refs}) when is_list(refs) do
    refs |> Enum.filter(&is_binary/1) |> Enum.take(@max_evidence_refs)
  end

  defp evidence_refs_attr(_attrs), do: nil

  defp outcome(%{"outcome" => outcome}) when is_binary(outcome), do: outcome
  defp outcome(%{outcome: outcome}) when is_binary(outcome), do: outcome
  defp outcome(_attrs), do: "pending"
end
