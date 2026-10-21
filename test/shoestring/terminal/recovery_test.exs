defmodule Shoestring.Terminal.RecoveryTest do
  use Shoestring.DataCase, async: false
  import Ecto.Query
  alias Shoestring.Test.TerminalHelpers
  alias Shoestring.Harness.{CheckpointRecord, Projector, RunRecord}
  alias Shoestring.Terminal.{Events, Recovery, Session}
  alias Shoestring.Trajectory.TrajectoryEvent

  test "lost interactive sessions get a checkpoint and failed terminal, with no phantom resume" do
    fixture = TerminalHelpers.create!()
    id = fixture.dispatch.run_id

    for type <- ["run.starting", "run.running"] do
      assert {:ok, _} =
               Shoestring.Trajectory.append(
                 fixture.goal.id,
                 %{
                   "type" => type,
                   "schema_version" => 1,
                   "actor" => "elf",
                   "payload" => %{"run_id" => id}
                 },
                 trusted: [run_id: id, task_id: fixture.task.id]
               )
    end

    owner_ref = String.duplicate("a", 64)

    assert {:ok, _} =
             Events.append(fixture.request, "terminal.ownership.changed", %{
               "state" => "human_owned",
               "owner_ref" => owner_ref
             })

    assert {:ok, _} = Projector.project(fixture.goal.id)
    run = Repo.get!(RunRecord, id)
    assert {:ok, :reconciled} = Recovery.reconcile_run(run)
    assert Session.lookup(id) == nil
    assert Repo.get!(RunRecord, id).status == "failed"

    assert [%CheckpointRecord{}] =
             Repo.all(from checkpoint in CheckpointRecord, where: checkpoint.run_id == ^id)

    ownership =
      Repo.one!(
        from event in TrajectoryEvent,
          where: event.run_id == ^id and event.type == "terminal.ownership.changed",
          order_by: [desc: event.sequence],
          limit: 1
      )

    assert ownership.payload == %{
             "run_id" => id,
             "state" => "interrupted",
             "owner_ref" => owner_ref
           }

    assert {:ok, :unchanged} = Recovery.reconcile_run(Repo.get!(RunRecord, id))

    assert Repo.aggregate(
             from(event in TrajectoryEvent,
               where: event.run_id == ^id and event.type == "run.failed"
             ),
             :count
           ) == 1
  end

  test "a queued never-started run is left for normal durable delivery" do
    fixture = TerminalHelpers.create!()
    run = Repo.get!(RunRecord, fixture.dispatch.run_id)
    assert {:ok, :unchanged} = Recovery.reconcile_run(run)
    assert Repo.get!(RunRecord, run.id).status == "requested"
    assert Session.lookup(run.id) == nil
  end

  test "recovery preserves an exit fact recorded before the Elf checkpoint" do
    fixture = TerminalHelpers.create!()
    id = fixture.dispatch.run_id

    for type <- ["run.starting", "run.running"] do
      assert {:ok, _} =
               Shoestring.Trajectory.append(
                 fixture.goal.id,
                 %{
                   "type" => type,
                   "schema_version" => 1,
                   "actor" => "elf",
                   "payload" => %{"run_id" => id}
                 },
                 trusted: [run_id: id, task_id: fixture.task.id]
               )
    end

    assert {:ok, original} =
             Events.append(
               fixture.request,
               "terminal.session.exited",
               %{"reason" => "helper_failed"},
               "terminal-exit:#{id}"
             )

    assert {:ok, _} = Projector.project(fixture.goal.id)
    assert {:ok, :reconciled} = Recovery.reconcile_run(Repo.get!(RunRecord, id))
    assert Repo.get!(RunRecord, id).status == "failed"

    assert [exit] =
             Repo.all(
               from event in TrajectoryEvent,
                 where: event.run_id == ^id and event.type == "terminal.session.exited"
             )

    assert exit.id == original.id
    assert exit.payload["reason"] == "helper_failed"

    assert Repo.aggregate(
             from(checkpoint in CheckpointRecord, where: checkpoint.run_id == ^id),
             :count
           ) == 1
  end
end
