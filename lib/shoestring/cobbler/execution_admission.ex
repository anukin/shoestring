defmodule Shoestring.Cobbler.ExecutionAdmission do
  @moduledoc "Fresh per-task admission from the provider-scoped Observatory ledger; no inference."
  alias Shoestring.Cobbler.{
    AdmissionDecision,
    AdmissionEvaluation,
    AdmissionPolicy,
    Commands,
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
             "occurred_at" => now,
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
             [now: now, occupancy: occupied_by_other_goal?(goal_id)] ++
               PlanCapacityConfirmation.evaluation_options(confirmation)
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

  defp occupied_by_other_goal?(goal_id) do
    case Commands.active_claim() do
      nil -> false
      %{goal_id: ^goal_id} -> false
      _ -> true
    end
  end
end
