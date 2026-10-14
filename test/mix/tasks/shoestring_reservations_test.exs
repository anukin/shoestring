defmodule Mix.Tasks.Shoestring.ReservationsTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{
    ReservationControl,
    ReservationOperationRecord,
    ReservationRecord,
    ReservationSettlementRecord,
    ReservationWorker,
    Reservations
  }

  alias Shoestring.Harness.{Dispatches, DispatchRecord, RunRecord}
  alias Shoestring.Test.{PlanHandoffClock, ReservationHelpers}
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  defp cli(args) do
    Mix.Tasks.Shoestring.Reservations.run(args)
    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  defp request(c, action, id \\ Ecto.UUID.generate()),
    do: cli([action, c.owner.id, "--command-id", id, "--by", "human:operator"])

  test "CLI inspection shows owner, configured allowances and capacity without mutation" do
    c = ReservationHelpers.fixture()
    events = Repo.aggregate(TrajectoryEvent, :count)
    jobs = Repo.aggregate(Oban.Job, :count)
    view = cli(["show", c.owner.id])
    assert view["id"] == c.owner.id
    assert view["consumes_capacity"]
    assert view["configured_policy"]["global_limit"] == 1
    assert view["occupancy"]["provider_account_units"] == 1
    assert view["snapshot_id"] == c.owner.snapshot_id
    assert view["run"]["dispatch_id"] == c.run.dispatch_id
    assert length(view["capacity"]["windows"]) >= 1

    assert cli(["list", "--goal", c.goal.id])["reservations"] |> hd() |> Map.fetch!("id") ==
             c.owner.id

    assert Repo.aggregate(TrajectoryEvent, :count) == events
    assert Repo.aggregate(Oban.Job, :count) == jobs
  end

  test "CLI queues immutable recovery and the service releases unused orphan allowance" do
    c = ReservationHelpers.fixture(:orphan)
    id = Ecto.UUID.generate()
    result = request(c, "reconcile", id)
    assert result["status"] == "pending"
    assert result["result"] == nil
    job = Repo.get!(Oban.Job, result["job_id"])
    assert job.queue == "reservation_control"
    assert job.args == %{"operation_id" => id}
    assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
    assert request(c, "reconcile", id)["job_id"] == job.id
    assert :ok = ReservationWorker.perform(job)
    view = cli(["show", c.owner.id])
    assert view["status"] == "released"
    refute view["consumes_capacity"]
    assert hd(view["operations"])["result"]["disposition"] == "released"
    assert request(c, "reconcile", id)["job_id"] == nil
    assert cli(["list"])["reservations"] == []
    assert length(cli(["list", "--all"])["reservations"]) == 1
    assert Repo.get!(ReservationRecord, c.owner.id) == c.owner
  end

  test "explicit never-started cancellation fences late delivery and records canonical cancellation" do
    c = ReservationHelpers.fixture()
    result = request(c, "cancel-unstarted")
    assert Repo.get!(RunRecord, c.run.id).status == "requested"
    assert :ok = ReservationWorker.perform(Repo.get!(Oban.Job, result["job_id"]))
    assert Repo.get!(RunRecord, c.run.id).status == "cancelled"
    assert Repo.get!(DispatchRecord, c.run.dispatch_id).status == "cancelled"

    assert Repo.get!(ReservationSettlementRecord, c.owner.id).evidence["basis"] ==
             "never_started_intent_fenced"

    assert Reservations.outstanding() == []

    assert {:ok, {:skip, :cancelled}} =
             Dispatches.prepare_for_effect(c.run.dispatch_id, clock: PlanHandoffClock)

    assert :ok = ReservationWorker.perform(Repo.get!(Oban.Job, result["job_id"]))
    assert Repo.aggregate(ReservationSettlementRecord, :count) == 1

    assert Repo.aggregate(
             from(e in TrajectoryEvent,
               where: e.run_id == ^c.run.id and e.type == "run.cancelled"
             ),
             :count
           ) == 1
  end

  test "already claimed effects stay held and require reconciliation" do
    c = ReservationHelpers.fixture()

    assert {:ok, {:execute, _, _}} =
             Dispatches.prepare_for_effect(c.run.dispatch_id, clock: PlanHandoffClock)

    result = request(c, "cancel-unstarted")
    assert :ok = ReservationWorker.perform(Repo.get!(Oban.Job, result["job_id"]))
    view = cli(["show", c.owner.id])
    assert view["consumes_capacity"]
    assert view["status"] == "reconciliation_required"
    assert hd(view["operations"])["result"]["reason"] == "dispatch_effect_uncertain"
    assert Repo.get!(DispatchRecord, c.run.dispatch_id).status == "effect_started"
    assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
  end

  test "discarded operator jobs repair the same intent and cache tampering cannot authorize recovery" do
    c = ReservationHelpers.fixture(:orphan)
    result = request(c, "reconcile")
    job = Repo.get!(Oban.Job, result["job_id"])
    Repo.update!(Ecto.Changeset.change(job, state: "discarded"))
    assert {:ok, %{repaired_count: 1, failures: []}} = ReservationControl.repair()
    assert {:ok, %{repaired_count: 0, failures: []}} = ReservationControl.repair()
    operation = Repo.get!(ReservationOperationRecord, result["operation_id"])
    Repo.update!(Ecto.Changeset.change(operation, action: "cancel-unstarted"))
    assert {:error, :operation_authority_mismatch} = ReservationControl.perform(operation.id)
    assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
  end

  test "operator IDs conflict on changed intent and malformed CLI options never mutate" do
    c = ReservationHelpers.fixture(:orphan)
    id = Ecto.UUID.generate()
    request(c, "reconcile", id)
    assert_raise Mix.Error, ~r/operation_conflict/, fn -> request(c, "cancel-unstarted", id) end

    for args <- [
          ["list", "--force"],
          ["show", c.owner.id, "--all"],
          ["list", "--limit", "0"],
          ["list", "--limit", "1", "--limit", "1"],
          ["reconcile", c.owner.id, "--by", "model:planner", "--command-id", Ecto.UUID.generate()]
        ] do
      assert_raise Mix.Error, fn -> cli(args) end
    end

    assert Repo.aggregate(ReservationOperationRecord, :count) == 1
    assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
  end

  test "inspection omits raw run, snapshot and operation metadata while retaining required evidence" do
    c = ReservationHelpers.fixture()

    Repo.update!(
      Ecto.Changeset.change(c.run,
        prompt: "PRIVATE-PROMPT-SENTINEL",
        provider_session_id: "PRIVATE-SESSION-SENTINEL",
        extensions: Map.put(c.run.extensions, "private:raw", "PRIVATE-EXTENSION-SENTINEL")
      )
    )

    snapshot = Repo.get!(Shoestring.Harness.CapacitySnapshotRecord, c.owner.snapshot_id)

    Repo.update!(
      Ecto.Changeset.change(snapshot, extensions: %{"private:raw" => "PRIVATE-SNAPSHOT-SENTINEL"})
    )

    {:ok, _} = Reservations.require_reconciliation(c.owner.id, "PRIVATE-REASON-SENTINEL")
    result = request(c, "reconcile")
    operation = Repo.get!(ReservationOperationRecord, result["operation_id"])

    Repo.update!(
      Ecto.Changeset.change(operation,
        result: %{"raw" => "PRIVATE-OP-SENTINEL", "reason" => "PRIVATE-OP-REASON"}
      )
    )

    view = cli(["show", c.owner.id])
    json = Jason.encode!(view)
    refute json =~ "PRIVATE-"
    assert view["id"] == c.owner.id
    assert view["admission_event_id"] == c.owner.admission_event_id
    assert view["snapshot_id"] == c.owner.snapshot_id
    assert view["configured_units"] == 1
    assert view["reconciliation_reason"] == "operator_reconciliation_required"
    assert hd(view["operations"])["id"] == operation.id
  end

  test "cancellation refuses running evidence even when row and dispatch still look requested" do
    c = ReservationHelpers.fixture()

    assert {:ok, _} =
             Shoestring.Trajectory.append(
               c.goal.id,
               %{
                 "type" => "run.starting",
                 "schema_version" => 1,
                 "actor" => "fixture",
                 "payload" => %{"run_id" => c.run.id}
               },
               trusted: [run_id: c.run.id]
             )

    result = request(c, "cancel-unstarted")
    assert :ok = ReservationWorker.perform(Repo.get!(Oban.Job, result["job_id"]))

    assert hd(cli(["show", c.owner.id])["operations"])["result"]["reason"] ==
             "execution_evidence_present"

    assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
  end

  test "a failed completion write rolls back cancellation and settlement together" do
    c = ReservationHelpers.fixture()
    result = request(c, "cancel-unstarted")

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TEMP TRIGGER reject_recovery_completion BEFORE INSERT ON trajectory_events WHEN NEW.type = 'cobbler.reservation.operation.completed' BEGIN SELECT RAISE(ABORT, 'fixture recovery abort'); END"
    )

    assert_raise Exqlite.Error, fn ->
      ReservationControl.perform(result["operation_id"], clock: PlanHandoffClock)
    end

    assert Repo.get!(RunRecord, c.run.id).status == "requested"
    assert Repo.get!(DispatchRecord, c.run.dispatch_id).status == "requested"
    assert Repo.get!(ReservationOperationRecord, result["operation_id"]).status == "pending"
    assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
    assert Repo.get!(ReservationRecord, c.owner.id) == c.owner
  end

  test "live or unavailable Elf ownership retains capacity and replay never probes again" do
    c = ReservationHelpers.fixture()

    for lookup <- [fn _ -> self() end, fn _ -> raise "unavailable registry" end] do
      id = Ecto.UUID.generate()

      assert {:ok, _} =
               ReservationControl.request(c.owner.id, "cancel-unstarted", %{
                 command_id: id,
                 requested_by: "human:operator"
               })

      assert {:ok, %{"disposition" => "retained"}} =
               ReservationControl.perform(id, clock: PlanHandoffClock, elf_lookup: lookup)

      assert {:ok, %{"disposition" => "retained"}} =
               ReservationControl.perform(id, elf_lookup: fn _ -> flunk("replayed probe") end)
    end

    assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
    assert Repo.get!(DispatchRecord, c.run.dispatch_id).status == "requested"
  end

  test "changing a completed cache back to pending cannot authorize a second observation" do
    c = ReservationHelpers.fixture()
    result = request(c, "cancel-unstarted")
    id = result["operation_id"]

    assert {:ok, %{"disposition" => "retained"}} =
             ReservationControl.perform(id, elf_lookup: fn _ -> self() end)

    operation = Repo.get!(ReservationOperationRecord, id)
    Repo.update!(Ecto.Changeset.change(operation, status: "pending", result: nil))

    assert {:error, :operation_authority_mismatch} =
             ReservationControl.perform(id, elf_lookup: fn _ -> flunk("second probe") end)

    assert_raise Mix.Error, ~r/operation_authority_mismatch/, fn ->
      request(c, "cancel-unstarted", id)
    end

    assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
  end
end
