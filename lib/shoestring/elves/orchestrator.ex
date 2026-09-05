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

  Required attributes: `:action` (one of `choices/0`), `:rationale`.
  Optional: `:evidence_refs` (observation ids consumed), `:observation_id`
  (the primary observation), `:outcome` (what the requested action produced;
  may be recorded as `"pending"` and updated by a later choice), and
  `:decision_id` (stable idempotency key across retries; generated when
  absent).

  Recording never acts on the run: it is the audit trail the decision policy
  will later be judged against.
  """
  @spec record_choice(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, TrajectoryEvent.t()} | {:error, term()}
  def record_choice(run_id, attrs, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, run} <- fetch_run(run_id, repo),
         {:ok, action} <- cast_action(attrs),
         {:ok, rationale} <- cast_rationale(attrs) do
      decision_id = decision_id(attrs)
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
  Authorizes a replacement launch without launching anything itself.

  Returns `{:ok, :allowed}` when the guard passes; otherwise
  `{:error, :prior_run_active}`. The caller starts the new run, so a refused
  request can never duplicate work.
  """
  @spec request_replacement(Ecto.UUID.t(), keyword()) ::
          {:ok, :allowed} | {:error, term()}
  def request_replacement(run_id, opts \\ []) do
    case can_replace?(run_id, opts) do
      {:ok, true} -> {:ok, :allowed}
      {:ok, false} -> {:error, :prior_run_active}
      {:error, _reason} = error -> error
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
            event.type in ["run.completed", "run.failed", "run.cancelled"],
        order_by: [desc: event.sequence],
        limit: 1
    )
  end

  defp terminal_class(run, repo) do
    case terminal_event(run, repo) do
      %TrajectoryEvent{type: "run.completed"} -> "completed"
      %TrajectoryEvent{type: "run.failed"} -> "failed"
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

  defp decision_id(%{"decision_id" => id}) when is_binary(id), do: id
  defp decision_id(%{decision_id: id}) when is_binary(id), do: id
  defp decision_id(_attrs), do: Ecto.UUID.generate()

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
