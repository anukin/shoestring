defmodule Shoestring.Cobbler.PlanAuthorityHardeningTest do
  @moduledoc """
  Behavioral regression locks for the iteration-6 narrow authority
  hardening: stored digests are re-verified on every authority read,
  plan decision events require `human:` deciders consistently with the
  Plans API, and event replay verifies decision digests against the
  reconstructed immutable revision instead of returning forged authority.

  VERIFIED pre-fix behavior: each test below was run against the base
  commit `df62479` (tracked `lib/` changes stashed) and fails there for
  the stated behavioural reason — never on a missing module or changed
  signature.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.Plans
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.EventRegistry

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers, only: [create_goal!: 0]
  import Shoestring.Test.PlanFixtures

  @now ~U[2026-09-30 12:00:00.000000Z]

  defp opts, do: [now: @now, publish_fun: fn _event -> :ok end]

  defp propose_and_approve!(goal) do
    assert {:ok, %{revision: revision}} = Plans.propose(goal.id, propose_attrs(), opts())

    assert {:ok, _} =
             Plans.approve(
               goal.id,
               approve_attrs(revision.revision_number, revision.digest),
               opts()
             )

    revision
  end

  describe "authority verifies the stored digest" do
    test "a revision row whose digest no longer describes its content holds no authority" do
      goal = create_goal!()
      revision = propose_and_approve!(goal)

      assert %{revision_number: 1} = Plans.authority(goal.id)

      # Tamper with the stored digest only: content is untouched.
      revision
      |> Ecto.Changeset.change(%{digest: String.duplicate("0", 64)})
      |> Repo.update!()

      # Pre-fix behavior: authority still returns the tampered revision.
      assert Plans.authority(goal.id) == nil
    end
  end

  describe "plan decision events require human deciders" do
    test "an approval naming a non-human decider is refused at the event boundary" do
      goal = create_goal!()
      revision = propose_and_approve!(goal)

      payload = %{
        "plan_revision_id" => revision.id,
        "revision_number" => revision.revision_number,
        "decision_id" => "decision-forged",
        "plan_digest" => revision.digest,
        "decided_by" => "system:planner",
        "decided_at" => DateTime.to_iso8601(@now)
      }

      # Pre-fix behavior: this payload validates cleanly.
      assert {:error, {:invalid_payload, "cobbler.plan.approved", 1, _changeset}} =
               EventRegistry.validate_payload("cobbler.plan.approved", 1, payload, now: @now)
    end

    test "a rejection naming a non-human decider is refused at the event boundary" do
      goal = create_goal!()
      revision = propose_and_approve!(goal)

      payload = %{
        "plan_revision_id" => revision.id,
        "revision_number" => revision.revision_number,
        "decision_id" => "decision-forged",
        "plan_digest" => revision.digest,
        "decided_by" => "model:fixture",
        "decided_at" => DateTime.to_iso8601(@now),
        "reason" => "A bounded forged reason."
      }

      assert {:error, {:invalid_payload, "cobbler.plan.rejected", 1, _changeset}} =
               EventRegistry.validate_payload("cobbler.plan.rejected", 1, payload, now: @now)
    end

    test "a revision event with a non-human author identity is refused" do
      goal = create_goal!()
      revision = propose_and_approve!(goal)

      [created] =
        Repo.all(
          from event in Shoestring.Trajectory.TrajectoryEvent,
            where: event.goal_id == ^goal.id and event.type == "cobbler.plan.revision.created"
        )

      forged = Map.put(created.payload, "authored_by", "system:planner")

      assert {:error, {:invalid_payload, "cobbler.plan.revision.created", 1, _changeset}} =
               EventRegistry.validate_payload(
                 "cobbler.plan.revision.created",
                 1,
                 forged,
                 now: @now
               )

      assert revision.authored_by == "human:planner"
    end
  end

  describe "replay verifies decision digests against reconstructed revisions" do
    test "an approval bound to a digest the revision never had fails the rebuild" do
      goal = create_goal!()
      revision = propose_and_approve!(goal)

      forged_digest = String.duplicate("1", 64)

      {:ok, _event} =
        Trajectory.append(
          goal.id,
          %{
            "type" => "cobbler.plan.approved",
            "schema_version" => 1,
            "actor" => "cobbler",
            "occurred_at" => @now,
            "payload" => %{
              "plan_revision_id" => revision.id,
              "revision_number" => revision.revision_number,
              "decision_id" => "decision-forged-digest",
              "plan_digest" => forged_digest,
              "decided_by" => "human:intruder",
              "decided_at" => DateTime.to_iso8601(@now)
            }
          }
        )

      # Pre-fix behavior: rebuild succeeds and reports the forged digest
      # as the active authority.
      assert {:error, {:rebuild_decision_digest_mismatch, _sequence, 1, _, ^forged_digest}} =
               Plans.rebuild(goal.id)
    end

    # Documentation, not a hardening lock: the missing-revision refusal
    # predates this work package and passes at the base commit too. It
    # pins the error shape the digest check above defers to for ghosts.
    test "a decision for a revision that was never created fails the rebuild" do
      goal = create_goal!()
      revision = propose_and_approve!(goal)

      {:ok, _event} =
        Trajectory.append(
          goal.id,
          %{
            "type" => "cobbler.plan.rejected",
            "schema_version" => 1,
            "actor" => "cobbler",
            "occurred_at" => @now,
            "payload" => %{
              "plan_revision_id" => revision.id,
              "revision_number" => 99,
              "decision_id" => "decision-ghost-revision",
              "plan_digest" => revision.digest,
              "decided_by" => "human:intruder",
              "decided_at" => DateTime.to_iso8601(@now),
              "reason" => "Rejecting a revision that does not exist."
            }
          }
        )

      assert {:error, {:rebuild_decision_without_revision, _sequence, 99}} =
               Plans.rebuild(goal.id)
    end
  end
end
