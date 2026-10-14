defmodule Shoestring.Cobbler.PlanScopeCheck do
  @moduledoc "Record deterministic declared-scope evidence for approved, unstarted ready tasks."
  alias Shoestring.Cobbler.{PlanContract, PlanExecutor, PlanIndependence, Plans, ScopeEvidence}
  alias Shoestring.Repo
  alias Shoestring.Trajectory

  def record(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, status} <- PlanExecutor.status(goal_id, opts),
         %{execution: execution, planned?: true} <- status,
         %{revision: revision} <- Plans.authority(goal_id, repo: repo),
         true <-
           revision.revision_number == execution.revision_number and
             revision.digest == execution.plan_digest,
         {:ok, contract} <- PlanContract.new(revision.content),
         path when is_binary(path) <-
           execution[:repository_path] || Keyword.get(opts, :repository_path) do
      accepted = MapSet.new(status.accepted)
      required = MapSet.new(PlanContract.required_task_ids(contract))

      tasks =
        Enum.filter(contract.content["tasks"], fn task ->
          MapSet.member?(required, task["id"]) and not Map.has_key?(status.attempts, task["id"]) and
            Enum.all?(task["depends_on"], &MapSet.member?(accepted, &1))
        end)

      base = get_in(contract.content, ["goal", "repository", "base_revision"])

      {metadata, observation} =
        case ScopeEvidence.repository(path, base) do
          {:ok, metadata} -> {metadata, "verified_accepted_base"}
          {:error, reason} -> {%{verified?: false}, to_string(reason)}
        end

      decision = PlanIndependence.declared(tasks, metadata)

      decision =
        if not is_nil(status.active_run_id) or status.needs_user?,
          do: Map.merge(decision, %{"disposition" => "sequential", "execution_blocked" => true}),
          else: decision

      payload = %{
        "execution_id" => execution.execution_id,
        "revision_number" => execution.revision_number,
        "plan_digest" => execution.plan_digest,
        "accepted_base" => base,
        "repository_observation" => observation,
        "decision" => decision
      }

      digest =
        :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))
        |> Base.encode16(case: :lower)

      repo.transaction(
        fn ->
          # Recheck the exact authority after filesystem observation before recording.
          authority = Plans.authority(goal_id, repo: repo)

          unless authority && authority.revision.digest == execution.plan_digest &&
                   authority.revision.revision_number == execution.revision_number,
                 do: repo.rollback(:plan_authority_changed)

          {:ok, current} = PlanExecutor.status(goal_id, opts)

          unless Map.take(current, [
                   :execution,
                   :accepted,
                   :attempts,
                   :active_run_id,
                   :needs_user?
                 ]) ==
                   Map.take(status, [
                     :execution,
                     :accepted,
                     :attempts,
                     :active_run_id,
                     :needs_user?
                   ]),
                 do: repo.rollback(:execution_scope_state_changed)

          case Trajectory.append(
                 goal_id,
                 %{
                   "type" => "cobbler.plan.independence.evaluated",
                   "schema_version" => 1,
                   "actor" => "cobbler",
                   "occurred_at" => Keyword.get(opts, :now, DateTime.utc_now()),
                   "idempotency_key" => "plan-independence:#{digest}",
                   "payload" => payload
                 },
                 writer_opts: [transaction_repo: repo]
               ) do
            {:ok, event} ->
              %{event_id: event.id, evidence: event.payload, parallel_dispatch_enabled: false}

            {:error, reason} ->
              repo.rollback(reason)
          end
        end,
        mode: :immediate
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :scope_execution_authority_required}
    end
  end
end
