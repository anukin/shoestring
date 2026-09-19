defmodule Shoestring.Harness.HandoffSessionLookupTest do
  @moduledoc """
  Regression lock: a handoff replay must recognize a live receiver session
  that is registered the way real adapters register one.

  Both production adapters register a session under `RunIdentity.run_id`,
  and `CodexAppServer.start_session/2` / `ClaudeHeadless` set that from
  `request.dispatch_id` — NOT the run row id. `Shoestring.Elves.Elf` already
  documents this ("Sessions register under request.dispatch_id, which differs
  from the run row id on dispatched continuation runs — so look up dispatch
  first, run id second").

  `Elves.live_receiver_session?/2` looked the receiver up by
  `stored_run.id` only. Against a real adapter that lookup always missed, so
  the replay decision tree fell through to its "no evidence the effect ran"
  arm and called `adapter.start/2` again — a SECOND live provider session for
  one receiver run, which is exactly the duplicate-session defect.

  The stub here registers its session under the dispatch id, mirroring the
  real adapters. `Shoestring.Harness.HandoffCorrectionTest`'s own
  `LiveSessionStubAdapter` registers under the run row id, which is why that
  suite passed while production duplicated.

  ## Lock ledger (base `01f2a54`)

  `"a receiver session registered under the dispatch id is recognized on
  replay"` is a TRUE behavioural lock: on base it fails with
  `RequestLog.count == 2` where 1 is asserted — a second `adapter.start`,
  i.e. the duplicate session. The run-row-id arm and the
  dispatch-id-equals-run-id arm are DOCUMENTATION: they pass on base and pin
  the behaviour the fix must preserve.

  Hermetic: Fake-derived stub adapter, no provider CLI, no network.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Elves
  alias Shoestring.Harness.Fake
  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Harness.{Projector, RunRecord}
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @sender_session "fake-session-sender-FOXTROT3"
  @next_action "NEXTACTION-FOXTROT3 advance to step seven"

  defmodule DispatchKeyedSessionAdapter do
    @moduledoc """
    A Fake-backed adapter that registers its session the way the real
    adapters do: under `RunIdentity.run_id`, which `start/2` derives from
    `request.dispatch_id`.
    """
    @behaviour Shoestring.Harness.Adapter

    alias Shoestring.Harness.Fake

    @impl true
    def identity, do: Fake.identity()
    @impl true
    def capabilities, do: Fake.capabilities()
    @impl true
    def probe(opts), do: Fake.probe(opts)
    @impl true
    def start(request, opts), do: Fake.start(request, opts)
    @impl true
    def resume(prior, request, opts), do: Fake.resume(prior, request, opts)
    @impl true
    def send(identity, message, opts), do: Fake.send(identity, message, opts)
    @impl true
    def cancel(identity, opts), do: Fake.cancel(identity, opts)
    @impl true
    def status(identity, opts), do: Fake.status(identity, opts)
    @impl true
    def stream(identity, opts), do: Fake.stream(identity, opts)

    @doc "Registers a live session under `id`, mirroring `store_session/2`."
    def register(id, pid \\ self()) do
      Process.put(:dispatch_keyed_sessions, Map.put(sessions(), id, pid))
      :ok
    end

    @doc "Session liveness read, mirroring `CodexAppServer.lookup_session/1`."
    def lookup_session(id) do
      case sessions() do
        %{^id => pid} when is_pid(pid) -> {:ok, pid}
        _other -> {:error, :not_found}
      end
    end

    defp sessions, do: Process.get(:dispatch_keyed_sessions, %{})
  end

  describe "receiver session lookup covers the ids a session can register under" do
    test "a receiver session registered under the dispatch id is recognized on replay" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      opts = handoff_opts(fixture, log)

      assert {:ok, %{run: receiver}} = Elves.resume_run(fixture.run.id, opts)
      assert RequestLog.count(log) == 1

      # The receiver row and its dispatch id are genuinely different ids —
      # without that this test would prove nothing.
      refute receiver.dispatch_id == receiver.id

      # Register the live session where a real adapter puts it.
      :ok = DispatchKeyedSessionAdapter.register(receiver.dispatch_id)

      assert {:ok, %{run: replayed}} = Elves.resume_run(fixture.run.id, opts)

      assert replayed.id == receiver.id
      # THE LOCK: no second session was started for this receiver run.
      assert RequestLog.count(log) == 1
      assert RequestLog.resumes(log) == []
      assert handoff_count(fixture.goal.id, opts[:handoff_id]) == 1
      assert run_count(fixture.goal.id) == 2
    end

    test "a session registered under the run row id is still recognized (DOCUMENTATION)" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      opts = handoff_opts(fixture, log)

      assert {:ok, %{run: receiver}} = Elves.resume_run(fixture.run.id, opts)
      assert RequestLog.count(log) == 1

      :ok = DispatchKeyedSessionAdapter.register(receiver.id)

      assert {:ok, %{run: replayed}} = Elves.resume_run(fixture.run.id, opts)
      assert replayed.id == receiver.id
      assert RequestLog.count(log) == 1
    end

    test "a dead session under the dispatch id does not mask a missing effect" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      opts = handoff_opts(fixture, log)

      assert {:ok, %{run: receiver}} = Elves.resume_run(fixture.run.id, opts)

      {:ok, dead} = Agent.start(fn -> :ok end)
      :ok = Agent.stop(dead)
      :ok = DispatchKeyedSessionAdapter.register(receiver.dispatch_id, dead)

      assert {:ok, %{run: replayed}} = Elves.resume_run(fixture.run.id, opts)

      assert replayed.id == receiver.id
      # A registry entry pointing at a dead pid is not evidence of a live
      # session: the effect is re-attempted, under the SAME ids.
      assert RequestLog.count(log) == 2
      assert handoff_count(fixture.goal.id, opts[:handoff_id]) == 1
      assert run_count(fixture.goal.id) == 2
    end

    test "no registered session at all re-attempts the effect" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      opts = handoff_opts(fixture, log)

      assert {:ok, %{run: receiver}} = Elves.resume_run(fixture.run.id, opts)
      assert {:ok, %{run: replayed}} = Elves.resume_run(fixture.run.id, opts)

      assert replayed.id == receiver.id
      assert RequestLog.count(log) == 2
      assert run_count(fixture.goal.id) == 2
    end
  end

  # ----------------------------------------------------------------------------
  # Fixture
  # ----------------------------------------------------------------------------

  defp handoff_opts(fixture, log) do
    [
      adapter: DispatchKeyedSessionAdapter,
      adapter_opts: %{
        scenario: Scenario.handoff_target(),
        clock: Shoestring.Test.FixedClock,
        request_log: log
      },
      continuation: fixture.presented,
      provider_session_id: @sender_session,
      to_provider_id: "fake-harness-b",
      reason: "quota handoff",
      handoff_id: fixture.handoff_id,
      new_run_id: fixture.new_run_id,
      new_dispatch_id: fixture.new_dispatch_id
    ]
  end

  defp handoff_fixture do
    goal = FakeHelpers.insert_goal(Ecto.UUID.generate())
    task = FakeHelpers.insert_task(goal, Ecto.UUID.generate())

    run =
      FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate()
      )

    checkpoint_id = Ecto.UUID.generate()
    decision_id = Ecto.UUID.generate()
    now = Shoestring.Test.FixedClock.now()

    CobblerHelpers.append_admission_event!(
      goal.id,
      CobblerHelpers.admission_payload(decision_id: decision_id)
    )

    {:ok, _} =
      Trajectory.append(
        goal.id,
        %{
          "type" => "checkpoint.created",
          "schema_version" => 1,
          "actor" => "harness",
          "occurred_at" => now,
          "idempotency_key" => "checkpoint:#{checkpoint_id}",
          "payload" => %{
            "checkpoint_id" => checkpoint_id,
            "run_id" => run.id,
            "contract_version" => 1,
            "acceptance_contract" => %{"criteria" => ["tests pass"]},
            "repository_state" => %{"revision" => "abc123", "dirty" => false},
            "evidence" => %{"items" => []},
            "decisions" => %{"items" => ["chose approach A"]},
            "unresolved_issues" => %{"items" => []},
            "next_action" => @next_action,
            "provider_session_id" => @sender_session,
            "stop_reason" => "quota_refused",
            "artifact_ids" => %{"items" => []},
            "extensions" => %{}
          }
        },
        trusted: [run_id: run.id]
      )

    {:ok, _} = Projector.project(goal.id)

    %{
      goal: goal,
      task: task,
      run: Repo.get!(RunRecord, run.id),
      checkpoint_id: checkpoint_id,
      decision_id: decision_id,
      handoff_id: Ecto.UUID.generate(),
      new_run_id: Ecto.UUID.generate(),
      new_dispatch_id: Ecto.UUID.generate(),
      presented: %{
        checkpoint_id: checkpoint_id,
        next_action: @next_action,
        decision_refs: [decision_id]
      }
    }
  end

  defp handoff_count(goal_id, handoff_id) do
    key = "handoff:" <> handoff_id

    Repo.one!(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == "handoff.created" and
            event.idempotency_key == ^key,
        select: count(event.id)
    )
  end

  defp run_count(goal_id) do
    Repo.one!(from run in RunRecord, where: run.goal_id == ^goal_id, select: count(run.id))
  end
end
