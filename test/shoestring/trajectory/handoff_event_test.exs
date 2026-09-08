defmodule Shoestring.Trajectory.HandoffEventTest do
  @moduledoc """
  Hermetic tests for the `handoff.created` v1 event: registry validation,
  both projector arms, and the specified halt-visible behaviour of unknown
  `handoff.*` types (only `cobbler.*` gets leniency).

  Status per the standing contract, verified against the base commit
  (`d3ca088`) with `lib/` reverted and these test files kept:

  - TRUE REGRESSION LOCKS (fail on base for the right behavioural reason,
    pass with this slice): exact schema validation, missing-required
    rejection, secret-value rejection with the exact `invalid_payload`
    reason, both-projectors-advance, and foreign-checkpoint visible
    failure. On base each fails with
    `{:error, {:unknown_event_type, "handoff.created"}}`.
  - Rejection-shape locks (pass on base vacuously via `unknown_event_type`,
    pin bare `{:error, _}` rejection post-fix): unknown/transcript-key and
    non-UUID/oversized-ref rejection.
  - SPECIFICATION locks (pass on base and after): `handoff.future_probe`
    append refusal and visible projector halt, pinning that unknown
    non-cobbler types halt and the `cobbler.*` leniency does not
    generalize.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.Projector, as: HarnessProjector
  alias Shoestring.Repo
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{EventRegistry, Projector, TrajectoryEvent}

  @snapshot_id "01950000-0000-7000-8000-0000000000b1"
  @grant_id "01950000-0000-7000-8000-0000000000b2"
  @checkpoint_id "01950000-0000-7000-8000-0000000000b3"
  @handoff_id "01950000-0000-7000-8000-0000000000b4"

  defp handoff_payload(checkpoint_id, run_id, overrides \\ %{}) do
    Map.merge(
      %{
        "handoff_id" => @handoff_id,
        "run_id" => run_id,
        "checkpoint_id" => checkpoint_id,
        "from_provider_id" => "shoestring.harness.fake",
        "to_provider_id" => "fake-harness-b",
        "contract_version" => 1,
        "next_action" => "resume from the established checkpoint",
        "decision_refs" => [],
        "reason" => "quota handoff",
        "extensions" => %{}
      },
      overrides
    )
  end

  describe "registry: handoff.created v1 (regression lock)" do
    test "validates the exact v1 schema" do
      payload = handoff_payload(@checkpoint_id, Ecto.UUID.generate())

      assert {:ok, validated} = EventRegistry.validate_payload("handoff.created", 1, payload)
      assert validated["checkpoint_id"] == @checkpoint_id
      assert EventRegistry.current_version("handoff.created") == 1
      assert {"handoff.created", 1} in EventRegistry.registered_types()
    end

    test "rejects missing required fields" do
      payload = handoff_payload(@checkpoint_id, Ecto.UUID.generate()) |> Map.delete("reason")

      assert {:error, {:invalid_payload, "handoff.created", 1, _}} =
               EventRegistry.validate_payload("handoff.created", 1, payload)
    end

    test "rejects unknown and transcript-scale keys" do
      run_id = Ecto.UUID.generate()

      for key <- ["transcript", "raw_transcript", "messages", "stdout", "bogus_field"] do
        tainted = Map.put(handoff_payload(@checkpoint_id, run_id), key, "x")

        assert {:error, _} = EventRegistry.validate_payload("handoff.created", 1, tainted),
               "expected rejection for #{key}"
      end
    end

    test "rejects secret-bearing values through the normalized scan" do
      run_id = Ecto.UUID.generate()

      tainted =
        Map.put(
          handoff_payload(@checkpoint_id, run_id),
          "next_action",
          "use sk-abcdefghijklmnopqr"
        )

      assert {:error, {:invalid_payload, "handoff.created", 1, _}} =
               EventRegistry.validate_payload("handoff.created", 1, tainted)
    end

    test "rejects non-UUID decision refs and oversized ref lists" do
      run_id = Ecto.UUID.generate()

      assert {:error, _} =
               EventRegistry.validate_payload(
                 "handoff.created",
                 1,
                 handoff_payload(@checkpoint_id, run_id, %{"decision_refs" => ["not-a-uuid"]})
               )

      assert {:error, _} =
               EventRegistry.validate_payload(
                 "handoff.created",
                 1,
                 handoff_payload(@checkpoint_id, run_id, %{
                   "decision_refs" => Enum.map(1..33, fn _ -> Ecto.UUID.generate() end)
                 })
               )
    end
  end

  describe "projectors advance past handoff.created (regression lock)" do
    test "append validates and both projectors advance with no derived mutation" do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)

      run_a =
        FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
          run_id: Ecto.UUID.generate()
        )

      run_b =
        FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
          run_id: Ecto.UUID.generate()
        )

      now = Shoestring.Test.FixedClock.now()

      FakeHelpers.append_run_requested(goal, task, run_a)
      FakeHelpers.append_run_starting(goal, run_a)
      FakeHelpers.append_run_running(goal, run_a, session_id: "session-a")
      append_snapshot!(goal.id, run_a.id, now)
      append_lease!(goal.id, run_a.id, "lease.proposed", lease_proposed_payload(run_a.id), now)
      append_lease!(goal.id, run_a.id, "lease.granted", %{"grant_id" => @grant_id}, now)
      append_lease!(goal.id, run_a.id, "lease.active", %{"grant_id" => @grant_id}, now)
      FakeHelpers.append_checkpoint_created(goal, @checkpoint_id, run_a.id, "quota_refused")
      FakeHelpers.append_run_requested(goal, task, run_b)

      assert {:ok, _event} =
               Trajectory.append(
                 goal.id,
                 %{
                   "type" => "handoff.created",
                   "schema_version" => 1,
                   "actor" => "elf",
                   "occurred_at" => now,
                   "idempotency_key" => "handoff:#{@handoff_id}",
                   "payload" =>
                     handoff_payload(@checkpoint_id, run_b.id, %{
                       "prior_run_id" => run_a.id,
                       "lease_grant_id" => @grant_id
                     })
                 },
                 trusted: [task_id: task.id, run_id: run_b.id]
               )

      assert {:ok, harness_position} = HarnessProjector.project(goal.id)
      assert harness_position.last_sequence == 10
      assert harness_position.status == "ok"

      assert Repo.get!(Shoestring.Harness.CheckpointRecord, @checkpoint_id).next_action ==
               "continue from step 3"

      assert {:ok, goal_position} = Projector.project(goal.id)
      assert goal_position.last_sequence == 10
      assert goal_position.status == "ok"
    end

    test "handoff pointing at a foreign checkpoint fails the harness projection visibly" do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)

      run_a =
        FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
          run_id: Ecto.UUID.generate()
        )

      now = Shoestring.Test.FixedClock.now()

      FakeHelpers.append_run_requested(goal, task, run_a)

      foreign_checkpoint = Ecto.UUID.generate()

      assert {:ok, _event} =
               Trajectory.append(
                 goal.id,
                 %{
                   "type" => "handoff.created",
                   "schema_version" => 1,
                   "actor" => "elf",
                   "occurred_at" => now,
                   "idempotency_key" => "handoff:foreign-#{goal.id}",
                   "payload" => handoff_payload(foreign_checkpoint, run_a.id)
                 },
                 trusted: [task_id: task.id, run_id: run_a.id]
               )

      assert {:error, {:harness_projection_failed, 2, {:handoff_dependency_not_found, _}, _}} =
               HarnessProjector.project(goal.id)
    end
  end

  describe "unknown handoff.* types halt visibly (specification lock)" do
    test "append refuses unknown handoff future types" do
      goal = FakeHelpers.insert_goal()

      assert {:error, {:unknown_event_type, "handoff.future_probe"}} =
               Trajectory.append(goal.id, %{
                 "type" => "handoff.future_probe",
                 "schema_version" => 1,
                 "actor" => "elf",
                 "occurred_at" => Shoestring.Test.FixedClock.now(),
                 "payload" => %{}
               })
    end

    test "goal/task projection halts visibly on a directly-inserted unknown handoff type" do
      goal = FakeHelpers.insert_goal()

      assert {:ok, _} =
               Trajectory.append(goal.id, %{
                 "type" => "goal.created",
                 "schema_version" => 1,
                 "actor" => "system",
                 "payload" => %{"title" => "Handoff probe goal"},
                 "idempotency_key" => "goal-#{goal.id}"
               })

      %TrajectoryEvent{goal_id: goal.id, sequence: 2}
      |> TrajectoryEvent.changeset(%{
        "type" => "handoff.future_probe",
        "schema_version" => 1,
        "actor" => "fixture",
        "occurred_at" => ~U[2026-09-07 12:00:00Z],
        "payload" => %{"note" => "a future handoff event this projector never learned"}
      })
      |> Repo.insert!()

      assert {:error, {:projection_failed, 2, {:unknown_event_type, "handoff.future_probe"}}} =
               Projector.project(goal.id)
    end
  end

  # -- Helpers --

  defp append_snapshot!(goal_id, run_id, now) do
    assert {:ok, _event} =
             Trajectory.append(
               goal_id,
               %{
                 "type" => "capacity.snapshot_observed",
                 "schema_version" => 2,
                 "actor" => "harness",
                 "occurred_at" => now,
                 "idempotency_key" => "snapshot:#{@snapshot_id}",
                 "payload" => %{
                   "snapshot_id" => @snapshot_id,
                   "run_id" => run_id,
                   "contract_version" => 2,
                   "capacity_state" => "observed",
                   "windows" => %{
                     "items" => [
                       %{"kind" => "five_hour", "state" => "observed", "used_percent" => 25.0}
                     ]
                   },
                   "observed_at" => "2026-08-30T12:00:00Z",
                   "expires_at" => "2026-08-30T12:05:00Z",
                   "freshness" => %{"max_age_seconds" => 300},
                   "source" => %{
                     "adapter_id" => "shoestring.harness.fake",
                     "provider_id" => "fake",
                     "invocation_mode" => "fake",
                     "event" => "explicit_read"
                   },
                   "scope" => "subscription",
                   "confidence" => "high",
                   "support_tier" => "proactive",
                   "compatibility_state" => "compatible",
                   "reason" => nil,
                   "extensions" => %{}
                 }
               },
               trusted: [run_id: run_id]
             )
  end

  defp lease_proposed_payload(run_id) do
    %{
      "grant_id" => @grant_id,
      "run_id" => run_id,
      "admitted_snapshot_id" => @snapshot_id,
      "contract_version" => 1,
      "reserves" => %{"response" => 1, "tool" => 1},
      "response_budget" => 4,
      "tool_budget" => 4,
      "deadline" => "2026-08-30T12:15:00Z",
      "checkpoint_cadence" => 2,
      "renewal_state" => "eligible",
      "extensions" => %{}
    }
  end

  defp append_lease!(goal_id, run_id, type, payload, now) do
    assert {:ok, _event} =
             Trajectory.append(
               goal_id,
               %{
                 "type" => type,
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => now,
                 "idempotency_key" => "#{type}:#{@grant_id}",
                 "payload" => payload
               },
               trusted: [run_id: run_id]
             )
  end
end
