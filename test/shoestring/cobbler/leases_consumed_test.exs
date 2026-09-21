defmodule Shoestring.Cobbler.LeasesConsumedTest do
  @moduledoc """
  Hermetic regression locks for `Shoestring.Cobbler.Leases.consumed/2`.

  The spend read model must fail closed: when repository state
  reconstruction raises, `consumed/2` returns `nil` (rendered as "not
  recorded") rather than raising or inventing zero spend. The
  `run_id: nil` clause is defensive-only — persisted rows always carry a
  run id — so the test below drives the `rescue` path with a valid
  persisted lease, not that clause.
  """

  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.Leases

  alias Shoestring.Harness.{CapacitySnapshotRecord, ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Test.RaisingRepo
  alias Shoestring.Trajectory.{Goal, Task}

  @now ~U[2026-09-07 12:00:00.000000Z]

  test "consumed/2 returns nil when the trajectory log is unreadable" do
    lease = insert_lease()

    assert lease.run_id != nil
    assert Leases.consumed(lease, repo: RaisingRepo) == nil
  end

  test "consumed/2 rebuilds zero spend for a fresh lease" do
    lease = insert_lease()

    assert %{
             epoch: 0,
             responses: 0,
             tools: 0,
             next_boundary: %{bound: :checkpoint_cadence, reached?: false}
           } = Leases.consumed(lease, repo: Repo)
  end

  defp insert_lease do
    goal =
      %Goal{}
      |> Ecto.Changeset.change(%{
        id: Ecto.UUID.generate(),
        owner_id: Ecto.UUID.generate(),
        title: "Consumed fail-closed goal",
        status: "active"
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(%{"title" => "Consumed task"})
      |> Ecto.Changeset.put_change(:goal_id, goal.id)
      |> Repo.insert!()

    run =
      %RunRecord{
        id: Ecto.UUID.generate(),
        goal_id: goal.id,
        task_id: task.id,
        dispatch_id: Ecto.UUID.generate(),
        provider_id: "codex",
        workspace_ref: "ws-consumed",
        request_version: 1,
        prompt: "Consumed prompt",
        continuation: %{},
        policy: %{"mode" => "supervised"},
        requested_capabilities: %{},
        status: "requested",
        projection_sequence: 0,
        inserted_at: @now,
        updated_at: @now
      }
      |> Repo.insert!()

    snapshot =
      %CapacitySnapshotRecord{id: Ecto.UUID.generate(), goal_id: goal.id}
      |> CapacitySnapshotRecord.changeset(%{
        contract_version: 1,
        capacity_state: "observed",
        legacy_capacity_state: "known",
        legacy_observed_at: @now,
        freshness_max_age_seconds: 300,
        source_adapter_id: "fixture.adapter",
        source_method: "probe",
        source_provider_id: "codex",
        source_invocation_mode: "cli",
        source_event: "explicit_read",
        scope: "account-ui",
        confidence: "high",
        support_tier: "proactive",
        compatibility_state: "compatible",
        extensions: %{},
        projection_sequence: 0
      })
      |> Repo.insert!()

    %ExecutionLeaseRecord{
      id: Ecto.UUID.generate(),
      goal_id: goal.id,
      run_id: run.id,
      admitted_snapshot_id: snapshot.id
    }
    |> ExecutionLeaseRecord.changeset(%{
      contract_version: 1,
      response_reserve: 2,
      tool_reserve: 5,
      response_budget: 10,
      tool_budget: 25,
      deadline: DateTime.add(@now, 3600, :second),
      checkpoint_cadence: 5,
      renewal_state: "eligible",
      status: "active",
      extensions: %{},
      projection_sequence: 0
    })
    |> Repo.insert!()
  end
end
