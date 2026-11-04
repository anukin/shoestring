defmodule Shoestring.Cobbler.ExecutionAdmission do
  @moduledoc "Fresh per-task admission from the provider-scoped Observatory ledger; no inference."
  alias Shoestring.Cobbler.{
    AdmissionDecision,
    AdmissionEvaluation,
    AdmissionPolicy,
    Parallelism,
    GoalLocalObservation,
    PlanCapacityConfirmation,
    WakeupObserve
  }

  alias Shoestring.Harness.{Clock, EventPayload, Projector}
  alias Shoestring.Trajectory

  def admit(goal_id, execution, task, attempt) do
    profile = execution[:agent_profile]
    clock = Application.get_env(:shoestring, :dispatch_clock, Shoestring.Harness.SystemClock)
    now = Clock.now(clock)
    scope = Application.get_env(:shoestring, :run_submission_scope, "subscription")

    with %{} <- profile,
         :ok <- codex_collection_clear(profile, scope),
         :ok <- record_unobservable(profile, scope),
         {:ok, observed} <-
           WakeupObserve.observe(%{provider_id: profile["provider"], scope: scope}),
         {:ok, snapshot} <-
           GoalLocalObservation.localize(
             observed,
             "submission",
             goal_id,
             "#{execution.execution_id}:#{task["id"]}:#{attempt}"
           ),
         {:ok, _} <-
           Trajectory.append(goal_id, %{
             "type" => "capacity.snapshot_observed",
             "schema_version" => 2,
             "actor" => "cobbler",
             # Keep the original observation's state valid at its own time;
             # admission below judges freshness at the current clock.
             "occurred_at" => snapshot.observed_at || now,
             "idempotency_key" => "submission-snapshot:#{snapshot.snapshot_id}",
             "payload" => EventPayload.capacity_snapshot(snapshot, nil)
           }),
         {:ok, _} <- Projector.project(goal_id),
         confirmation =
           PlanCapacityConfirmation.available(goal_id, execution, task, attempt, scope),
         {:ok, decision} <-
           AdmissionEvaluation.evaluate(
             %{
               goal_id: goal_id,
               requested_capability: "supervised_execution",
               scope: scope,
               override: PlanCapacityConfirmation.override(confirmation)
             },
             %{
               provider_id: profile["provider"],
               adapter_id: profile["adapter_id"],
               scope: scope,
               support_tier: snapshot.support_tier,
               compatibility_state: snapshot.compatibility_state,
               capabilities: ["supervised_execution"]
             },
             snapshot,
             %{
               AdmissionPolicy.default()
               | deadline_seconds: min(task["execution"]["max_duration_seconds"], 300)
             },
             evaluation_options(now, occupancy(goal_id, execution, task, profile), confirmation)
           ),
         {:ok, event} <-
           Trajectory.append(goal_id, %{
             "type" => "admission.decided",
             "schema_version" => 1,
             "actor" => "cobbler",
             "occurred_at" => now,
             "idempotency_key" =>
               if(confirmation, do: "plan-capacity-decision:#{confirmation.id}"),
             "payload" => AdmissionDecision.to_payload(decision)
           }) do
      cond do
        decision.result != :admit ->
          {:error, {:execution_admission_blocked, decision.reason_code}}

        event.payload["result"] != "admit" ->
          {:error, {:execution_admission_blocked, event.payload["reason_code"]}}

        true ->
          _ =
            Shoestring.Measurement.Brackets.before(
              goal_id,
              to_string(profile["provider"]),
              scope,
              Shoestring.Measurement.Brackets.context(execution.execution_id, task["id"], attempt)
            )

          {:ok, event.id}
      end
    else
      {:error, reason} ->
        waiting(goal_id, execution, task, attempt, profile, scope, now, reason)
        {:error, {:execution_admission_blocked, reason}}

      _ ->
        {:error, {:execution_admission_blocked, :execution_profile_required}}
    end
  end

  # opencode exposes no capacity reading and has no monitor, so the
  # Observatory would never hold one and admission would wait forever. The
  # adapter's honest unknown reading is recorded instead; admission then asks
  # for the usual attributable confirmation, never admitting on its own.
  defp record_unobservable(%{"provider" => "opencode"}, scope) do
    {:ok, snapshot} = Shoestring.Harness.OpencodeAcp.probe(%{scope: scope})

    case Shoestring.Harness.Observatory.ingest(snapshot) do
      {:ok, _outcome, _snapshot} -> :ok
      {:error, _reason} -> {:error, :observation_unavailable}
    end
  end

  defp record_unobservable(_profile, _scope), do: :ok

  # An `openai/…` opencode model draws on the ChatGPT subscription Codex
  # measures, and Shoestring cannot see that use. While a Codex collection
  # window is open such a run would be unattributed external use inside it, so
  # it waits until the window is closed.
  defp codex_collection_clear(%{"provider" => "opencode", "model" => "openai/" <> _}, scope) do
    open =
      Shoestring.Measurement.Collection.list()
      |> Enum.any?(&(&1.provider == "codex" and &1.scope == scope and is_nil(&1.closed_at)))

    if open, do: {:error, :codex_collection_window_open}, else: :ok
  end

  defp codex_collection_clear(_profile, _scope), do: :ok

  # A failure before any admission decision (no capacity reading for the
  # provider, for example) would otherwise leave nothing a human can see:
  # the job retries every minute without a trace. It is recorded once per
  # attempt and reason.
  defp waiting(goal_id, execution, task, attempt, %{} = profile, scope, now, reason) do
    code = reason_code(reason)

    _ =
      Trajectory.append(goal_id, %{
        "type" => "cobbler.plan.admission.waiting",
        "schema_version" => 1,
        "actor" => "cobbler",
        "occurred_at" => now,
        "idempotency_key" =>
          "plan-admission-waiting:#{execution.execution_id}:#{task["id"]}:#{attempt}:#{code}",
        "payload" => %{
          "execution_id" => execution.execution_id,
          "plan_task_id" => task["id"],
          "attempt" => attempt,
          "provider_id" => to_string(profile["provider"]),
          "scope" => scope,
          "reason" => code
        }
      })

    :ok
  end

  defp waiting(_goal_id, _execution, _task, _attempt, _profile, _scope, _now, _reason), do: :ok

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "admission_unavailable"

  @wait_key "shoestring.parallel:wait"

  defp occupancy(goal_id, execution, task, profile) do
    scope = Application.get_env(:shoestring, :run_submission_scope, "subscription")
    opts = [task: task, repository: execution[:repository_path]]
    Parallelism.occupancy(goal_id, profile["provider"], scope, opts)
  end

  @doc false
  def wait_key, do: @wait_key

  # At Settings' parallel tasks 2 or more an occupied scope also records why
  # (every place taken, or files overlapping another running dispatch), so
  # `follow` can say it. At 1 the decision is exactly what it always was.
  defp evaluation_options(now, occupancy, confirmation) do
    options = [now: now, occupancy: occupancy != nil]
    confirmed = PlanCapacityConfirmation.evaluation_options(confirmation)

    case occupancy do
      %{"limit" => limit} = wait when is_integer(limit) ->
        extensions = Map.put(Keyword.get(confirmed, :extensions, %{}), @wait_key, wait)
        options ++ Keyword.put(confirmed, :extensions, extensions)

      _ ->
        options ++ confirmed
    end
  end
end
