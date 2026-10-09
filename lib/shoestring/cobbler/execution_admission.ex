defmodule Shoestring.Cobbler.ExecutionAdmission do
  @moduledoc "Fresh per-task admission from the provider-scoped Observatory ledger; no inference."
  alias Shoestring.Cobbler.{
    AdmissionDecision,
    AdmissionEvaluation,
    AdmissionPolicy,
    Commands,
    GoalLocalObservation,
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
         {:ok, decision} <-
           AdmissionEvaluation.evaluate(
             %{goal_id: goal_id, requested_capability: "supervised_execution", scope: scope},
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
             now: now,
             occupancy: occupied_by_other_goal?(goal_id)
           ),
         {:ok, event} <-
           Trajectory.append(goal_id, %{
             "type" => "admission.decided",
             "schema_version" => 1,
             "actor" => "cobbler",
             "occurred_at" => now,
             "payload" => AdmissionDecision.to_payload(decision)
           }) do
      if decision.result == :admit,
        do: {:ok, event.id},
        else: {:error, {:execution_admission_blocked, decision.reason_code}}
    else
      {:error, reason} -> {:error, {:execution_admission_blocked, reason}}
      _ -> {:error, {:execution_admission_blocked, :execution_profile_required}}
    end
  end

  defp occupied_by_other_goal?(goal_id) do
    case Commands.active_claim() do
      nil -> false
      %{goal_id: ^goal_id} -> false
      _ -> true
    end
  end
end
