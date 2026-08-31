defmodule Shoestring.Harness.ContractsTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.{
    CapacitySnapshot,
    Checkpoint,
    EventPayload,
    ExecutionLease,
    HarnessEvent,
    RunRequest
  }

  alias Shoestring.Trajectory.EventRegistry

  @goal_id "00000000-0000-4000-8000-000000000001"
  @task_id "00000000-0000-4000-8000-000000000002"
  @run_id "00000000-0000-4000-8000-000000000003"
  @dispatch_id "00000000-0000-4000-8000-000000000004"
  @snapshot_id "00000000-0000-4000-8000-000000000005"
  @grant_id "00000000-0000-4000-8000-000000000006"
  @checkpoint_id "00000000-0000-4000-8000-000000000007"

  test "all public v1 contracts construct typed normalized values" do
    assert {:ok, %RunRequest{version: 1, requested_capabilities: [:resume]}} =
             RunRequest.new(run_request_attrs())

    assert {:ok, %HarnessEvent{kind: :result, result: %{status: "completed"}}} =
             HarnessEvent.new(%{
               version: 1,
               run_id: @run_id,
               source_event_id: "event-1",
               ordinal: 1,
               occurred_at: ~U[2026-08-30 12:00:00Z],
               kind: :result,
               result: %{status: "completed"}
             })

    assert {:ok, %CapacitySnapshot{capacity_state: :known}} =
             CapacitySnapshot.new(known_snapshot_attrs())

    assert {:ok, %ExecutionLease{grant_id: @grant_id, reserves: %{response: 1, tool: 2}}} =
             ExecutionLease.new(lease_attrs())

    assert {:ok, %Checkpoint{checkpoint_id: @checkpoint_id}} = Checkpoint.new(checkpoint_attrs())
  end

  test "contract versions and extensions are explicit and bounded" do
    assert {:error, changeset} = RunRequest.new(Map.put(run_request_attrs(), :version, 2))
    assert "must equal 1; received 2" in errors_on(changeset).version

    assert {:error, changeset} =
             RunRequest.new(put_in(run_request_attrs(), [:extensions], %{"unscoped" => "value"}))

    assert "keys must be namespaced" in errors_on(changeset).extensions

    assert {:error, changeset} =
             RunRequest.new(Map.put(run_request_attrs(), :prompt, "Bearer abc.def.ghi"))

    assert "must not contain secrets" in errors_on(changeset).prompt
  end

  test "normalized error categories distinguish every required failure boundary" do
    assert Shoestring.Harness.Error.categories() == [
             :transport,
             :schema_incompatible,
             :authentication_required,
             :quota_refused,
             :cancelled,
             :task_failed,
             :invalid_transition,
             :unsupported_capability
           ]

    assert {:ok, %HarnessEvent{error: %{category: :quota_refused}}} =
             HarnessEvent.new(%{
               version: 1,
               run_id: @run_id,
               source_event_id: "quota-1",
               ordinal: 1,
               occurred_at: ~U[2026-08-30 12:00:00Z],
               kind: :error,
               error: %{category: "quota_refused", code: "limit", message: "Capacity refused"}
             })
  end

  test "capacity unknown and freshness are first-class deterministic states" do
    assert {:ok, unknown} =
             CapacitySnapshot.new(%{
               version: 1,
               snapshot_id: @snapshot_id,
               capacity_state: :unknown,
               windows: [],
               observed_at: ~U[2026-08-30 12:00:00Z],
               source: %{adapter_id: "test.adapter", method: "probe"},
               scope: "account",
               confidence: :none,
               support_tier: :unsupported,
               compatibility_state: :degraded
             })

    assert CapacitySnapshot.unknown?(unknown)
    assert CapacitySnapshot.freshness(unknown, ~U[2030-01-01 00:00:00Z]) == :unknown
    refute CapacitySnapshot.eligible?(unknown, ~U[2026-08-30 12:00:00Z])

    assert {:ok, known} = CapacitySnapshot.new(known_snapshot_attrs())
    assert CapacitySnapshot.freshness(known, ~U[2026-08-30 12:04:59Z]) == :fresh
    assert CapacitySnapshot.freshness(known, ~U[2026-08-30 12:05:01Z]) == :stale
    refute CapacitySnapshot.eligible?(known, ~U[2026-08-30 12:05:01Z])
  end

  test "a minimum checkpoint does not require model authored text or a summary" do
    attrs = checkpoint_attrs()
    refute Map.has_key?(attrs, :summary)
    refute Map.has_key?(attrs, :model_response)

    assert {:ok, checkpoint} = Checkpoint.new(attrs)
    assert checkpoint.evidence == []
    assert checkpoint.decisions == []
    assert checkpoint.unresolved_issues == []
  end

  test "raw transcripts are rejected in durable extension structures" do
    assert {:error, changeset} =
             Checkpoint.new(
               put_in(checkpoint_attrs(), [:extensions], %{
                 "test.adapter:raw_output" => "not allowed"
               })
             )

    assert "must not contain secrets or raw transcripts" in errors_on(changeset).extensions
  end

  test "contract event payloads are JSON-safe and registered at their exact v1 schemas" do
    assert {:ok, request} = RunRequest.new(run_request_attrs())
    assert {:ok, snapshot} = CapacitySnapshot.new(known_snapshot_attrs())
    assert {:ok, lease} = ExecutionLease.new(lease_attrs())
    assert {:ok, checkpoint} = Checkpoint.new(checkpoint_attrs())

    assert {:ok, harness_event} =
             HarnessEvent.new(%{
               version: 1,
               run_id: @run_id,
               source_event_id: "result-1",
               ordinal: 1,
               occurred_at: ~U[2026-08-30 12:00:00Z],
               kind: :result,
               result: %{status: "completed"}
             })

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "run.requested",
               1,
               EventPayload.run_requested(request, @run_id, "test.adapter")
             )

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "capacity.snapshot_observed",
               1,
               EventPayload.capacity_snapshot(snapshot, @run_id)
             )

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "lease.proposed",
               1,
               EventPayload.execution_lease(lease)
             )

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "checkpoint.created",
               1,
               EventPayload.checkpoint(checkpoint)
             )

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "harness.event_recorded",
               1,
               EventPayload.harness_event(harness_event)
             )
  end

  defp run_request_attrs do
    %{
      version: 1,
      goal_id: @goal_id,
      task_id: @task_id,
      workspace_ref: "workspace/project",
      prompt: "Implement the next action.",
      policy: %{mode: "supervised", network: false, write_access: true},
      requested_capabilities: [:resume],
      dispatch_id: @dispatch_id,
      extensions: %{"test.adapter:mode" => "scripted"}
    }
  end

  defp known_snapshot_attrs do
    %{
      version: 1,
      snapshot_id: @snapshot_id,
      capacity_state: :known,
      windows: [
        %{
          kind: "five_hour",
          state: :known,
          used_percent: 25.0,
          reset_at: ~U[2026-08-30 13:00:00Z]
        }
      ],
      observed_at: ~U[2026-08-30 12:00:00Z],
      expires_at: ~U[2026-08-30 12:05:00Z],
      source: %{adapter_id: "test.adapter", method: "probe"},
      scope: "account",
      confidence: :high,
      support_tier: :supported,
      compatibility_state: :compatible,
      extensions: %{}
    }
  end

  defp lease_attrs do
    %{
      version: 1,
      grant_id: @grant_id,
      run_id: @run_id,
      admitted_snapshot_id: @snapshot_id,
      reserves: %{response: 1, tool: 2},
      response_budget: 4,
      tool_budget: 8,
      deadline: ~U[2026-08-30 12:15:00Z],
      checkpoint_cadence: 2,
      renewal_state: :eligible,
      extensions: %{}
    }
  end

  defp checkpoint_attrs do
    %{
      version: 1,
      checkpoint_id: @checkpoint_id,
      goal_id: @goal_id,
      run_id: @run_id,
      acceptance_contract: %{criteria: ["Focused tests are green"]},
      repository_state: %{revision: "unknown", dirty: false},
      evidence: [],
      decisions: [],
      unresolved_issues: [],
      next_action: "Resume at the next safe boundary.",
      provider_session_id: nil,
      stop_reason: "quota_refused",
      artifact_ids: [],
      extensions: %{}
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
