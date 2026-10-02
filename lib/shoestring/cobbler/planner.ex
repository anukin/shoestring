defmodule Shoestring.Cobbler.Planner do
  @moduledoc """
  Bounded, quota-aware planner boundary: model-assisted decomposition that
  proposes plans without ever owning lifecycle, quotas, worktrees, dispatch,
  or approval.

  This is the domain entrypoint for planning. Like `Plans`, nothing here
  needs a LiveView: a goal can be planned through this module alone, which
  is what lets the eventual approval UI (package C) be a view over the
  domain rather than the place the domain lives.

  ## The request lifecycle

  1. **Validate.** Request inputs (human initiator, goal statement, resolved
     base revision, bounded constraints, trusted acceptance gates, explicit
     context references) are validated before anything is claimed. Planner
     attribution comes from the configured adapter, never from the caller,
     so a request cannot spoof which planner answered it.
  2. **Claim.** The request row is inserted (`in_progress`) with a
     `cobbler.planner.requested` event in one immediate write transaction.
     The `(goal_id, request_id)` unique index is the idempotency token: the
     same id with the same input digest replays the stored outcome with zero
     new invocations; the same id with a different digest is a conflict.
     The digest binds the semantic request identity (initiator, proposal
     id, parent, confirmation), so another initiator's identical bytes can
     never replay someone else's attribution.
  3. **Admit every invocation.** Each of the at-most-two invocations is
     evaluated through `AdmissionEvaluation` against a planner candidate
     and an explicit capacity snapshot, and each evaluation persists an
     `admission.decided` event. Only `:admit` invokes. A blocked planner
     settles to the queue/manual-plan path with zero invocations — reserves
     are never bypassed.
  4. **Invoke, at most twice.** One initial attempt plus at most one bounded
     repair after invalid schema/contract output. Transport failures,
     refusals, and unsafe proposals are terminal: they are never repaired
     and never retried. Repair errors travel back to the model as bounded
     field-level summaries, never as raw output.
  5. **Validate before persisting.** Output passes `PlannerSafety` (no
     reserve, lifecycle, dispatch, approval, destructive-integration,
     worktree-override, or command-bypass directives) and then the full
     `PlanContract` validation from package A, including planner-attribution
     echo and goal/base-revision binding to the request inputs. Only a
     valid contract reaches `Plans.propose/3`, authored by the human
     requester. Invalid output never creates a revision, and every
     persisted proposal stays `proposed`: the planner cannot approve.
  6. **Settle.** Success, failure, repair exhaustion, quota blocking, and
     explicit cancellation each settle the row and append a
     `cobbler.planner.resolved` event with a closed outcome/reason pair.
     Proposal persistence and request settlement commit atomically (one
     transaction; events publish only after it commits), so cancellation
     can never leave an orphan proposal behind for a cancelled request.
     Terminal rows never move; retry, replay, and restart converge on the
     stored outcome instead of duplicating invocations or resetting the
     attempt budget.

  ## Accounting

  Planner inference is admitted work, accounted in existing quota units:
  one `admission.decided` event per evaluation plus the durable two-attempt
  budget on the request row. Execution leases are deliberately not used
  here — leases bound Elf runs, and planning never runs an Elf. The
  admission gate plus the invocation budget is the reservation; the settled
  row plus the resolved event is the release.

  ## Not in this slice

  Dispatch and execution (package D), amendment/replan orchestration
  (package E), and the approval UI (package C) are absent. Validation
  errors surface through the structured `{:error, ...}` returns so C can
  render them; dispatch must still bind the approved authority at dispatch
  time (see `Plans`).
  """

  import Ecto.Query
  require Logger

  alias Shoestring.Cobbler.{
    AdmissionDecision,
    AdmissionEvaluation,
    PlannerFixture,
    PlannerPrompt,
    PlannerRequestRecord,
    PlannerSafety,
    PlanContract,
    Plans
  }

  alias Shoestring.Harness.Contract
  alias Shoestring.Repo
  alias Shoestring.Trajectory.Goal
  alias Shoestring.Trajectory.{EventRegistry, TrajectoryEvent}

  @actor "cobbler"
  @schema_version 1

  @event_types ["cobbler.planner.requested", "cobbler.planner.resolved"]

  @capability "plan_decomposition"
  @max_attempts 2
  @max_repair_errors 8
  @max_error_summary 2_000

  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,126}\z/
  @human_identity_pattern ~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/

  @type request_result ::
          {:ok,
           %{
             required(:request) => PlannerRequestRecord.t(),
             required(:revision) => Shoestring.Cobbler.PlanRevisionRecord.t() | nil,
             required(:outcome) => :recorded | :replayed,
             required(:events) => [TrajectoryEvent.t()]
           }}
          | {:error, term()}

  @doc "Canonical planner event types owned by this boundary."
  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  @doc "Maximum planning invocations for one request (initial plus one repair)."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc "The admission capability planner inference is evaluated under."
  @spec capability() :: String.t()
  def capability, do: @capability

  # ----------------------------------------------------------------------------
  # Requesting a plan
  # ----------------------------------------------------------------------------

  @doc """
  Requests a bounded plan proposal for a goal.

  `attrs` carries `request_id`, `requested_by` (a `human:` identity),
  `goal_statement`, `repository` (`base_revision` plus optional `remote_ref`),
  `acceptance` (trusted gates plus evidence), and optional `constraints`,
  `non_goals`, `context_refs`, `proposal_id`, `parent_revision_number`, and
  `confirmation` (an attributable admission override).

  Returns `{:ok, %{request, revision, outcome, events}}` on a valid
  proposal, or a structured `{:error, reason}` that package C can render:
  `{:invalid_planner_request, field, message}`, `:planner_not_configured`,
  `{:planner_request_conflict, detail}`,
  `{:planner_request_in_progress, detail}`,
  `{:planner_quota_blocked, detail}`,
  `{:planner_confirmation_required, detail}`,
  `{:planner_manual_required, detail}` (repair exhausted, with validation
  errors for user edit), `{:planner_transport_error, detail}`,
  `{:planner_refused, detail}`, or `{:planner_unsafe_proposal, detail}`.
  """
  @spec request_plan(Ecto.UUID.t(), map(), keyword()) :: request_result()
  def request_plan(goal_id, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, request_id} <- identifier(attrs, :request_id),
         {:ok, requested_by} <- human_identity(attrs, :requested_by),
         {:ok, proposal_id} <- proposal_id(attrs, request_id),
         {:ok, parent} <- optional_revision_number(attrs, :parent_revision_number),
         {:ok, confirmation} <- confirmation(attrs, :confirmation),
         {:ok, config} <- resolve_config(opts),
         :ok <- check_adapter_config(config, opts),
         {:ok, inputs} <- PlannerPrompt.normalize(planner_attrs(attrs, config)),
         {:ok, built} <- PlannerPrompt.build(inputs),
         :ok <- ensure_goal(repo, goal_id),
         :ok <- check_lineage(repo, goal_id, request_id, parent) do
      claim_and_run(
        repo,
        goal_id,
        request_id,
        requested_by,
        proposal_id,
        parent,
        confirmation,
        config,
        inputs,
        built,
        now(opts),
        opts
      )
    end
  end

  @doc """
  Explicitly cancels an in-progress planner request.

  `attrs` carries `cancelled_by` (a `human:` identity). Cancelling settles
  the request as `cancelled` with a `cobbler.planner.resolved` event and
  returns `{:ok, ...}`; cancelling an already-terminal request replays its
  stored outcome without touching it. Unknown requests are
  `:planner_request_not_found`. A planner invocation already in flight is
  not interrupted — cancellation settles the accounting, and a late
  settlement converges on the cancelled row rather than overwriting it.
  """
  @spec cancel(Ecto.UUID.t(), String.t(), map(), keyword()) :: request_result() | {:error, term()}
  def cancel(goal_id, request_id, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, request_id} <- identifier(%{request_id: request_id}, :request_id),
         {:ok, cancelled_by} <- human_identity(attrs, :cancelled_by),
         :ok <- ensure_goal(repo, goal_id) do
      cancel_transaction(repo, goal_id, request_id, cancelled_by, now(opts), opts)
    end
  end

  @doc "Returns one planner request row for a goal, or nil."
  @spec get_request(Ecto.UUID.t(), String.t(), keyword()) :: PlannerRequestRecord.t() | nil
  def get_request(goal_id, request_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, request_id} <- identifier(%{request_id: request_id}, :request_id) do
      existing_request(repo, goal_id, request_id)
    else
      _other -> nil
    end
  end

  @doc "Lists every planner request for a goal in request order."
  @spec list_requests(Ecto.UUID.t(), keyword()) :: [PlannerRequestRecord.t()]
  def list_requests(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case cast_goal_id(goal_id) do
      {:ok, goal_id} ->
        repo.all(
          from request in PlannerRequestRecord,
            where: request.goal_id == ^goal_id,
            order_by: [asc: request.inserted_at]
        )

      {:error, _reason} ->
        []
    end
  end

  # ----------------------------------------------------------------------------
  # Claim, admit, invoke, settle
  # ----------------------------------------------------------------------------

  defp claim_and_run(
         repo,
         goal_id,
         request_id,
         requested_by,
         proposal_id,
         parent,
         confirmation,
         config,
         inputs,
         built,
         now,
         opts
       ) do
    context = %{
      goal_id: goal_id,
      request_id: request_id,
      requested_by: requested_by,
      proposal_id: proposal_id,
      parent: parent,
      confirmation: confirmation,
      config: config,
      inputs: inputs,
      prompt: built.prompt,
      input_digest: built.input_digest,
      now: now,
      opts: opts
    }

    case claim(repo, context) do
      # The claim publishes its own events; the run publishes its own.
      # Nothing here publishes twice, and a replay invokes nothing.
      {:ok, %{request: request, outcome: :replayed}} ->
        replay_stored(repo, context, request)

      {:ok, %{request: request, outcome: :recorded}} ->
        run_attempts(repo, request, context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The claim inserts the request row and the `requested` event in one
  # immediate write transaction, before any admission or invocation. The
  # unique index decides every race: a loser with identical inputs converges
  # on the winner's stored outcome, a loser with different inputs gets a
  # conflict, and a loser arriving mid-flight gets an in-progress refusal.
  # Nothing here invokes the planner, so no race can duplicate an invocation.
  defp claim(repo, context) do
    repo
    |> run_transaction(fn -> claim_transaction(repo, context) end)
    |> case do
      {:ok, %{request: _request, outcome: _outcome} = result} ->
        publish(result.events, context.opts)
        {:ok, result}

      {:error, {:planner_request_in_progress, _detail} = reason} ->
        {:error, reason}

      {:error, _reason} = result ->
        case converge_claim(repo, context) do
          {:ok, _request, outcome} -> outcome
          :no_convergence -> result
        end
    end
  end

  defp claim_transaction(repo, context) do
    case existing_request(repo, context.goal_id, context.request_id) do
      %PlannerRequestRecord{input_digest: digest} = existing
      when digest == context.input_digest ->
        if PlannerRequestRecord.terminal?(existing) do
          %{request: existing, outcome: :replayed, events: []}
        else
          repo.rollback({:planner_request_in_progress, %{"request_id" => context.request_id}})
        end

      %PlannerRequestRecord{input_digest: existing_digest} ->
        repo.rollback(
          {:planner_request_conflict,
           %{
             "request_id" => context.request_id,
             "existing_digest" => existing_digest,
             "incoming_digest" => context.input_digest
           }}
        )

      nil ->
        record_claim(repo, context)
    end
  end

  defp record_claim(repo, context) do
    %{config: config, inputs: inputs} = context

    record =
      goal_id(context)
      |> PlannerRequestRecord.claim_changeset(
        %{
          request_id: context.request_id,
          requested_by: context.requested_by,
          planner_identity: config.planner_identity,
          planner_version: config.planner_version,
          planner_model: config.model,
          input_digest: context.input_digest,
          goal_statement: inputs.goal_statement,
          base_revision: inputs.base_revision,
          source_context_refs: %{
            "refs" => Enum.map(inputs.context_refs, &%{"ref" => &1.ref, "summary" => &1.summary})
          },
          proposal_id: context.proposal_id
        },
        context.now
      )
      |> repo.insert()
      |> case do
        {:ok, row} ->
          row

        {:error, changeset} ->
          repo.rollback(claim_insert_refusal(repo, context, changeset))
      end

    events =
      append_events(
        repo,
        context.goal_id,
        [requested_event(record, inputs, context)],
        context.now
      )

    %{request: record, outcome: :recorded, events: events}
  end

  # A writer that lost the claim race rolled its whole transaction back.
  # If the winner's row is now visible with identical inputs, the honest
  # answer is the convergence it always meant — terminal or in-progress —
  # rather than a storage error for a request that in fact landed.
  defp converge_claim(repo, context) do
    case existing_request(repo, context.goal_id, context.request_id) do
      %PlannerRequestRecord{input_digest: digest} = existing
      when digest == context.input_digest ->
        if PlannerRequestRecord.terminal?(existing) do
          {:ok, existing, replay_stored(repo, context, existing)}
        else
          {:ok, existing,
           {:error, {:planner_request_in_progress, %{"request_id" => context.request_id}}}}
        end

      _other ->
        :no_convergence
    end
  end

  defp claim_insert_refusal(repo, context, changeset) do
    if constraint_violated?(changeset, "cobbler_planner_requests_goal_id_request_id_index") do
      case existing_request(repo, context.goal_id, context.request_id) do
        %PlannerRequestRecord{input_digest: digest} when digest != context.input_digest ->
          {:planner_request_conflict,
           %{
             "request_id" => context.request_id,
             "existing_digest" => digest,
             "incoming_digest" => context.input_digest
           }}

        _other ->
          {:planner_request_race_lost, %{"request_id" => context.request_id}}
      end
    else
      {:planner_request_insert_failed, changeset}
    end
  end

  # ----------------------------------------------------------------------------
  # Attempts: admit, invoke, validate, settle
  # ----------------------------------------------------------------------------

  # Before invoking, check whether an earlier attempt already persisted the
  # revision (a crash between `Plans.propose` and settlement). Converging on
  # it keeps persistence exactly-once without spending another invocation.
  defp run_attempts(repo, request, context) do
    case persisted_revision(repo, context) do
      %{} = revision ->
        settle(repo, request, context, :proposed, "valid_plan", %{
          revision_number: revision.revision_number,
          plan_digest: revision.digest,
          admission_decision_ids: []
        })

      nil ->
        attempt(repo, request, context, request.attempts_used + 1, [], [])
    end
  end

  defp attempt(repo, request, context, attempt_number, repair_errors, decision_ids) do
    case admit(repo, request, context, attempt_number) do
      {:ok, request, decision} ->
        decision_ids = Enum.uniq(decision_ids ++ [decision.decision_id])

        case prompt_for(context, repair_errors) do
          {:ok, prompt} ->
            case invoke(context, attempt_number, prompt) do
              {:ok, raw} ->
                handle_output(repo, request, context, decision_ids, attempt_number, raw)

              {:error, {:planner_invalid_response, _detail}} ->
                schema_failure(repo, request, context, decision_ids, attempt_number, [
                  "The model response was not a plan object."
                ])

              {:error, {:planner_transport_error, detail}} ->
                settle(
                  repo,
                  recheck_request(repo, request),
                  context,
                  :failed,
                  "transport_error",
                  %{
                    error_summary: "Planner transport failed: #{detail_value(detail["reason"])}.",
                    error_extra: %{"reason" => detail_value(detail["reason"])},
                    admission_decision_ids: decision_ids
                  }
                )

              {:error, {:planner_refused, detail}} ->
                settle(
                  repo,
                  recheck_request(repo, request),
                  context,
                  :failed,
                  "refused",
                  %{
                    error_summary:
                      "The planner refused to plan: #{detail_value(detail["reason"])}.",
                    error_extra: %{"reason" => detail_value(detail["reason"])},
                    admission_decision_ids: decision_ids
                  }
                )

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            settle(repo, request, context, :manual_required, "repair_exhausted", %{
              error_summary:
                "The repair prompt exceeded its bounds: #{truncate(inspect(reason))}.",
              admission_decision_ids: decision_ids
            })
        end

      {:blocked, request, decision} ->
        settle_blocked(repo, request, context, decision)

      {:settled, result} ->
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One admission evaluation per invocation, persisted as an
  # `admission.decided` event in the same transaction that consumes the
  # attempt. Only `:admit` proceeds; every other result settles the request
  # on the queue/manual path with zero invocations.
  defp admit(repo, request, context, attempt_number) do
    fresh = recheck_request(repo, request)

    cond do
      PlannerRequestRecord.terminal?(fresh) ->
        # Settled while we were working (an explicit cancellation won the
        # race): converge on the stored outcome instead of spending more.
        {:settled, replay_stored(repo, context, fresh)}

      fresh.attempts_used >= fresh.max_attempts ->
        settle(repo, fresh, context, :manual_required, "repair_exhausted", %{
          error_summary: "No planning attempts remain.",
          admission_decision_ids: []
        })

      true ->
        evaluate_admission(repo, fresh, context, attempt_number)
    end
  end

  defp evaluate_admission(repo, request, context, _attempt_number) do
    snapshot = Keyword.get(context.opts, :capacity_snapshot)
    policy = planner_policy(context)

    decision_id = Ecto.UUID.generate()

    admission_request = %{
      requested_capability: @capability,
      scope: context.config.candidate.scope,
      goal_id: context.goal_id,
      override: context.confirmation
    }

    case AdmissionEvaluation.evaluate(
           admission_request,
           context.config.candidate,
           snapshot,
           policy,
           now: context.now,
           decision_id: decision_id,
           occupancy: planner_occupancy(repo, context)
         ) do
      {:ok, %AdmissionDecision{result: :admit} = decision} ->
        consume_admission(repo, request, context, decision)

      {:ok, %AdmissionDecision{} = decision} ->
        record_blocked_admission(repo, request, context, decision)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_admission(repo, request, context, decision) do
    repo
    |> run_transaction(fn ->
      current = recheck_request(repo, request)

      if PlannerRequestRecord.terminal?(current) do
        {:converged, current}
      else
        current
        |> PlannerRequestRecord.consume_attempt_changeset(context.now)
        |> repo.update()
        |> case do
          {:ok, updated} ->
            events =
              append_events(
                repo,
                context.goal_id,
                [admission_event(decision, context)],
                context.now
              )

            {updated, decision, events}

          {:error, changeset} ->
            repo.rollback({:planner_attempt_exhausted, changeset})
        end
      end
    end)
    |> case do
      {:ok, {:converged, current}} ->
        {:settled, replay_stored(repo, context, current)}

      {:ok, {updated, decision, events}} ->
        publish(events, context.opts)
        {:ok, updated, decision}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_blocked_admission(repo, request, context, decision) do
    repo
    |> run_transaction(fn ->
      events =
        append_events(repo, context.goal_id, [admission_event(decision, context)], context.now)

      {:blocked, recheck_request(repo, request), decision, events}
    end)
    |> case do
      {:ok, {:blocked, current, decision, events}} ->
        publish(events, context.opts)
        {:blocked, current, decision}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prompt_for(context, []) do
    {:ok, context.prompt}
  end

  defp prompt_for(context, repair_errors) do
    case PlannerPrompt.build(context_inputs(context), repair_errors: repair_errors) do
      {:ok, %{prompt: prompt}} -> {:ok, prompt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke(context, attempt_number, prompt) do
    adapter_opts =
      context.opts
      |> Keyword.take([
        :fixture,
        :call_log,
        :endpoint,
        :model,
        :api_key,
        :api_key_env,
        :timeout_ms,
        :max_body
      ])
      |> Keyword.put(:attempt, attempt_number)

    case context.config.adapter.plan(prompt, adapter_opts) do
      {:ok, plan} when is_map(plan) ->
        {:ok, plan}

      {:ok, _other} ->
        {:error,
         {:planner_invalid_response,
          short_detail(context, "model response was not a plan object")}}

      {:error, {:transport, detail}} ->
        {:error, {:planner_transport_error, short_detail(context, transport_summary(detail))}}

      {:error, {:refused, detail}} ->
        {:error, {:planner_refused, short_detail(context, transport_summary(detail))}}

      {:error, {:invalid_response, detail}} ->
        {:error, {:planner_invalid_response, short_detail(context, transport_summary(detail))}}

      {:error, reason} ->
        {:error,
         {:planner_transport_error,
          short_detail(context, "adapter error: #{truncate(inspect(reason))}")}}
    end
  end

  defp handle_output(repo, request, context, decision_ids, attempt_number, raw) do
    # A cancellation (or any settlement) that landed while the model was
    # answering wins: the late output is dropped, never persisted, and the
    # stored outcome is replayed. Staleness never interrupts useful work,
    # and it never resurrects it either.
    if PlannerRequestRecord.terminal?(recheck_request(repo, request)) do
      replay_stored(repo, context, recheck_request(repo, request))
    else
      handle_validated_output(repo, request, context, decision_ids, attempt_number, raw)
    end
  end

  defp handle_validated_output(repo, request, context, decision_ids, attempt_number, raw) do
    with :ok <- PlannerSafety.scan(raw),
         {:ok, contract} <- PlanContract.new(raw),
         :ok <- check_attribution(contract, context),
         :ok <- check_output_binding(contract, context),
         {:ok, _result} = recorded <-
           propose_and_settle(repo, request, context, contract, decision_ids) do
      recorded
    else
      {:error, {:unsafe_proposal, detail}} ->
        settle(repo, recheck_request(repo, request), context, :failed, "unsafe_proposal", %{
          error_summary:
            "Unsafe planner directive #{detail.directive} at #{Enum.join(detail.path, ".")}; no repair is attempted.",
          admission_decision_ids: decision_ids
        })

      {:error, reason} ->
        schema_failure(
          repo,
          request,
          context,
          decision_ids,
          attempt_number,
          summarize_contract_error(reason)
        )
    end
  end

  # Invalid schema/contract output gets exactly one bounded repair: the
  # second and final invocation carries the bounded error summaries. The
  # second failure — or any failure after a resumed attempt — settles the
  # request on the user-edit/manual path with the validation errors intact.
  defp schema_failure(repo, request, context, decision_ids, attempt_number, errors) do
    current = recheck_request(repo, request)

    if attempt_number < current.max_attempts and current.attempts_used < current.max_attempts do
      attempt(repo, current, context, attempt_number + 1, errors, decision_ids)
    else
      settle(repo, current, context, :manual_required, "repair_exhausted", %{
        error_summary:
          "Planning failed validation after #{current.attempts_used} attempts: #{Enum.join(errors, " ")}",
        error_extra: %{"validation_errors" => Enum.take(errors, @max_repair_errors)},
        admission_decision_ids: decision_ids
      })
    end
  end

  # ----------------------------------------------------------------------------
  # Settlement
  # ----------------------------------------------------------------------------

  defp settle_blocked(repo, request, context, decision) do
    {reason, error, tag, extra} =
      case decision.result do
        :defer_until ->
          {"quota_blocked",
           "Planner admission deferred (#{decision.reason_code}): #{decision.explanation}",
           :planner_quota_blocked,
           %{
             "reason_code" => decision.reason_code,
             "explanation" => truncate_summary(decision.explanation),
             "defer_until" => datetime_string(decision.defer_until)
           }}

        :require_confirmation ->
          {"confirmation_required",
           "Planner admission needs an attributable confirmation (#{decision.reason_code}): #{decision.explanation}",
           :planner_confirmation_required,
           %{
             "reason_code" => decision.reason_code,
             "explanation" => truncate_summary(decision.explanation)
           }}

        _other ->
          {"quota_blocked",
           "Planner admission refused (#{decision.reason_code}): #{decision.explanation}",
           :planner_quota_blocked,
           %{
             "reason_code" => decision.reason_code,
             "explanation" => truncate_summary(decision.explanation)
           }}
      end

    fields = %{
      error_summary: error,
      admission_decision_ids: [decision.decision_id]
    }

    # `settle/6` replays the durable row outcome; merge the admission facts
    # the row cannot carry (reason code, explanation, deferral) back over
    # the stored detail so the public error keeps the full accounting.
    case settle(repo, request, context, :manual_required, reason, fields) do
      {:error, {_settled_tag, detail}} when is_map(detail) ->
        {:error, {tag, Map.merge(extra, detail)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle(repo, request, context, status, reason, fields) do
    outcome =
      case status do
        :proposed -> :proposed
        :manual_required -> :manual_required
        :failed -> :failed
        :cancelled -> :cancelled
      end

    repo
    |> run_transaction(fn ->
      settle_transaction(repo, request, context, status, outcome, reason, fields)
    end)
    |> case do
      {:ok, %{request: updated, revision: revision, events: events}} ->
        publish(events, context.opts)

        if status == :proposed do
          {:ok, %{request: updated, revision: revision, outcome: :recorded, events: events}}
        else
          {:error, replay_error(updated)}
        end

      {:error, {:planner_already_settled, %{"request_id" => _request_id}}} ->
        replay_stored(repo, context, recheck_request(repo, request))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle_transaction(repo, request, context, status, outcome, reason, fields) do
    current = recheck_request(repo, request)

    if PlannerRequestRecord.terminal?(current) do
      repo.rollback({:planner_already_settled, %{"request_id" => request.request_id}})
    else
      decision_ids =
        (admission_ids(current) ++ Map.get(fields, :admission_decision_ids, [])) |> Enum.uniq()

      settle_attrs =
        %{status: Atom.to_string(status), admission_decision_ids: %{"ids" => decision_ids}}
        |> Map.merge(settlement_fields(reason, fields))

      current
      |> PlannerRequestRecord.settle_changeset(settle_attrs, context.now)
      |> repo.update()
      |> case do
        {:ok, updated} ->
          events =
            append_events(
              repo,
              context.goal_id,
              [resolved_event(updated, outcome, reason, fields, context)],
              context.now
            )

          %{request: updated, revision: settled_revision(repo, context, updated), events: events}

        {:error, changeset} ->
          repo.rollback({:planner_settle_failed, changeset})
      end
    end
  end

  # Terminal settlement always names WHY the request stopped: a proposal
  # names the revision and digest it created; every other stop records the
  # closed reason plus a bounded redacted summary. `error_detail` on the row
  # carries the structured detail the public error replays.
  defp settlement_fields("valid_plan", %{revision_number: number, plan_digest: digest}) do
    %{revision_number: number, plan_digest: digest, error_kind: nil, error_detail: nil}
  end

  defp settlement_fields(reason, %{error_summary: summary} = fields) do
    extra = Map.get(fields, :error_extra, %{})
    detail = Map.merge(%{"summary" => truncate_summary(summary)}, stringify_detail(extra))

    %{error_kind: reason, error_detail: detail}
  end

  defp settlement_fields(reason, _fields) do
    %{error_kind: reason, error_detail: %{"summary" => "The planner request stopped: #{reason}."}}
  end

  defp cancel_transaction(repo, goal_id, request_id, cancelled_by, now, opts) do
    context = %{goal_id: goal_id, request_id: request_id, now: now, opts: opts}

    case existing_request(repo, goal_id, request_id) do
      nil ->
        {:error, :planner_request_not_found}

      %PlannerRequestRecord{} = request ->
        if PlannerRequestRecord.terminal?(request) do
          case replay_stored(repo, context, request) do
            {:ok, _result} = ok ->
              ok

            {:error, _reason} ->
              {:ok, %{request: request, revision: nil, outcome: :replayed, events: []}}
          end
        else
          repo
          |> run_transaction(fn ->
            current = recheck_request(repo, request)

            if PlannerRequestRecord.terminal?(current) do
              repo.rollback({:planner_already_settled, %{"request_id" => request_id}})
            else
              current
              |> PlannerRequestRecord.settle_changeset(
                %{
                  status: "cancelled",
                  error_kind: "cancelled",
                  error_detail: %{
                    "summary" => "Cancelled by #{cancelled_by}.",
                    "cancelled_by" => cancelled_by
                  }
                },
                now
              )
              |> repo.update()
              |> case do
                {:ok, updated} ->
                  events =
                    append_events(
                      repo,
                      goal_id,
                      [resolved_event(updated, :cancelled, "cancelled", %{}, context)],
                      now
                    )

                  %{request: updated, revision: nil, events: events}

                {:error, changeset} ->
                  repo.rollback({:planner_settle_failed, changeset})
              end
            end
          end)
          |> case do
            {:ok, %{events: events, request: updated} = result} ->
              publish(events, opts)

              {:ok,
               %{request: updated, revision: result.revision, outcome: :recorded, events: events}}

            {:error, {:planner_already_settled, _detail}} ->
              current = recheck_request(repo, request)

              {:ok,
               %{
                 request: current,
                 revision: settled_revision(repo, context, current),
                 outcome: :replayed,
                 events: []
               }}

            {:error, _reason} = error ->
              error
          end
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Replay of stored outcomes (zero invocations)
  # ----------------------------------------------------------------------------

  defp replay_stored(repo, context, request) do
    case request.status do
      "proposed" ->
        case settled_revision(repo, context, request) do
          nil ->
            {:error, {:planner_replay_diverged, %{"request_id" => request.request_id}}}

          revision ->
            {:ok, %{request: request, revision: revision, outcome: :replayed, events: []}}
        end

      _other ->
        {:error, replay_error(request)}
    end
  end

  defp replay_error(request) do
    detail =
      case request.error_detail do
        content when is_map(content) -> content
        _other -> %{}
      end
      |> Map.put_new("request_id", request.request_id)
      |> Map.put_new("attempts_used", request.attempts_used)

    case request.error_kind do
      "quota_blocked" -> {:planner_quota_blocked, detail}
      "confirmation_required" -> {:planner_confirmation_required, detail}
      "repair_exhausted" -> {:planner_manual_required, detail}
      "transport_error" -> {:planner_transport_error, detail}
      "refused" -> {:planner_refused, detail}
      "unsafe_proposal" -> {:planner_unsafe_proposal, detail}
      "cancelled" -> {:planner_cancelled, detail}
      _other -> {:planner_failed, detail}
    end
  end

  defp settled_revision(repo, context, request) do
    if request.status == "proposed" and is_integer(request.revision_number) do
      Plans.get_revision(context.goal_id, request.revision_number, repo: repo)
    else
      nil
    end
  end

  defp persisted_revision(repo, context) do
    context.goal_id
    |> Plans.list_revisions(repo: repo)
    |> Enum.find(&(&1.proposal_id == context.proposal_id))
  end

  # ----------------------------------------------------------------------------
  # Rebuild from canonical events
  # ----------------------------------------------------------------------------

  @doc """
  Recomputes planner request states purely from canonical `cobbler.planner.*`
  events and reports divergence from stored rows without mutating anything.
  """
  @spec rebuild(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             requests: [map()],
             consistent?: boolean(),
             divergences: [String.t()]
           }}
          | {:error, term()}
  def rebuild(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         events <- fetch_planner_events(repo, goal_id),
         :ok <- validate_history(events),
         {:ok, state} <- fold_events(events) do
      rebuilt = state |> Map.values() |> Enum.sort_by(& &1["request_id"])
      divergences = rebuild_divergences(rebuilt, list_requests(goal_id, opts))

      {:ok, %{requests: rebuilt, consistent?: divergences == [], divergences: divergences}}
    end
  end

  defp fetch_planner_events(repo, goal_id) do
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
    Enum.reduce_while(events, {:ok, %{}}, fn event, {:ok, state} ->
      case fold_event(state, event) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fold_event(state, %TrajectoryEvent{type: "cobbler.planner.requested"} = event) do
    payload = event.payload
    request_id = payload["request_id"]

    if Map.has_key?(state, request_id) do
      {:error, {:rebuild_duplicate_request, event.sequence, request_id}}
    else
      {:ok,
       Map.put(state, request_id, %{
         "request_id" => request_id,
         "requested_by" => payload["requested_by"],
         "input_digest" => payload["input_digest"],
         "planner_identity" => payload["planner_identity"],
         "status" => "in_progress",
         "attempts_used" => 0,
         "revision_number" => nil,
         "plan_digest" => nil,
         "reason" => nil
       })}
    end
  end

  defp fold_event(state, %TrajectoryEvent{type: "cobbler.planner.resolved"} = event) do
    payload = event.payload
    request_id = payload["request_id"]

    case Map.fetch(state, request_id) do
      {:ok, entry} ->
        if entry["status"] == "in_progress" do
          {:ok,
           Map.put(state, request_id, %{
             entry
             | "status" => terminal_status(payload["outcome"]),
               "attempts_used" => payload["attempts_used"],
               "revision_number" => payload["revision_number"],
               "plan_digest" => payload["plan_digest"],
               "reason" => payload["reason"]
           })}
        else
          {:error, {:rebuild_double_settlement, event.sequence, request_id}}
        end

      :error ->
        {:error, {:rebuild_resolution_without_request, event.sequence, request_id}}
    end
  end

  defp terminal_status("proposed"), do: "proposed"
  defp terminal_status("manual_required"), do: "manual_required"
  defp terminal_status("failed"), do: "failed"
  defp terminal_status("cancelled"), do: "cancelled"

  defp rebuild_divergences(rebuilt, stored) do
    missing =
      for row <- stored,
          not Enum.any?(rebuilt, &(&1["request_id"] == row.request_id)),
          do: "request #{row.request_id} is stored but absent from events"

    mismatched =
      for row <- stored,
          entry = Enum.find(rebuilt, &(&1["request_id"] == row.request_id)),
          entry != nil,
          detail <- request_mismatch(entry, row),
          do: detail

    extra =
      for entry <- rebuilt,
          not Enum.any?(stored, &(&1.request_id == entry["request_id"])),
          do: "request #{entry["request_id"]} is in events but not stored"

    missing ++ mismatched ++ extra
  end

  defp request_mismatch(entry, row) do
    [
      {entry["input_digest"] != row.input_digest, "request #{row.request_id} digest diverges"},
      {entry["requested_by"] != row.requested_by, "request #{row.request_id} requester diverges"},
      {entry["status"] != row.status, "request #{row.request_id} status diverges"},
      {entry["attempts_used"] != row.attempts_used,
       "request #{row.request_id} attempt budget diverges"},
      {entry["revision_number"] != row.revision_number,
       "request #{row.request_id} revision diverges"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # ----------------------------------------------------------------------------
  # Configuration
  # ----------------------------------------------------------------------------

  @doc """
  Resolves the effective planner configuration.

  Application config (`config :shoestring, :planner`) supplies adapter,
  model, provider, candidate, and policy defaults; per-call opts override
  them. The default adapter is the deterministic fixture, so an
  unconfigured node can never spend quota or touch the network.
  """
  @spec resolve_config(keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_config(opts \\ []) do
    app_config = Application.get_env(:shoestring, :planner, [])
    adapter = Keyword.get(opts, :adapter, Keyword.get(app_config, :adapter, PlannerFixture))

    if planner_adapter?(adapter) do
      attribution = adapter_attribution(adapter)
      model = Keyword.get(opts, :model, Keyword.get(app_config, :model, attribution.model))

      provider_id =
        Keyword.get(opts, :provider_id, Keyword.get(app_config, :provider_id, "planner"))

      {:ok,
       %{
         adapter: adapter,
         model: model,
         provider_id: provider_id,
         planner_identity: attribution.identity,
         planner_version: attribution.version,
         candidate: planner_candidate(opts, app_config, provider_id),
         policy: planner_policy_value(opts, app_config)
       }}
    else
      {:error, {:invalid_planner_adapter, %{adapter: inspect(adapter)}}}
    end
  end

  # `function_exported?/3` reports false for a module that has not been
  # loaded yet, so ensure loading first: an unloadable name is not an
  # adapter, and a loaded one answers for itself.
  defp planner_adapter?(adapter) when is_atom(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :plan, 2)
  end

  defp planner_adapter?(_adapter), do: false

  defp adapter_attribution(adapter) do
    if function_exported?(adapter, :identity, 0) do
      adapter.identity()
    else
      %{identity: "unknown-planner", version: "0", model: "unknown"}
    end
  rescue
    _error -> %{identity: "unknown-planner", version: "0", model: "unknown"}
  end

  defp planner_candidate(opts, app_config, provider_id) do
    configured =
      Keyword.get(opts, :candidate, Keyword.get(app_config, :candidate, %{}))

    %{
      provider_id: provider_id,
      adapter_id:
        Map.get(configured, :adapter_id, Map.get(configured, "adapter_id", "cobbler.planner")),
      support_tier:
        Map.get(configured, :support_tier, Map.get(configured, "support_tier", :proactive)),
      compatibility_state:
        Map.get(
          configured,
          :compatibility_state,
          Map.get(configured, "compatibility_state", :compatible)
        ),
      scope: Map.get(configured, :scope, Map.get(configured, "scope", "account:#{provider_id}")),
      capabilities:
        Map.get(configured, :capabilities, Map.get(configured, "capabilities", [@capability]))
    }
  end

  defp planner_policy_value(opts, app_config) do
    Keyword.get(opts, :policy, Keyword.get(app_config, :policy))
  end

  defp planner_policy(context), do: context.config.policy

  # Shared planner-inference reservation from authoritative durable state:
  # any other in-progress planner request (any goal) occupies the shared
  # account scope until it settles, so concurrent requests cannot invoke
  # from the same headroom. Terminal rows release; explicit human
  # cancellation releases a stuck row. The requesting row itself is
  # excluded, so a bounded repair re-admits. Occupancy is an unbypassable
  # hard stop downstream: confirmation cannot override it, and a blocked
  # request settles to the manual path with zero invocations.
  defp planner_occupancy(repo, context) do
    scope = context.config.candidate.scope

    occupied? =
      repo.exists?(
        from request in PlannerRequestRecord,
          where:
            request.status == "in_progress" and
              (request.goal_id != ^context.goal_id or
                 request.request_id != ^context.request_id)
      )

    if occupied?, do: %{scope => true}, else: false
  end

  # Adapter configuration is validated before anything is claimed,
  # admitted, or invoked: an unconfigured planner is a structured refusal
  # with zero accounting, never a transport failure after spending an
  # attempt. Adapters without a `configured/1` boundary (like the
  # fixture) are always usable.
  defp check_adapter_config(%{adapter: adapter}, opts) do
    adapter_opts =
      Keyword.take(opts, [
        :fixture,
        :call_log,
        :endpoint,
        :model,
        :api_key,
        :api_key_env,
        :timeout_ms,
        :max_body
      ])

    if function_exported?(adapter, :configured, 1) do
      case adapter.configured(adapter_opts) do
        {:ok, _config} -> :ok
        {:error, :planner_not_configured} -> {:error, :planner_not_configured}
      end
    else
      :ok
    end
  end

  # ----------------------------------------------------------------------------
  # Events
  # ----------------------------------------------------------------------------

  defp requested_event(record, inputs, context) do
    payload =
      %{
        "request_id" => record.request_id,
        "requested_by" => record.requested_by,
        "planner_identity" => record.planner_identity,
        "planner_version" => record.planner_version,
        "planner_model" => record.planner_model,
        "input_digest" => record.input_digest,
        "goal_statement" => record.goal_statement,
        "base_revision" => record.base_revision,
        "attempt_budget" => record.max_attempts,
        "constraints" => inputs.constraints,
        "non_goals" => inputs.non_goals,
        "acceptance_gates" => gate_names(inputs.acceptance),
        "acceptance_evidence" => inputs.acceptance["evidence"],
        "source_context_refs" =>
          Enum.map(inputs.context_refs, &%{"ref" => &1.ref, "summary" => &1.summary}),
        "proposal_id" => record.proposal_id
      }
      |> maybe_put("remote_ref", inputs[:remote_ref])
      |> maybe_put("parent_revision_number", context.parent)

    %{"type" => "cobbler.planner.requested", "payload" => payload}
  end

  defp resolved_event(request, outcome, reason, fields, context) do
    payload =
      %{
        "request_id" => request.request_id,
        "outcome" => Atom.to_string(outcome),
        "reason" => reason,
        "attempts_used" => request.attempts_used,
        "decided_at" => DateTime.to_iso8601(context.now),
        "planner_identity" => request.planner_identity,
        "admission_decision_ids" => admission_ids(request)
      }
      |> maybe_put("proposal_id", request.proposal_id)
      |> merge_settlement(fields)

    %{"type" => "cobbler.planner.resolved", "payload" => payload}
  end

  defp merge_settlement(payload, %{revision_number: number, plan_digest: digest}) do
    payload |> Map.put("revision_number", number) |> Map.put("plan_digest", digest)
  end

  defp merge_settlement(payload, %{error_summary: summary}) do
    Map.put(payload, "error_summary", truncate_summary(summary))
  end

  defp merge_settlement(payload, _fields), do: payload

  defp admission_event(%AdmissionDecision{} = decision, _context) do
    %{
      "type" => "admission.decided",
      "payload" => AdmissionDecision.to_payload(decision)
    }
  end

  # ----------------------------------------------------------------------------
  # Contract validation and persistence helpers
  # ----------------------------------------------------------------------------

  # Proposal persistence and request settlement commit atomically: the
  # revision row, the plan event, the settled request row, and the resolved
  # event land in one immediate transaction, and every event publishes only
  # after that commit. A cancellation that lands first forces the whole
  # transaction back (no orphan revision, no proposal event); a
  # cancellation that lands after finds a settled request and converges on
  # it. Either way the two can never disagree.
  defp propose_and_settle(repo, request, context, contract, decision_ids) do
    result =
      repo
      |> run_transaction(fn ->
        case propose_quiet(repo, context, contract) do
          {:ok, %{revision: revision, events: propose_events}} ->
            fields = %{
              revision_number: revision.revision_number,
              plan_digest: revision.digest,
              admission_decision_ids: decision_ids
            }

            settled =
              settle_transaction(
                repo,
                request,
                context,
                :proposed,
                :proposed,
                "valid_plan",
                fields
              )

            %{settled | events: propose_events ++ settled.events}

          {:error, reason} ->
            repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{events: events} = committed} ->
        publish(events, context.opts)

        {:ok,
         %{
           request: committed.request,
           revision: committed.revision,
           outcome: :recorded,
           events: events
         }}

      {:error, {:planner_already_settled, %{"request_id" => _request_id}}} ->
        replay_stored(repo, context, recheck_request(repo, request))

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Plans.propose with publication suppressed: its events join the outer
  # transaction and publish with everything else only on commit, so a
  # rolled-back proposal never broadcasts.
  defp propose_quiet(repo, context, contract) do
    attrs =
      %{
        proposal_id: context.proposal_id,
        authored_by: context.requested_by,
        plan: contract_to_attrs(contract)
      }
      |> maybe_put_parent(context.parent)

    propose_opts = [repo: repo, now: context.now, publish_fun: fn _event -> :ok end]

    case Plans.propose(context.goal_id, attrs, propose_opts) do
      {:ok, %{revision: revision, events: events}} -> {:ok, %{revision: revision, events: events}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp contract_to_attrs(contract) do
    # `Plans.propose/3` re-validates through `PlanContract.new/1`; passing
    # the already-normalized content back through exercises the same strict
    # boundary a human-authored proposal meets.
    contract.content
  end

  defp maybe_put_parent(attrs, nil), do: attrs
  defp maybe_put_parent(attrs, parent), do: Map.put(attrs, :parent_revision_number, parent)

  defp check_attribution(contract, context) do
    planner = contract.content["planner"] || %{}

    if planner["identity"] == context.config.planner_identity and
         planner["version"] == context.config.planner_version do
      :ok
    else
      {:error,
       {:invalid_plan_provenance,
        "planner block must echo #{context.config.planner_identity} version #{context.config.planner_version}"}}
    end
  end

  # A validly shaped plan can still answer the wrong goal. The returned
  # goal statement and base revision must echo the request inputs exactly;
  # anything else is a contract failure routed to the single bounded
  # repair, never persisted.
  defp check_output_binding(contract, context) do
    goal = contract.content["goal"] || %{}
    repository = goal["repository"] || %{}

    if goal["statement"] == context.inputs.goal_statement and
         repository["base_revision"] == context.inputs.base_revision do
      :ok
    else
      {:error,
       {:plan_goal_mismatch,
        "the plan answers a different goal or base revision than the request named"}}
    end
  end

  defp summarize_contract_error({:invalid_plan, changeset}) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", truncate(inspect(value)))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
    |> Enum.map(&truncate/1)
    |> Enum.take(@max_repair_errors)
    |> case do
      [] -> ["The plan failed validation."]
      errors -> errors
    end
  end

  defp summarize_contract_error({:invalid_graph, reason}),
    do: ["The task graph is invalid: #{truncate(inspect(reason))}."]

  defp summarize_contract_error({:forbidden_command_field, %{path: path, key: key}}),
    do: ["Forbidden command field #{key} at #{Enum.join(path, ".")}."]

  defp summarize_contract_error({:plan_too_large, %{bytes: bytes, limit: limit}}),
    do: ["The plan is #{bytes} bytes; the limit is #{limit}."]

  defp summarize_contract_error(
         {:budget_exceeded, %{field: field, declared: declared, required: required}}
       ),
       do: ["Budget #{field} declares #{declared} but the tasks require #{required}."]

  defp summarize_contract_error({:malformed_plan_json, reason}),
    do: ["The plan rendering is malformed: #{truncate(inspect(reason))}."]

  defp summarize_contract_error({:invalid_plan_provenance, message}), do: [truncate(message)]

  defp summarize_contract_error({:plan_goal_mismatch, message}), do: [truncate(message)]

  defp summarize_contract_error({:plan_proposal_conflict, _detail}),
    do: ["The proposal id is already taken by different content."]

  defp summarize_contract_error({:approved_task_identity_dropped, %{"missing" => missing}}),
    do: ["The plan drops approved task identities: #{Enum.join(Enum.take(missing, 8), ", ")}."]

  defp summarize_contract_error({:plan_parent_required, _detail}),
    do: ["The goal already has revisions; name a parent revision number."]

  defp summarize_contract_error({:plan_parent_not_found, _detail}),
    do: ["The named parent revision does not exist for this goal."]

  defp summarize_contract_error(reason),
    do: ["The plan was refused: #{truncate(inspect(reason))}."]

  # ----------------------------------------------------------------------------
  # Request attribute validation
  # ----------------------------------------------------------------------------

  defp planner_attrs(attrs, config) do
    shared = [
      "goal_statement",
      "repository",
      "constraints",
      "non_goals",
      "acceptance",
      "context_refs"
    ]

    planner = %{
      "identity" => config.planner_identity,
      "version" => config.planner_version,
      "model" => config.model
    }

    stringified = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    taken =
      stringified
      |> Map.take(shared)
      |> Map.put("requested_by", stringified["requested_by"])
      |> Map.put("proposal_id", stringified["proposal_id"] || stringified["request_id"])
      |> Map.put("parent_revision_number", stringified["parent_revision_number"])
      |> Map.put("confirmation", stringified["confirmation"])

    taken
    |> Map.put("planner", planner)
    |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp identifier(attrs, field) do
    case Contract.fetch(attrs, field) do
      {:ok, value} when is_binary(value) ->
        if Regex.match?(@id_pattern, value) do
          {:ok, value}
        else
          {:error, {:invalid_planner_request, field, "must be a bounded identifier"}}
        end

      _other ->
        {:error, {:invalid_planner_request, field, "can't be blank"}}
    end
  end

  defp human_identity(attrs, field) do
    case Contract.fetch(attrs, field) do
      {:ok, value} when is_binary(value) ->
        if Regex.match?(@human_identity_pattern, value) do
          {:ok, value}
        else
          {:error, {:non_human_identity, %{"field" => field, "value" => value}}}
        end

      _other ->
        {:error, {:invalid_planner_request, field, "can't be blank"}}
    end
  end

  defp proposal_id(attrs, request_id) do
    case Contract.fetch(attrs, :proposal_id) do
      :error -> {:ok, request_id}
      {:ok, nil} -> {:ok, request_id}
      {:ok, value} -> identifier(%{proposal_id: value}, :proposal_id)
    end
  end

  defp optional_revision_number(attrs, field) do
    case Contract.fetch(attrs, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:invalid_planner_request, field, "must be a positive integer"}}
    end
  end

  # An attributable confirmation names the human accepting manual
  # responsibility for a degraded-capacity plan. Non-human or blank
  # confirmations are refused rather than silently dropped.
  defp confirmation(attrs, field) do
    case Contract.fetch(attrs, field) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, override} when is_map(override) ->
        case Contract.fetch(override, :confirmed_by) do
          {:ok, confirmed_by} when is_binary(confirmed_by) ->
            if Regex.match?(@human_identity_pattern, confirmed_by) do
              {:ok, override}
            else
              {:error,
               {:invalid_planner_request, field, "confirmation must name a human identity"}}
            end

          _other ->
            {:error, {:invalid_planner_request, field, "confirmation must name who confirmed"}}
        end

      _other ->
        {:error, {:invalid_planner_request, field, "must be an object"}}
    end
  end

  # Lineage is enforced for fresh request ids only. When the id was
  # already claimed, the claim owns the answer — an identical digest
  # replays the stored outcome, a different digest is a conflict, and a
  # mid-flight id is refused as in-progress — so a replay or conflict
  # report is never masked by a lineage refusal. Fresh ids that would
  # silently branch an existing revision history are refused before any
  # claim, admission, or invocation.
  defp check_lineage(repo, goal_id, request_id, parent) do
    case existing_request(repo, goal_id, request_id) do
      %PlannerRequestRecord{} -> :ok
      nil -> check_lineage_parent(repo, goal_id, parent)
    end
  end

  defp check_lineage_parent(repo, goal_id, parent) do
    revisions = Plans.list_revisions(goal_id, repo: repo)

    cond do
      revisions == [] and is_nil(parent) ->
        :ok

      revisions == [] ->
        {:error,
         {:invalid_planner_request, :parent_revision_number, "the goal has no revisions yet"}}

      is_nil(parent) ->
        {:error,
         {:invalid_planner_request, :parent_revision_number,
          "the goal already has revisions; name a parent revision number"}}

      Enum.any?(revisions, &(&1.revision_number == parent)) ->
        :ok

      true ->
        {:error,
         {:invalid_planner_request, :parent_revision_number,
          "the named parent revision does not exist"}}
    end
  end

  # ----------------------------------------------------------------------------
  # Shared store helpers
  # ----------------------------------------------------------------------------

  defp goal_id(context), do: context.goal_id

  defp context_inputs(context), do: context.inputs

  defp recheck_request(repo, request) do
    existing_request(repo, request.goal_id, request.request_id) || request
  end

  defp existing_request(repo, goal_id, request_id) do
    repo.one(
      from request in PlannerRequestRecord,
        where: request.goal_id == ^goal_id and request.request_id == ^request_id
    )
  end

  defp ensure_goal(repo, goal_id) do
    if repo.exists?(from goal in Goal, where: goal.id == ^goal_id) do
      :ok
    else
      {:error, :goal_not_found}
    end
  end

  defp constraint_violated?(changeset, index_name) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == index_name
    end)
  end

  defp run_transaction(repo, fun) do
    repo.transaction(fun, mode: :immediate)
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      {:error, {:database_busy, Exception.message(error)}}

    error in [Ecto.StaleEntryError, Ecto.ConstraintError, Ecto.MultiplePrimaryKeyError] ->
      {:error,
       {:database_conflict,
        %{"kind" => inspect(error.__struct__), "message" => Exception.message(error)}}}
  end

  defp append_events(repo, goal_id, inputs, now) do
    base = next_sequence(repo, goal_id)

    Enum.with_index(inputs, fn input, index ->
      append_one_event(repo, goal_id, input, base + index, now)
    end)
  end

  defp append_one_event(repo, goal_id, input, sequence, now) do
    occurred_at = Map.get(input, "occurred_at", now)

    try do
      with {:ok, payload} <-
             EventRegistry.validate_payload(input["type"], @schema_version, input["payload"],
               now: now
             ),
           {:ok, event} <- insert_event(repo, goal_id, input, payload, sequence, occurred_at) do
        event
      else
        {:error, reason} -> repo.rollback({:event_append_failed, input["type"], reason})
      end
    rescue
      error in [Ecto.ConstraintError] ->
        repo.rollback({:event_append_failed, input["type"], error})
    end
  end

  defp insert_event(repo, goal_id, input, payload, sequence, occurred_at) do
    %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: goal_id,
      task_id: nil,
      run_id: nil,
      sequence: sequence,
      parent_event_id: nil,
      type: input["type"],
      actor: @actor,
      occurred_at: occurred_at,
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
      Logger.warning("cobbler planner event publish failed: #{Exception.message(error)}")
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

  defp gate_names(%{"gates" => gates}) when is_list(gates) do
    gates |> Enum.map(& &1["gate"]) |> Enum.filter(&is_binary/1)
  end

  defp gate_names(_acceptance), do: []

  defp admission_ids(request) do
    case request.admission_decision_ids do
      %{"ids" => ids} when is_list(ids) -> ids
      _other -> []
    end
  end

  # Error extras stay small, string-keyed, and JSON-safe: bounded lists of
  # bounded strings only. Anything else collapses to its truncated inspect.
  defp stringify_detail(extra) when is_map(extra) do
    Map.new(extra, fn {key, value} -> {to_string(key), detail_value(value)} end)
  end

  defp stringify_detail(_extra), do: %{}

  defp detail_value(values) when is_list(values),
    do: values |> Enum.take(8) |> Enum.map(&truncate/1)

  defp detail_value(value) when is_binary(value), do: truncate(value)
  defp detail_value(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp detail_value(value), do: truncate(inspect(value))

  defp datetime_string(nil), do: nil
  defp datetime_string(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp transport_summary(detail) when is_map(detail) do
    case Map.get(detail, "reason") do
      reason when is_binary(reason) -> truncate(reason)
      _other -> "the planner could not be reached"
    end
  end

  defp transport_summary(_detail), do: "the planner could not be reached"

  defp short_detail(context, summary) do
    %{"request_id" => context.request_id, "reason" => truncate(summary)}
  end

  defp truncate(text) when is_binary(text) do
    if String.length(text) > 300, do: String.slice(text, 0, 300), else: text
  end

  defp truncate(other), do: other |> inspect() |> truncate()

  # Error summaries travel to the resolved event (cap 2 000) and into the
  # repair prompt; fragments above stay at the 300-character bound.
  defp truncate_summary(text) when is_binary(text) do
    if String.length(text) > @max_error_summary,
      do: String.slice(text, 0, @max_error_summary),
      else: text
  end

  defp truncate_summary(other), do: other |> inspect() |> truncate_summary()
end
