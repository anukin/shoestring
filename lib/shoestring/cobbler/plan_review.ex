defmodule Shoestring.Cobbler.PlanReview do
  @moduledoc """
  Cross-provider review of a plan-task attempt, after its deterministic gates
  passed and before it is accepted (iteration 8). Off unless trusted
  configuration enables it (`Shoestring.Cobbler.Review.Configuration`).

  ## Lifecycle

  1. Gates pass. A review record binds the attempt, the reviewed commit, the
     immutable packet (`Review.Packet`), the stored gate evidence and the
     reviewer configuration (`cobbler.plan.task.review_requested`).
  2. The call is admitted like any provider call (`read_only`, the reviewer's
     provider and scope). A held call waits for a human confirmation of that
     one call (`cobbler.plan.review.confirmed`); nothing bypasses admission.
  3. One tool-free call returns structured findings (`Review.Findings`),
     recorded as `cobbler.plan.task.reviewed`. The implementation worktree
     must still be at the reviewed commit and clean afterwards, or the review
     is discarded as failed.
  4. Deterministic code decides: no supported blocking finding accepts the
     attempt (with the review summary on `cobbler.plan.task.accepted`);
     blocking findings that may still be repaired resolve the attempt as
     `cobbler.plan.task.review_blocked` with `retry`, and the next attempt
     starts from the reviewed commit with the findings in its prompt.
  5. The last allowed round, a blocking finding that repeats the previous
     round's (same path and violated contract) or an exhausted attempt
     budget escalates instead: the attempt stays open for a human.

  Unavailable review (no reviewer, the implementer's provider, an unusable
  packet), a failed call or a lost call never approve anything. A human
  decides (`cobbler.plan.review.decided`): `accept` (a waiver or a dismissal
  of the findings, with a reason), `reject` (the attempt fails and needs the
  user) or `retry` (one more call; at most two per review). Transport
  failures are never retried automatically, and a running call that was lost
  in a crash is never re-sent by time alone.
  """
  import Ecto.Query

  alias Shoestring.{Repo, Trajectory, Worktrees}
  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionEvaluation, Commands, GateProcess}
  alias Shoestring.Cobbler.{PlanContract, ReservationWriter, WakeupObserve}
  alias Shoestring.Cobbler.Review.{Configuration, Findings, Packet, Record}
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Trajectory.TrajectoryEvent

  @confirmed "cobbler.plan.review.confirmed"
  @decided "cobbler.plan.review.decided"
  @extension "shoestring.plan:review_confirmation_id"
  @gate "cross_review"
  @held_retry_ms 60_000
  @max_calls 2

  def gate, do: @gate

  @type outcome ::
          {:accept, map() | nil, [map()] | nil}
          | {:blocked, map()}
          | {:changes_requested, Record.t()}
          | {:pending, term()}

  @doc "The review record of one attempt, if any."
  def existing(repo \\ Repo, execution_id, plan_task_id, attempt) do
    repo.get_by(Record, execution_id: execution_id, plan_task_id: plan_task_id, attempt: attempt)
  end

  @doc """
  Advances the review of one attempt whose gates passed. `ctx`: `:goal_id`,
  `:execution`, `:dispatched`, `:contract`, `:task_contract`,
  `:gate_evidences` (nil when the record already exists) and `:opts`.

  Returns `{:accept, nil, nil}` when review is not required, `{:accept,
  summary, gate_evidences}`, `{:changes_requested, record}` (the executor
  decides between repair and escalation), `{:blocked, detail}` (a human
  rejected the attempt) or `{:pending, reason}`.
  """
  @spec stage(map()) :: outcome()
  def stage(ctx) do
    %{execution: execution, dispatched: dispatched} = ctx

    case existing(execution.execution_id, dispatched.plan_task_id, dispatched.attempt) do
      nil ->
        with {:ok, policy} <- Configuration.load(execution, ctx.opts) do
          case policy do
            :not_required ->
              {:accept, nil, nil}

            policy ->
              with {:ok, record} <- create(ctx, policy), do: advance(record, ctx)
          end
        end

      record ->
        advance(record, ctx)
    end
  end

  @doc "Escalates a `changes_requested` review the executor will not repair."
  def escalate(%Record{state: "changes_requested"} = record, reason, opts \\ []) do
    save(record, %{state: "escalated", errors: items([error("escalated", reason)])}, opts)
  end

  @doc "Whether this round's blocking findings repeat the previous round's."
  def repeated?(%Record{} = record) do
    previous =
      Repo.one(
        from r in Record,
          where:
            r.execution_id == ^record.execution_id and r.plan_task_id == ^record.plan_task_id and
              r.round == ^(record.round - 1),
          limit: 1
      )

    current = fingerprints(record)

    previous != nil and MapSet.size(current) > 0 and
      not MapSet.disjoint?(current, fingerprints(previous))
  end

  @doc "The blocking findings of a `changes_requested` review, for the repair prompt."
  def blocking_findings(%Record{result_json: json}) when is_binary(json) do
    json |> Jason.decode!() |> Map.fetch!("findings") |> Enum.filter(&Findings.blocking?/1)
  end

  def blocking_findings(_record), do: []

  @doc "The latest review of an earlier attempt of this task that asked for changes."
  def repair_source(execution_id, plan_task_id, attempt) do
    Repo.one(
      from r in Record,
        where:
          r.execution_id == ^execution_id and r.plan_task_id == ^plan_task_id and
            r.attempt == ^(attempt - 1) and r.state == "changes_requested",
        limit: 1
    )
  end

  @doc "Every review of an execution, oldest first, for status and results."
  def summary(repo \\ Repo, execution_id) do
    repo.all(
      from r in Record,
        where: r.execution_id == ^execution_id,
        order_by: [asc: r.plan_task_id, asc: r.attempt]
    )
    |> Enum.map(&view/1)
  end

  @doc "Whether a review is waiting for a human decision (not a capacity confirmation)."
  def needs_user?(%Record{} = record) do
    record.state in ~w(escalated failed) or
      (record.state == "pending" and
         (Map.has_key?(record.configuration, "unavailable") or record.calls >= @max_calls))
  end

  # ----------------------------------------------------------------------------
  # Human decisions
  # ----------------------------------------------------------------------------

  @doc """
  Records a human confirmation for the next call of one held review.
  `attrs`: `:review_id`, `:confirmation_id` (UUID) and `:confirmed_by`.
  """
  def confirm(goal_id, attrs) do
    with %Record{goal_id: ^goal_id, state: state} = record when state in ~w(pending held) <-
           get(attrs[:review_id]),
         %{"provider_id" => provider, "scope" => scope} <- record.configuration,
         {:ok, id} <- Ecto.UUID.cast(attrs[:confirmation_id]) do
      append(
        goal_id,
        @confirmed,
        %{
          "confirmation_id" => id,
          "review_id" => record.id,
          "execution_id" => record.execution_id,
          "plan_task_id" => record.plan_task_id,
          "attempt" => record.attempt,
          "provider_id" => provider,
          "scope" => scope,
          "confirmed_by" => attrs[:confirmed_by]
        },
        "plan-review-confirmation:#{id}",
        "human",
        []
      )
    else
      _ -> {:error, :review_confirmation_mismatch}
    end
  end

  @doc """
  Records a human decision on a review that cannot finish by itself.
  `attrs`: `:review_id`, `:decision_id` (UUID), `:decision` (`"accept"`,
  `"reject"` or `"retry"`), `:reason` and `:decided_by`.
  """
  def decide(goal_id, attrs) do
    with %Record{goal_id: ^goal_id} = record <- get(attrs[:review_id]),
         true <- allowed?(record, attrs[:decision]),
         {:ok, id} <- Ecto.UUID.cast(attrs[:decision_id]) do
      append(
        goal_id,
        @decided,
        %{
          "decision_id" => id,
          "review_id" => record.id,
          "execution_id" => record.execution_id,
          "plan_task_id" => record.plan_task_id,
          "attempt" => record.attempt,
          "decision" => attrs[:decision],
          "reason" => attrs[:reason],
          "decided_by" => attrs[:decided_by]
        },
        "plan-review-decision:#{id}",
        "human",
        []
      )
    else
      _ -> {:error, :review_decision_not_allowed}
    end
  end

  defp allowed?(%Record{state: state} = record, "retry"),
    do:
      state in ~w(failed running) and record.calls < @max_calls and
        not Map.has_key?(record.configuration, "unavailable")

  defp allowed?(%Record{state: state}, decision) when decision in ["accept", "reject"],
    do: state in ~w(pending held running failed escalated)

  defp allowed?(_record, _decision), do: false

  # ----------------------------------------------------------------------------
  # Creation
  # ----------------------------------------------------------------------------

  defp create(ctx, policy) do
    %{execution: execution, dispatched: dispatched, gate_evidences: evidences} = ctx
    first = hd(evidences)
    previous = repair_source(execution.execution_id, dispatched.plan_task_id, dispatched.attempt)

    base =
      if previous,
        do: previous.base_commit,
        else: worktree_base(first.worktree, ctx.opts)

    configuration =
      case policy do
        {:required, loaded} ->
          loaded.public

        {:unavailable, reason} ->
          %{
            "version" => "1",
            "unavailable" => Atom.to_string(reason),
            "implementer_provider" => get_in(execution, [:agent_profile, "provider"]) || "fake"
          }
      end

    gates = Enum.map(evidences, &stored/1)

    {packet, packet_error} =
      with base when is_binary(base) <- base,
           {:ok, built} <-
             Packet.build(%{
               goal: ctx.contract.content["goal"],
               task: ctx.task_contract,
               revision_number: execution.revision_number,
               plan_digest: execution.plan_digest,
               base: base,
               commit: first.commit,
               worktree: first.worktree,
               gates: Enum.map(gates, &Map.put(&1, "argv", Enum.join(&1["gate_argv"], " ")))
             }) do
        {built, nil}
      else
        {:error, reason} -> {%{json: "{}", digest: PlanContract.digest(%{})}, reason}
        _ -> {%{json: "{}", digest: PlanContract.digest(%{})}, :review_base_unknown}
      end

    round =
      Repo.aggregate(
        from(r in Record,
          where:
            r.execution_id == ^execution.execution_id and
              r.plan_task_id == ^dispatched.plan_task_id and r.attempt < ^dispatched.attempt
        ),
        :count
      ) + 1

    record = %Record{
      goal_id: ctx.goal_id,
      execution_id: execution.execution_id,
      plan_task_id: dispatched.plan_task_id,
      attempt: dispatched.attempt,
      run_id: dispatched.run_id,
      round: min(round, 3),
      base_commit: base || first.commit,
      commit: first.commit,
      packet_json: packet.json,
      packet_digest: packet.digest,
      gates: %{"items" => gates},
      configuration: configuration,
      state: if(packet_error, do: "failed", else: "pending"),
      errors:
        items(
          if(packet_error,
            do: [error(packet_error, "The review packet could not be built.")],
            else: []
          )
        )
    }

    transact(fn ->
      record = Repo.insert!(record)

      append!(
        ctx.goal_id,
        "cobbler.plan.task.review_requested",
        %{
          "review_id" => record.id,
          "execution_id" => record.execution_id,
          "plan_task_id" => record.plan_task_id,
          "revision_number" => execution.revision_number,
          "plan_digest" => execution.plan_digest,
          "run_id" => record.run_id,
          "attempt" => record.attempt,
          "round" => record.round,
          "base_commit" => record.base_commit,
          "commit" => record.commit,
          "packet_digest" => record.packet_digest,
          "configuration" => configuration
        },
        "plan-review-requested:#{record.execution_id}:#{record.plan_task_id}:#{record.attempt}",
        record.run_id
      )

      record
    end)
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, _} = error ->
        case existing(execution.execution_id, dispatched.plan_task_id, dispatched.attempt) do
          nil -> error
          record -> {:ok, record}
        end
    end
  end

  defp worktree_base(path, opts) do
    case Worktrees.get(path, Keyword.take(opts, [:worktrees_dir])) do
      {:ok, %{base_commit: base}} -> base
      _ -> nil
    end
  end

  # Stored with the full argv list so acceptance can be rebuilt exactly.
  defp stored(evidence) do
    %{
      "gate" => evidence.gate,
      "gate_argv" => evidence.gate_argv,
      "commit" => evidence.commit,
      "worktree" => evidence.worktree,
      "exit_status" => evidence.exit_status,
      # Redacted before it is stored or sent to a reviewer.
      "output" => Shoestring.Cobbler.GateOutput.redact(evidence.output),
      "duration_ms" => evidence.duration_ms,
      "sandbox" => Map.get(evidence, :sandbox),
      "spec" => Map.get(evidence, :spec),
      "required" => Map.get(evidence, :required, true),
      "result" => Map.get(evidence, :result, "passed"),
      "artifact_id" => Map.get(evidence, :artifact_id)
    }
  end

  defp evidences(%Record{gates: %{"items" => items}}) do
    Enum.map(items, fn item ->
      %{
        gate: item["gate"],
        gate_argv: item["gate_argv"],
        commit: item["commit"],
        worktree: item["worktree"],
        exit_status: item["exit_status"],
        output: item["output"],
        duration_ms: item["duration_ms"],
        sandbox: item["sandbox"],
        spec: item["spec"],
        required: Map.get(item, "required", true),
        result: Map.get(item, "result", "passed"),
        artifact_id: item["artifact_id"]
      }
    end)
  end

  # ----------------------------------------------------------------------------
  # Advancing
  # ----------------------------------------------------------------------------

  defp advance(record, ctx) do
    case pending_decision(record) do
      nil -> by_state(record, ctx)
      decision -> apply_decision(record, decision, ctx)
    end
  end

  defp apply_decision(record, %TrajectoryEvent{payload: p} = event, ctx) do
    case p["decision"] do
      "accept" ->
        with {:ok, record} <- save(record, %{state: "waived", decision_id: event.id}, ctx.opts) do
          {:accept, review_summary(record, p), evidences(record)}
        end

      "reject" ->
        with {:ok, record} <- save(record, %{state: "rejected", decision_id: event.id}, ctx.opts) do
          {:blocked, blocked_detail(record, "Rejected by #{p["decided_by"]}: #{p["reason"]}")}
        end

      "retry" ->
        with {:ok, record} <-
               save(
                 record,
                 %{state: "pending", decision_id: event.id, errors: items([])},
                 ctx.opts
               ) do
          by_state(record, ctx)
        end
    end
  end

  defp by_state(%Record{state: "approved"} = record, _ctx),
    do: {:accept, review_summary(record, nil), evidences(record)}

  defp by_state(%Record{state: "waived"} = record, _ctx) do
    decision = record.decision_id && Repo.get(TrajectoryEvent, record.decision_id)
    {:accept, review_summary(record, decision && decision.payload), evidences(record)}
  end

  defp by_state(%Record{state: "rejected"} = record, _ctx),
    do: {:blocked, blocked_detail(record, "Rejected by a human decision.")}

  defp by_state(%Record{state: "changes_requested"} = record, _ctx),
    do: {:changes_requested, record}

  defp by_state(%Record{state: "escalated"}, _ctx), do: {:pending, :review_escalated}
  defp by_state(%Record{state: "running"}, _ctx), do: {:pending, :review_running}

  defp by_state(%Record{state: "failed"} = record, _ctx),
    do: {:pending, {:review_failed, first_code(record)}}

  defp by_state(%Record{state: state} = record, ctx) when state in ["pending", "held"] do
    cond do
      Map.has_key?(record.configuration, "unavailable") ->
        {:pending, {:review_unavailable, record.configuration["unavailable"]}}

      record.calls >= @max_calls ->
        {:pending, :review_calls_exhausted}

      state == "held" and not readmit?(record) ->
        {:pending, :review_held}

      true ->
        with :ok <- fresh(record),
             {:ok, loaded} <- loaded(record, ctx) do
          admit(record, loaded, ctx)
        else
          {:error, reason} -> fail(record, reason, ctx)
        end
    end
  end

  # A held call is evaluated again only for a new human confirmation, or after
  # a minute when it was held for a reason confirmation cannot address.
  defp readmit?(record) do
    confirmation(record) != nil or
      (first_code(record) not in ~w(unknown_capacity support_tier_conservative_partial support_tier_reactive_only stale_observation future_observation) and
         DateTime.diff(DateTime.utc_now(), record.updated_at, :millisecond) >= @held_retry_ms)
  end

  defp admit(record, loaded, ctx) do
    public = loaded.public
    # Confirmations are stamped with the wall clock, so admission is too.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    confirmation = confirmation(record)

    {:ok, decision} =
      AdmissionEvaluation.evaluate(
        %{
          goal_id: record.goal_id,
          requested_capability: "read_only",
          scope: public["scope"],
          override: override(confirmation)
        },
        Configuration.candidate(public),
        snapshot(public, ctx.opts),
        nil,
        [now: now, occupancy: occupied_by_other_goal?(record.goal_id)] ++
          if(confirmation,
            do: [decision_id: confirmation.id, extensions: %{@extension => confirmation.id}],
            else: []
          )
      )

    case append(
           record.goal_id,
           "admission.decided",
           AdmissionDecision.to_payload(decision),
           if(confirmation, do: "plan-review-decision:#{confirmation.id}"),
           "cobbler",
           []
         ) do
      {:ok, admission} when decision.result == :admit ->
        call(record, loaded, admission, ctx)

      {:ok, _admission} ->
        errors = items([error(decision.reason_code, decision.explanation)])

        with {:ok, _} <- save(record, %{state: "held", errors: errors}, ctx.opts) do
          {:pending, :review_held}
        end

      {:error, _} = error ->
        error
    end
  end

  defp call(record, loaded, admission, ctx) do
    public = loaded.public
    number = record.calls + 1

    started =
      transact(fn ->
        record =
          update!(record, %{
            state: "running",
            calls: number,
            charged_output_tokens: record.charged_output_tokens + public["max_output_tokens"],
            errors: items([])
          })

        append!(
          record.goal_id,
          "cobbler.plan.review.attempt.started",
          %{
            "review_id" => record.id,
            "call" => number,
            "admission_event_id" => admission.id,
            "output_token_allowance" => public["max_output_tokens"]
          },
          "plan-review-started:#{record.id}:#{number}",
          record.run_id
        )

        record
      end)

    with {:ok, record} <- started do
      begin = System.monotonic_time(:millisecond)
      result = infer(record, loaded, ctx.opts)
      duration = System.monotonic_time(:millisecond) - begin
      finish(record, result, duration, ctx)
    end
  end

  defp infer(record, loaded, opts) do
    input = %{
      "packet_json" => record.packet_json,
      "schema" => Findings.schema(),
      "model" => loaded.public["model"],
      "max_output_tokens" => loaded.public["max_output_tokens"],
      "timeout_ms" => loaded.public["timeout_ms"]
    }

    adapter_opts =
      loaded.adapter_opts
      |> Keyword.put(:endpoint, loaded.endpoint)
      |> Keyword.merge(Keyword.get(opts, :review_adapter_opts, []))

    task =
      Task.Supervisor.async_nolink(
        Keyword.get(opts, :task_supervisor, Shoestring.Cobbler.PlannerTasks),
        fn -> loaded.adapter.review(input, adapter_opts) end
      )

    case Task.yield(task, loaded.public["timeout_ms"]) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{json: json, output_tokens: tokens}}}
      when is_binary(json) and is_integer(tokens) and tokens >= 0 ->
        if tokens <= loaded.public["max_output_tokens"] do
          case Findings.validate(json, Jason.decode!(record.packet_json)) do
            {:ok, result} -> {:ok, result, tokens}
            {:error, {kind, _field}} -> {:failed, Atom.to_string(kind), tokens}
          end
        else
          {:failed, "output_limit", tokens}
        end

      {:ok, {:error, code}} when is_atom(code) ->
        {:failed, Atom.to_string(code), nil}

      {:ok, _other} ->
        {:failed, "invalid_adapter_result", nil}

      {:exit, _} ->
        {:failed, "adapter_exit", nil}

      nil ->
        {:failed, "transport_timeout", nil}
    end
  end

  # The implementation must be exactly what was reviewed, before and after.
  defp finish(record, result, duration, ctx) do
    result =
      case {result, fresh(record)} do
        {_, {:error, reason}} -> {:failed, Atom.to_string(reason), elem_tokens(result)}
        {result, :ok} -> result
      end

    {state, extra, payload} =
      case result do
        {:ok, findings, tokens} ->
          json = PlanContract.canonical_json(findings)

          {findings["outcome"],
           %{result_json: json, result_digest: PlanContract.digest(findings)},
           %{
             "outcome" => findings["outcome"],
             "findings_json" => json,
             "blocking_count" => findings["blocking_count"],
             "output_tokens" => tokens
           }}

        {:failed, code, tokens} ->
          {"failed",
           %{errors: items([error(code, "The review call ended without usable findings.")])},
           %{"outcome" => "failed", "error_code" => code}
           |> then(&if(tokens, do: Map.put(&1, "output_tokens", tokens), else: &1))}
      end

    transact(fn ->
      current = Repo.get!(Record, record.id)

      if current.state != "running" or current.calls != record.calls,
        do: Repo.rollback(:review_attempt_changed)

      record =
        update!(
          current,
          Map.merge(extra, %{state: state, duration_ms: current.duration_ms + duration})
        )

      append!(
        record.goal_id,
        "cobbler.plan.task.reviewed",
        Map.merge(payload, %{
          "review_id" => record.id,
          "execution_id" => record.execution_id,
          "plan_task_id" => record.plan_task_id,
          "revision_number" => ctx.execution.revision_number,
          "plan_digest" => ctx.execution.plan_digest,
          "run_id" => record.run_id,
          "attempt" => record.attempt,
          "round" => record.round,
          "commit" => record.commit,
          "packet_digest" => record.packet_digest,
          "reviewer" => "#{record.configuration["provider_id"]}:#{record.configuration["model"]}",
          "duration_ms" => duration
        }),
        "plan-review-finished:#{record.id}:#{record.calls}",
        record.run_id
      )

      record
    end)
    |> case do
      {:ok, record} -> by_state(record, ctx)
      {:error, _} = error -> error
    end
  end

  defp elem_tokens({:ok, _findings, tokens}), do: tokens
  defp elem_tokens({:failed, _code, tokens}), do: tokens

  defp fail(record, reason, ctx) do
    errors = items([error(reason, "The review cannot run as recorded.")])

    with {:ok, _} <- save(record, %{state: "failed", errors: errors}, ctx.opts),
         do: {:pending, {:review_failed, Atom.to_string(reason)}}
  end

  # The worktree of the attempt is still at the reviewed commit, and clean.
  defp fresh(%Record{gates: %{"items" => [%{"worktree" => worktree} | _]}} = record) do
    with {:ok, %{exit_status: 0, output: head}} <-
           GateProcess.run(["git", "rev-parse", "HEAD"], worktree, 15_000, 1024),
         true <- String.trim(head) == record.commit,
         {:ok, %{exit_status: 0, output: ""}} <-
           GateProcess.run(
             ["git", "status", "--porcelain", "--untracked-files=normal"],
             worktree,
             15_000,
             65_536
           ) do
      :ok
    else
      _ -> {:error, :reviewed_commit_changed}
    end
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  # The call uses exactly the configuration recorded with the review; any
  # change since (including disabling review) stops it for a human.
  defp loaded(record, ctx) do
    case Configuration.load(ctx.execution, ctx.opts) do
      {:ok, {:required, %{public: public} = loaded}} when public == record.configuration ->
        {:ok, loaded}

      _ ->
        {:error, :review_configuration_changed}
    end
  end

  defp pending_decision(record) do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^record.goal_id and e.type == @decided,
        order_by: [desc: e.sequence]
    )
    |> Enum.find(&(&1.payload["review_id"] == record.id))
    |> case do
      nil -> nil
      %{id: id} when id == record.decision_id -> nil
      event -> if allowed?(record, event.payload["decision"]), do: event
    end
  end

  defp get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Record, id)
      :error -> nil
    end
  end

  defp confirmation(record) do
    events =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^record.goal_id and e.type in [@confirmed, "admission.decided"],
          order_by: [desc: e.sequence]
      )

    consumed =
      events
      |> Enum.filter(&(&1.type == "admission.decided"))
      |> MapSet.new(&get_in(&1.payload, ["extensions", @extension]))

    Enum.find(events, fn event ->
      event.type == @confirmed and event.payload["review_id"] == record.id and
        not MapSet.member?(consumed, event.id)
    end)
  end

  defp override(nil), do: nil

  defp override(event) do
    %{
      "confirmed_by" => event.payload["confirmed_by"],
      "confirmed_at" => DateTime.to_iso8601(event.occurred_at),
      "target_provider_id" => event.payload["provider_id"],
      "target_scope" => event.payload["scope"],
      "intent" => "read_only"
    }
  end

  defp snapshot(public, opts) do
    case Keyword.fetch(opts, :review_snapshot) do
      {:ok, %CapacitySnapshot{} = snapshot} ->
        snapshot

      {:ok, nil} ->
        nil

      :error ->
        if public["provider_id"] in ["claude", "codex"] do
          case WakeupObserve.observe(%{
                 provider_id: public["provider_id"],
                 scope: public["scope"]
               }) do
            {:ok, snapshot} -> snapshot
            _ -> nil
          end
        end
    end
  end

  defp occupied_by_other_goal?(goal_id) do
    case Commands.active_claim() do
      nil -> false
      %{goal_id: ^goal_id} -> false
      _ -> true
    end
  end

  defp fingerprints(%Record{} = record),
    do: record |> blocking_findings() |> MapSet.new(&Findings.fingerprint/1)

  defp review_summary(record, decision) do
    %{
      "review_id" => record.id,
      "state" => record.state,
      "round" => record.round,
      "packet_digest" => record.packet_digest,
      "reviewer" =>
        if(record.configuration["provider_id"],
          do: "#{record.configuration["provider_id"]}:#{record.configuration["model"]}",
          else: "unavailable:#{record.configuration["unavailable"]}"
        ),
      "blocking_count" => length(blocking_findings(record)),
      "decided_by" => decision && decision["decided_by"],
      "decision_reason" => decision && decision["reason"]
    }
  end

  defp blocked_detail(record, reason) do
    %{
      review_id: record.id,
      reason: String.slice(reason, 0, 2000),
      commit: record.commit,
      duration_ms: record.gates["items"] |> Enum.map(&(&1["duration_ms"] || 0)) |> Enum.sum(),
      review_ms: record.duration_ms
    }
  end

  defp view(record) do
    %{
      review_id: record.id,
      plan_task_id: record.plan_task_id,
      attempt: record.attempt,
      round: record.round,
      state: record.state,
      commit: record.commit,
      reviewer: record.configuration["provider_id"],
      model: record.configuration["model"],
      unavailable: record.configuration["unavailable"],
      reason: first_code(record),
      calls: record.calls,
      # A recorded decision the service has not applied yet no longer waits
      # for the human.
      decision_pending?: pending_decision(record) != nil,
      needs_user?: needs_user?(record) and pending_decision(record) == nil,
      findings:
        if(record.result_json, do: Jason.decode!(record.result_json)["findings"], else: [])
    }
  end

  defp first_code(%Record{errors: %{"items" => [%{"code" => code} | _]}}), do: code
  defp first_code(_record), do: nil

  defp error(code, message), do: %{"code" => to_string(code), "message" => message}
  defp items(list), do: %{"items" => list}

  defp save(record, attrs, _opts), do: transact(fn -> update!(record, attrs) end)

  # Compare-and-set on state and calls: a losing writer cannot overwrite.
  defp update!(record, attrs) do
    query =
      from r in Record,
        where: r.id == ^record.id and r.state == ^record.state and r.calls == ^record.calls

    case Repo.update_all(query, set: Map.to_list(attrs) ++ [updated_at: DateTime.utc_now()]) do
      {1, _} -> Repo.get!(Record, record.id)
      _ -> Repo.rollback(:review_attempt_changed)
    end
  end

  defp append(goal_id, type, payload, key, actor, trusted) do
    Trajectory.append(
      goal_id,
      %{
        "type" => type,
        "schema_version" => 1,
        "actor" => actor,
        "occurred_at" => DateTime.utc_now(),
        "idempotency_key" => key,
        "payload" => payload
      },
      trusted: trusted
    )
  end

  defp append!(goal_id, type, payload, key, run_id) do
    case Trajectory.append(
           goal_id,
           %{
             "type" => type,
             "schema_version" => 1,
             "actor" => "cobbler",
             "occurred_at" => DateTime.utc_now(),
             "idempotency_key" => key,
             "payload" => payload
           },
           trusted: [run_id: run_id],
           writer_opts: [transaction_repo: Repo]
         ) do
      {:ok, event} -> event
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transact(fun) do
    ReservationWriter.run(Repo, fn -> Repo.transaction(fun, mode: :immediate) end)
  rescue
    _ in [Exqlite.Error, DBConnection.ConnectionError] -> {:error, :review_database_busy}
    _ in [Ecto.ConstraintError, Ecto.StaleEntryError] -> {:error, :review_database_conflict}
  end
end
