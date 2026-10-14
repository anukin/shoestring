defmodule Shoestring.Cobbler.PlanChildInboxTest do
  @moduledoc "New inbox capability tests; the separate delivery regression uses only baseline APIs."
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers

  alias Shoestring.Cobbler.{
    PlanChildInbox,
    PlanChildMessage,
    PlanChildWorker,
    PlanExecutor,
    PlanFanout,
    Reservations
  }

  alias Shoestring.Harness.RunRecord
  alias Shoestring.Test.PlanExecutorHelpers
  alias Shoestring.Trajectory.{EventRegistry, TrajectoryEvent}

  test "normalized progress binds canonical identity and copies no provider payload" do
    {c, north, _} = children()
    event = progress!(c, north)
    row = Repo.get!(PlanChildMessage, event.id)
    assert row.goal_id == c.goal.id and row.execution_id == c.execution.execution_id
    assert row.run_id == north.run_id and row.root_run_id == north.run_id

    assert row.revision_number == c.execution.revision_number and
             row.plan_digest == c.execution.plan_digest

    assert row.plan_task_id == "north" and row.attempt == 1 and
             row.source_sequence == event.sequence

    assert row.message_kind == "progress" and row.status == "pending"
    stored = Map.from_struct(row)
    refute Map.has_key?(stored, :payload)
    refute Map.has_key?(stored, :provider_session_id)
    refute Map.has_key?(stored, :extensions)
    assert event.payload["provider_session_id"] == "fake-session-0001"
    assert Repo.get!(Oban.Job, row.job_id).args == %{"event_id" => event.id}
    assert {:ok, %{outcome: :observed}} = PlanChildInbox.process(event.id, c.opts)
    ack = observation(event.id)
    assert ack.parent_event_id == event.id and ack.run_id == north.run_id
    assert ack.payload["source_event_id"] == event.id
    refute Map.has_key?(ack.payload, "extensions")
    refute Map.has_key?(ack.payload, "provider_session_id")
  end

  test "duplicate source delivery is stable and repairs a discarded job without a new source" do
    {c, north, _} = children()
    event = progress!(c, north)
    original = Repo.get!(PlanChildMessage, event.id)
    assert progress!(c, north).id == event.id
    assert Repo.get!(PlanChildMessage, event.id).job_id == original.job_id

    Repo.get!(Oban.Job, original.job_id)
    |> Ecto.Changeset.change(state: "discarded")
    |> Repo.update!()

    assert progress!(c, north).id == event.id
    repaired = Repo.get!(PlanChildMessage, event.id)
    assert repaired.job_id != original.job_id
    assert Repo.aggregate(PlanChildMessage, :count) == 1
    assert Repo.aggregate(from(e in TrajectoryEvent, where: e.id == ^event.id), :count) == 1
    assert Repo.get!(Oban.Job, original.job_id).state == "discarded"
  end

  test "source insertion rolls back if its durable inbox cannot be recorded" do
    {c, north, _} = children()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER inbox_fixture_refusal BEFORE INSERT ON cobbler_plan_child_inbox
      BEGIN SELECT RAISE(ABORT, 'fixture inbox refusal'); END
      """,
      []
    )

    before_events = Repo.aggregate(TrajectoryEvent, :count)
    before_jobs = Repo.aggregate(Oban.Job, :count)
    assert {:error, _} = append_progress(c, north)
    assert Repo.aggregate(TrajectoryEvent, :count) == before_events
    assert Repo.aggregate(Oban.Job, :count) == before_jobs
    assert Repo.aggregate(PlanChildMessage, :count) == 0
  end

  test "terminal delivery accepts a later child and older progress never regresses it" do
    {c, north, south} = children()
    progress = progress!(c, south)
    complete_child!(c.goal, south.run_id)
    terminal = Repo.get_by!(TrajectoryEvent, type: "run.completed", run_id: south.run_id)
    assert {:ok, %{outcome: :accepted}} = PlanChildInbox.process(terminal.id, c.opts)
    assert {:ok, %{outcome: :observed}} = PlanChildInbox.process(progress.id, c.opts)

    assert {:ok, %{accepted: ["south"], active_run_id: id, child_inbox: inbox}} =
             PlanExecutor.status(c.goal.id, c.opts)

    assert id == north.run_id and inbox.observed_count == 2
    assert inbox.pending_count > 0
    assert Repo.aggregate(RunRecord, :count) == 2
    assert Enum.map(Reservations.outstanding(), & &1.run_id) == [north.run_id]
  end

  test "canonical acknowledgement repairs a modified cache without replaying gates" do
    {c, _north, south} = children()
    complete_child!(c.goal, south.run_id)
    terminal = Repo.get_by!(TrajectoryEvent, type: "run.completed", run_id: south.run_id)
    assert {:ok, %{outcome: :accepted}} = PlanChildInbox.process(terminal.id, c.opts)
    row = Repo.get!(PlanChildMessage, terminal.id)

    row
    |> Ecto.Changeset.change(status: "pending", observation_event_id: nil, job_id: nil)
    |> Repo.update!()

    assert {:ok, %{failures: []}} = PlanChildInbox.reconcile(goal_id: c.goal.id)
    assert Repo.get!(PlanChildMessage, terminal.id).status == "observed"

    assert {:ok, %{outcome: :replayed}} =
             PlanChildInbox.process(
               terminal.id,
               Keyword.put(c.opts, :gate_runner_opts,
                 runner: fn _, _, _ -> flunk("replayed gate") end
               )
             )

    assert Repo.aggregate(
             from(e in TrajectoryEvent,
               where:
                 e.type == "cobbler.plan.child.observed" and e.parent_event_id == ^terminal.id
             ),
             :count
           ) == 1
  end

  test "uncertain process ownership waits without accepting, replacing or clearing either child" do
    {c, north, _south} = children()
    complete_child!(c.goal, north.run_id)
    terminal = Repo.get_by!(TrajectoryEvent, type: "run.completed", run_id: north.run_id)
    opts = Keyword.put(c.opts, :reconciliation_opts, group_probe: fn _ -> :alive end)
    assert {:ok, %{outcome: :awaiting_quiescence}} = PlanChildInbox.process(terminal.id, opts)
    assert Repo.get!(PlanChildMessage, terminal.id).status == "pending"
    assert Repo.get!(PlanChildMessage, terminal.id).last_reason == "awaiting_quiescence"
    refute observation(terminal.id)
    assert length(Reservations.outstanding()) == 2
    assert {:ok, %{accepted: [], total_attempts: 2}} = PlanExecutor.status(c.goal.id, c.opts)
    assert Repo.aggregate(RunRecord, :count) == 2
  end

  test "forged cache identity and payload-only run references cannot wake a child" do
    {c, north, south} = children()
    event = progress!(c, north)

    Repo.get!(PlanChildMessage, event.id)
    |> Ecto.Changeset.change(root_run_id: south.run_id)
    |> Repo.update!()

    assert {:error, :child_message_binding_mismatch} = PlanChildInbox.process(event.id, c.opts)
    refute observation(event.id)
    assert {:ok, untrusted} = append_progress(c, south, trusted: [])
    assert Repo.get(PlanChildMessage, untrusted.id) == nil
    assert Repo.aggregate(RunRecord, :count) == 2
  end

  test "quota sleep and cancellation are observed facts, not acceptance or replacement" do
    {c, north, south} = children()

    quota =
      append!(c, north, "run.failed", %{
        "error_category" => "quota_refused",
        "error_code" => "fixture_quota"
      })

    cancelled = append!(c, south, "run.cancelled", %{})
    assert Repo.get!(PlanChildMessage, quota.id).message_kind == "quota_wait"

    for event <- [quota, cancelled],
        do: assert({:ok, %{outcome: :observed}} = PlanChildInbox.process(event.id, c.opts))

    assert {:ok, %{accepted: [], total_attempts: 2}} = PlanExecutor.status(c.goal.id, c.opts)
    assert length(Reservations.outstanding()) == 2
    assert Repo.aggregate(RunRecord, :count) == 2
  end

  test "checkpoint and suspension notifications retain their canonical references without waking an Elf" do
    {c, north, _south} = children()
    append!(c, north, "run.starting", %{})

    assert {:ok, checkpoint} =
             Shoestring.Harness.CheckpointFallback.build(%{
               checkpoint_id: Ecto.UUID.generate(),
               goal_id: c.goal.id,
               run_id: north.run_id,
               acceptance_criteria: ["The fixture gate passes."],
               repository_revision: c.base,
               evidence: ["Public fixture checkpoint evidence"],
               decisions: [],
               unresolved_issues: [],
               stop_reason: "quota_refused",
               extensions: %{}
             })

    assert {:ok, %{events: [event]}} =
             Shoestring.Harness.Checkpoints.record(c.goal.id, checkpoint,
               now: PlanExecutorHelpers.now()
             )

    assert Repo.get!(PlanChildMessage, event.id).message_kind == "checkpoint"
    assert {:ok, %{outcome: :observed}} = PlanChildInbox.process(event.id, c.opts)
    append!(c, north, "run.running", %{"process_id" => "pgid:424242"})
    append!(c, north, "run.pausing", %{})
    suspended = append!(c, north, "run.suspended", %{})
    assert Repo.get!(PlanChildMessage, suspended.id).message_kind == "suspended"
    assert {:ok, %{outcome: :observed}} = PlanChildInbox.process(suspended.id, c.opts)
    assert observation(event.id).parent_event_id == event.id
    assert length(Reservations.outstanding()) == 2
    assert Repo.aggregate(RunRecord, :count) == 2
    assert {:ok, %{accepted: []}} = PlanExecutor.status(c.goal.id, c.opts)
  end

  test "acknowledgement schema preserves binding and refuses invented kinds and raw payloads" do
    {c, north, _} = children()
    event = progress!(c, north)
    assert {:ok, _} = PlanChildInbox.process(event.id, c.opts)
    payload = observation(event.id).payload

    assert {:ok, valid} =
             EventRegistry.validate_payload("cobbler.plan.child.observed", 1, payload)

    assert valid["root_run_id"] == north.run_id and valid["source_event_id"] == event.id

    for bad <- [
          Map.put(payload, "outcome", "dispatch"),
          Map.put(payload, "source_sequence", 0),
          Map.put(payload, "message_kind", "thinking"),
          Map.put(payload, "raw_output", "fixture text")
        ] do
      assert {:error, _} = EventRegistry.validate_payload("cobbler.plan.child.observed", 1, bad)
    end

    assert {:cancel, :invalid_child_inbox_job} = PlanChildWorker.perform(%Oban.Job{args: %{}})
  end

  test "historical canonical messages backfill without touching their payload or creating runs" do
    {c, north, _} = children()
    append!(c, north, "run.starting", %{})

    sequence =
      Repo.one(from e in TrajectoryEvent, where: e.goal_id == ^c.goal.id, select: max(e.sequence)) +
        1

    event =
      Repo.insert!(%TrajectoryEvent{
        id: Ecto.UUID.generate(),
        goal_id: c.goal.id,
        run_id: north.run_id,
        sequence: sequence,
        type: "run.running",
        actor: "fixture",
        schema_version: 1,
        occurred_at: PlanExecutorHelpers.now(),
        payload: %{"run_id" => north.run_id, "process_id" => "pgid:424242"}
      })

    assert Repo.get(PlanChildMessage, event.id) == nil

    assert {:ok, %{captured_count: 1, repaired_count: 1, failures: []}} =
             PlanChildInbox.reconcile(goal_id: c.goal.id)

    row = Repo.get!(PlanChildMessage, event.id)
    assert row.source_sequence == sequence and row.root_run_id == north.run_id
    assert Repo.get!(TrajectoryEvent, event.id) == event

    assert {:ok, _} =
             Shoestring.Harness.Projector.rebuild(c.goal.id,
               clock: Shoestring.Test.PlanHandoffClock
             )

    assert Repo.get!(TrajectoryEvent, event.id) == event

    assert {:ok, %{captured_count: 0, repaired_count: 0, failures: []}} =
             PlanChildInbox.reconcile(goal_id: c.goal.id)

    assert Repo.aggregate(RunRecord, :count) == 2
  end

  test "startup repair isolates a database refusal and preserves pending delivery" do
    {c, north, _south} = children()
    event = progress!(c, north)
    row = Repo.get!(PlanChildMessage, event.id)
    Repo.get!(Oban.Job, row.job_id) |> Ecto.Changeset.change(state: "discarded") |> Repo.update!()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER inbox_job_fixture_refusal BEFORE INSERT ON oban_jobs
      WHEN NEW.worker = 'Shoestring.Cobbler.PlanChildWorker'
      BEGIN SELECT RAISE(ABORT, 'fixture delivery refusal'); END
      """,
      []
    )

    root = Process.whereis(Shoestring.Supervisor)
    opts = [name: :inbox_failure_fixture, goal_id: c.goal.id]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pid = start_supervised!({Shoestring.Cobbler.PlanChildInboxReconciler, opts})
        assert :sys.get_state(pid) == opts
      end)

    assert log =~ "plan child inbox delivery repair failed"
    assert Process.whereis(Shoestring.Supervisor) == root
    assert Repo.get!(PlanChildMessage, event.id).job_id == row.job_id
    assert Repo.get!(PlanChildMessage, event.id).status == "pending"
    assert Repo.get!(Oban.Job, row.job_id).state == "discarded"
    refute observation(event.id)
  end

  test "a failed child is settled when verified stopped while its sibling remains untouched" do
    {c, north, south} = children()
    append!(c, north, "run.starting", %{})
    append!(c, north, "run.running", %{"process_id" => "pgid:424242"})

    failed =
      append!(c, north, "run.failed", %{
        "error_category" => "transport",
        "error_code" => "fixture_failure"
      })

    assert {:ok, %{outcome: :gate_failed}} = PlanChildInbox.process(failed.id, c.opts)
    assert Enum.map(Reservations.outstanding(), & &1.run_id) == [south.run_id]
    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert status.accepted == [] and status.total_attempts == 2
    assert Enum.find(status.children, &(&1.run_id == north.run_id)).resolution == :gate_failed
  end

  for {type, payload} <- [
        {"run.failed", %{"error_category" => "quota_refused", "error_code" => "fixture_quota"}},
        {"run.interrupted", %{}},
        {"run.cancelled", %{}}
      ] do
    test "verified #{type} ownership settles without accepting or replacing the task" do
      {c, north, south} = children()
      append!(c, north, "run.starting", %{})
      append!(c, north, "run.running", %{"process_id" => "pgid:424242"})
      event = append!(c, north, unquote(type), unquote(Macro.escape(payload)))
      assert {:ok, %{outcome: :observed}} = PlanChildInbox.process(event.id, c.opts)
      assert Enum.map(Reservations.outstanding(), & &1.run_id) == [south.run_id]
      assert {:ok, %{accepted: [], total_attempts: 2}} = PlanExecutor.status(c.goal.id, c.opts)
      assert Repo.aggregate(RunRecord, :count) == 2
    end
  end

  defp children do
    c = fixture(reconciliation_opts: [group_probe: fn _ -> :absent end])
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, south] = result.dispatched
    {c, north, south}
  end

  defp progress!(c, child) do
    assert {:ok, event} = append_progress(c, child)
    event
  end

  defp append_progress(c, child, opts \\ []) do
    Shoestring.Trajectory.append(
      c.goal.id,
      %{
        "type" => "harness.event_recorded",
        "schema_version" => 1,
        "actor" => "fixture",
        "occurred_at" => PlanExecutorHelpers.now(),
        "idempotency_key" => "inbox-progress:#{child.run_id}",
        "payload" => %{
          "run_id" => child.run_id,
          "source_event_id" => "fake-event-0001",
          "ordinal" => 1,
          "occurred_at" => DateTime.to_iso8601(PlanExecutorHelpers.now()),
          "kind" => "output",
          "provider_session_id" => "fake-session-0001",
          "extensions" => %{"fixture:diagnostic" => "public fixture metadata"}
        }
      },
      Keyword.put_new(opts, :trusted, run_id: child.run_id)
    )
  end

  defp append!(c, child, type, payload) do
    assert {:ok, event} =
             Shoestring.Trajectory.append(
               c.goal.id,
               %{
                 "type" => type,
                 "schema_version" => 1,
                 "actor" => "fixture",
                 "occurred_at" => PlanExecutorHelpers.now(),
                 "payload" => Map.put(payload, "run_id", child.run_id)
               },
               trusted: [run_id: child.run_id]
             )

    event
  end

  defp observation(id),
    do: Repo.get_by(TrajectoryEvent, type: "cobbler.plan.child.observed", parent_event_id: id)
end
