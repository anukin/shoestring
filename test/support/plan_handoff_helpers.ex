defmodule Shoestring.Test.PlanHandoffHelpers do
  import ExUnit.Assertions
  import Shoestring.Test.PlanExecutorHelpers
  alias Shoestring.{AgentProfiles, Cobbler, Repo, Trajectory}
  alias Shoestring.Cobbler.Handoffs
  alias Shoestring.Harness.{CheckpointFallback, Checkpoints, Continuation, RunRecord}
  alias Shoestring.Test.{CobblerHelpers, PlanFixtures}

  def fixture(stop \\ :quota) do
    assert {:ok, _} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{
               "codex_models" => "fixture-worker",
               "claude_models" => "default fixture-reviewer fixture-new"
             })

    attrs = Shoestring.ConfigurationFixtures.agent_attrs()

    roles =
      Enum.map(attrs["roles"], fn role ->
        case role["name"] do
          "Worker" -> Map.put(role, "model", "fixture-worker")
          "Reviewer" -> Map.put(role, "model", "fixture-reviewer")
          _ -> role
        end
      end)

    assert {:ok, agent} = AgentProfiles.create(Map.put(attrs, "roles", roles))
    assert {:ok, snapshot} = AgentProfiles.snapshot_by_id(agent.id)
    profile = Map.put(Map.take(snapshot, ~w(profile_id revision digest)), "role", "Worker")
    goal = CobblerHelpers.create_goal!()
    revision = propose_and_approve!(goal)
    admission = worker_admission(goal)

    assert {:ok, _} =
             Cobbler.request_plan_execution(
               goal.id,
               %{
                 revision_number: 1,
                 digest: revision.digest,
                 admission_event_id: admission.id,
                 agent_profile: profile
               },
               exec_opts()
             )

    assert {:ok, dispatched} =
             Cobbler.advance_plan_execution(goal.id, exec_opts(admission_event_id: admission.id))

    run = Repo.get!(RunRecord, dispatched.run_id)

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "run.starting",
                 "schema_version" => 1,
                 "actor" => "fixture",
                 "occurred_at" => now(),
                 "payload" => %{"run_id" => run.id}
               },
               trusted: [run_id: run.id, task_id: run.task_id]
             )

    assert {:ok, checkpoint} =
             CheckpointFallback.build(%{
               checkpoint_id: Ecto.UUID.generate(),
               goal_id: goal.id,
               run_id: run.id,
               acceptance_criteria: ["The approved task gate passes."],
               repository_revision: PlanFixtures.base_revision(),
               evidence: ["Synthetic checkpoint evidence"],
               decisions: [],
               unresolved_issues: [],
               stop_reason: "quota_refused",
               extensions: %{}
             })

    assert {:ok, _} = Checkpoints.record(goal.id, checkpoint, now: now())

    if stop == :suspended do
      for type <- ["run.running", "run.pausing"] do
        assert {:ok, _} =
                 Trajectory.append(
                   goal.id,
                   %{
                     "type" => type,
                     "schema_version" => 1,
                     "actor" => "fixture",
                     "occurred_at" => now(),
                     "payload" => %{"run_id" => run.id}
                   },
                   trusted: [run_id: run.id, task_id: run.task_id]
                 )
      end

      assert {:ok, _} =
               Trajectory.append(
                 goal.id,
                 %{
                   "type" => "run.suspended",
                   "schema_version" => 1,
                   "actor" => "fixture",
                   "occurred_at" => now(),
                   "payload" => %{"run_id" => run.id}
                 },
                 trusted: [run_id: run.id, task_id: run.task_id]
               )
    else
      terminal(
        goal,
        run,
        "run.failed",
        %{
          "error_category" => "quota_refused",
          "error_code" => "rate_limit_exceeded"
        },
        if(stop == :exhausted, do: DateTime.add(now(), 1200), else: now())
      )
    end

    %{goal: goal, agent: agent, run: run, checkpoint: checkpoint, revision: revision}
  end

  def worker_admission(goal) do
    original = admit!(goal)
    payload = put_in(original.payload, ["candidate", "adapter_id"], "codex_app_server_stdio")
    payload = Map.put(payload, "decision_id", Ecto.UUID.generate())
    CobblerHelpers.append_admission_event!(goal.id, payload)
  end

  def terminal(goal, run, type, extra \\ %{}, at \\ now()) do
    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => type,
                 "schema_version" => 1,
                 "actor" => "fixture",
                 "occurred_at" => at,
                 "idempotency_key" => "elf-terminal:#{run.dispatch_id}",
                 "payload" => Map.merge(%{"run_id" => run.id}, extra)
               },
               trusted: [run_id: run.id, task_id: run.task_id]
             )
  end

  def attrs(c) do
    %{
      "command_id" => "fixture-handoff-" <> Ecto.UUID.generate(),
      "payload" => %{
        "run_id" => c.run.id,
        "checkpoint_id" => c.checkpoint.checkpoint_id,
        "decision_refs" => Continuation.decision_refs(Repo, c.goal.id),
        "receiver_role" => "Reviewer",
        "to_provider_id" => "claude",
        "to_adapter_id" => "claude_headless_stream_json",
        "scope" => "fixture-scope",
        "reason" => "Continue this task after the sender quota stop",
        "requested_by" => "human:operator"
      }
    }
  end

  def request!(c, attributes \\ nil) do
    assert {:ok, %{command: command}} =
             Handoffs.request(c.goal.id, attributes || attrs(c), now: now())

    command
  end

  def perform_opts(extra \\ []) do
    {:ok, snapshot} =
      Shoestring.Harness.CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :observed,
          windows: [
            %{
              kind: "five_hour",
              state: :observed,
              used_percent: 10.0,
              reset_at: DateTime.add(now(), 7200)
            },
            %{
              kind: "weekly",
              state: :observed,
              used_percent: 12.0,
              reset_at: DateTime.add(now(), 7200)
            }
          ],
          observed_at: now(),
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "claude_headless_stream_json",
            provider_id: "claude",
            invocation_mode: "headless",
            event: :explicit_read
          },
          scope: "fixture-scope",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: now()
      )

    Keyword.merge(
      [
        now: now(),
        clock: Shoestring.Test.ManualClock,
        goal_state: :working,
        observe: fn _ -> {:ok, snapshot} end
      ],
      extra
    )
  end
end
