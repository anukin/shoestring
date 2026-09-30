defmodule Shoestring.Elves.ElfTerminalProjectionTest do
  @moduledoc """
  L8 terminal-projection closeout regression: after the Elf commits terminal
  events it promptly projects its own goal, so the durable lease/run rows
  reflect the canonical terminal state with no caller manually projecting.

  The live `lease_stop` run (`live-closeout-post85.md` §14) ended the
  trajectory at `lease.expired` → `lease.checkpoint_required` →
  `checkpoint.created` → `run.completed`, but the stored lease row still read
  `renewal_due` (and the run row `running`): `LeaseRenewal.persist_and_settle/5`
  projects once after the renewal snapshot, then appends the decision and the
  expiry markers, and neither `commit_terminal/2` nor `crash_land/0` projected
  after the terminal.

  Lock-vs-documentation ledger (verified against base `70af28e`):

  - `"a completed outcome with a refused lease projects terminal rows"` —
    **lock**. On base the lease row reads `renewal_due`, the run row reads
    `running`, and the `harness` projector position lags the terminal, because
    nothing projects after the terminal commit.
  - `"an interrupted decline projects terminal rows"` — **lock**. Same
    behavioural lag on base (lease `renewal_due`, run not `interrupted`,
    position lagging), through the suspend + wake decline path.
  - `"a launch crash projects terminal rows"` — **lock**. On base the
    `crash_land/0` terminal (`run.failed` / `elf_launch_crashed`) is durable
    but the run row is never projected to `failed` and the position lags.

  Hermetic: FixedClock, the Fake adapter (plus one raising adapter for the
  crash twin), trivial local commands. Never a provider CLI, never the
  network. No post-terminal `Projector.project/2` call anywhere in this file:
  that absence is the point — the Elf must have projected already.
  """

  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Cobbler.{Leases, WakeupRecord}
  alias Shoestring.Elves
  alias Shoestring.Harness.{CapacitySnapshot, ExecutionLease, ExecutionLeaseRecord, Fake}
  alias Shoestring.Harness.{DispatchRecord, Projector, RunIdentity, RunRecord, RunRequest}
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.FixedClock
  alias Shoestring.Trajectory.{ProjectorPosition, TrajectoryEvent}

  defmodule RaisingStartAdapter do
    @moduledoc false
    @behaviour Shoestring.Harness.Adapter

    def identity, do: Fake.identity()
    def capabilities, do: MapSet.new([])
    def probe(opts), do: Fake.probe(opts)
    def status(%RunIdentity{} = identity, opts), do: Fake.status(identity, opts)
    def stream(%RunIdentity{} = identity, opts), do: Fake.stream(identity, opts)

    def start(%RunRequest{}, _opts), do: raise("terminal projection crash-twin boom")
  end

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]
  @interval_ms 200
  @live_statuses ["proposed", "granted", "active", "renewal_due"]

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "a completed outcome with a refused lease projects terminal rows", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # The live L8 shape, hermetically: grant → renewal due (deadline already
    # past) → mid-flow projection inside `persist_and_settle/5` → the lease
    # refuses on the completed outcome → expiry markers → the ordinary
    # terminal checkpoint → `run.completed`. The Elf's own final projection
    # must settle the rows; the test never projects after the terminal.
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:terminal_projection_completed, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("first", source_event_id: "evt-out-1"),
        Scenario.output_event("second", source_event_id: "evt-out-2"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    %{grant_id: grant_id} =
      grant_for_run!(goal, run_id, fresh_id,
        response_budget: 100,
        tool_budget: 100,
        reserves: %{response: 1, tool: 1},
        checkpoint_cadence: 100,
        deadline: DateTime.add(FixedClock.now(), -60, :second)
      )

    release_elf(pid)

    # The notify arrives after the Elf's final projection, so every row read
    # below is what the Elf itself left behind — no test-side projection.
    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    # Exact canonical terminal sequence: one due marker, no renewal, one
    # refusal pair, one terminal checkpoint, exactly one terminal.
    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 1
    assert count_types(goal.id, run_id, ["lease.renewed"]) == 0
    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert count_types(goal.id, run_id, ["lease.checkpoint_required"]) == 1
    assert count_types(goal.id, run_id, ["admission.decided"]) == 1
    assert renewal_decisions(goal.id, run_id) == 1
    assert terminal_checkpoint_count(goal.id, run_id) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 0
    assert count_types(goal.id, run_id, ["run.completed"]) == 1
    assert count_types(goal.id, run_id, ["run.failed"]) == 0
    assert count_types(goal.id, run_id, ["run.interrupted"]) == 0
    assert count_types(goal.id, run_id, ["run.cancelled"]) == 0
    assert count_types(goal.id, run_id, ["harness.event_recorded"]) == 4

    # No suspension, wake, or redispatch for finished work.
    assert count_types(goal.id, run_id, ["run.pausing"]) == 0
    assert count_types(goal.id, run_id, ["run.suspended"]) == 0
    assert Repo.get_by(WakeupRecord, run_id: run_id) == nil
    assert Repo.aggregate(dispatch_query(goal.id, run_id), :count) == 1
    assert count_types(goal.id, run_id, ["run.starting"]) == 1

    ordered = ordered_events(goal.id, run_id)
    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.expired", nil})
    assert sequence_before?(ordered, {"lease.expired", nil}, {"lease.checkpoint_required", nil})

    assert sequence_before?(
             ordered,
             {"lease.checkpoint_required", nil},
             {"checkpoint.created", nil}
           )

    assert sequence_before?(ordered, {"checkpoint.created", nil}, {:terminal, nil})

    # Durable rows reflect the canonical terminal state with no live status.
    lease = Repo.get!(ExecutionLeaseRecord, grant_id)
    assert lease.status == "checkpoint_required"
    refute lease.status in @live_statuses

    assert Repo.get_by!(RunRecord, id: run_id).status == "completed"

    # The projector is caught up to the terminal: with no test-side
    # projection after it, only the Elf could have advanced it here.
    assert_projector_caught_up(goal.id)
  end

  test "an interrupted decline projects terminal rows", %{sup: sup, goal: goal, task: task} do
    # Twin through the decline path: an interrupted outcome with a refused
    # lease suspends for a wake-driven continuation AND keeps its interrupted
    # terminal. The same final projection must settle those rows too.
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:terminal_projection_interrupted, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.output_event("three", source_event_id: "evt-out-3"),
        Scenario.result_event("interrupted", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    %{grant_id: grant_id} =
      grant_for_run!(goal, run_id, fresh_id,
        response_budget: 2,
        tool_budget: 25,
        reserves: %{response: 0, tool: 0},
        checkpoint_cadence: 100,
        deadline: DateTime.add(FixedClock.now(), 3_600, :second)
      )

    release_elf(pid)

    assert_receive {:elf_terminal, ^run_id, %{class: :interrupted}}, 15_000

    # The decline suspended with its sleep wake, then terminalized.
    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert count_types(goal.id, run_id, ["lease.checkpoint_required"]) == 1
    assert count_types(goal.id, run_id, ["run.pausing"]) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1
    assert Repo.get_by!(WakeupRecord, run_id: run_id).status == "scheduled"
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert terminal_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.interrupted"]) == 1
    assert count_types(goal.id, run_id, ["run.completed"]) == 0

    ordered = ordered_events(goal.id, run_id)
    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.expired", nil})
    assert sequence_before?(ordered, {"run.suspended", nil}, {:terminal, nil})
    assert sequence_before?(ordered, {"checkpoint.created", nil}, {:terminal, nil})

    lease = Repo.get!(ExecutionLeaseRecord, grant_id)
    assert lease.status == "checkpoint_required"
    refute lease.status in @live_statuses

    assert Repo.get_by!(RunRecord, id: run_id).status == "interrupted"

    assert_projector_caught_up(goal.id)
  end

  test "a launch crash projects terminal rows", %{sup: sup, goal: goal, task: task} do
    # Twin through `crash_land/0`: the adapter raises inside start, so the
    # Elf lands exactly one `run.failed` (`elf_launch_crashed`) terminal with
    # its checkpoint — and must project it the same way.
    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               adapter: RaisingStartAdapter,
               scenario: ElvesHelpers.custom_scenario(:terminal_projection_crash, []),
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               notify: self()
             )

    run_id = ElvesHelpers.run_id_for_dispatch(request.dispatch_id)
    assert is_binary(run_id)

    # `crash_land/0` sends no notification; the DOWN arrives after the stop,
    # which follows the final projection, so rows read below are the Elf's
    # own work with no test-side projection.
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.failed"
    assert event.payload["error_code"] == "elf_launch_crashed"

    assert count_types(goal.id, run_id, ["run.starting"]) == 1
    assert count_types(goal.id, run_id, ["run.running"]) == 0
    assert terminal_checkpoint_count(goal.id, run_id) == 1

    ordered = ordered_events(goal.id, run_id)
    assert sequence_before?(ordered, {"checkpoint.created", nil}, {:terminal, nil})

    assert Repo.get_by!(RunRecord, id: run_id).status == "failed"

    assert_projector_caught_up(goal.id)
  end

  # -- Helpers --

  defp hold_before_first_event(pid), do: :ok = :sys.suspend(pid, 30_000)

  defp release_elf(pid), do: :ok = :sys.resume(pid, 30_000)

  defp wait_running(goal, dispatch_id) do
    assert {:ok, run_id} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.run_id_for_dispatch(dispatch_id) end)

    assert {:ok, _pgid} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

    run_id
  end

  defp fake_scenario(name, capacity, events) do
    %Scenario{
      name: name,
      capacity: capacity,
      start_error: nil,
      resume_error: nil,
      provider_session_id: "fake-session-#{name}",
      events: events,
      delivery_modifier: :none
    }
  end

  defp breached_snapshot(snapshot_id) do
    now = FixedClock.now()

    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: 95.0, reset_at: nil},
            %{kind: "weekly", state: :observed, used_percent: 30.0, reset_at: nil}
          ],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "shoestring.harness.fake",
            provider_id: "codex",
            invocation_mode: "app_server",
            event: :explicit_read
          },
          scope: "account:codex",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  defp grant_for_run!(goal, run_id, admitted_snapshot_id, opts) do
    decision_id = Ecto.UUID.generate()
    grant_id = Ecto.UUID.generate()

    admission =
      CobblerHelpers.append_admission_event!(
        goal.id,
        CobblerHelpers.admission_payload()
        |> Map.merge(%{
          "decision_id" => decision_id,
          "result" => "admit",
          "reason_code" => "automatic_admission_eligible",
          "explanation" => "Elf terminal projection test admission",
          "observation" => %{
            "snapshot_id" => admitted_snapshot_id,
            "confidence" => "high",
            "freshness" => "fresh"
          },
          "proposed_bounds" => %{
            "response_budget" => Keyword.fetch!(opts, :response_budget),
            "tool_budget" => Keyword.fetch!(opts, :tool_budget),
            "deadline" => DateTime.to_iso8601(Keyword.fetch!(opts, :deadline)),
            "checkpoint_cadence" => Keyword.fetch!(opts, :checkpoint_cadence),
            "reserves" => %{
              "response" => get_in(opts, [:reserves, :response]),
              "tool" => get_in(opts, [:reserves, :tool])
            }
          }
        })
      )

    reserves = Keyword.fetch!(opts, :reserves)

    {:ok, lease} =
      ExecutionLease.new(%{
        version: 1,
        grant_id: grant_id,
        run_id: run_id,
        admitted_snapshot_id: admitted_snapshot_id,
        reserves: %{response: reserves.response, tool: reserves.tool},
        response_budget: Keyword.fetch!(opts, :response_budget),
        tool_budget: Keyword.fetch!(opts, :tool_budget),
        deadline: Keyword.fetch!(opts, :deadline),
        checkpoint_cadence: Keyword.fetch!(opts, :checkpoint_cadence),
        renewal_state: :none,
        extensions: %{
          "cobbler.lease:admission_decision_id" => decision_id,
          "cobbler.lease:admission_event_id" => admission.id,
          "cobbler.lease:candidate" => "codex/codex_app_server",
          "cobbler.lease:scope" => "account:codex"
        }
      })

    assert {:ok, %{grant_id: ^grant_id}} = Leases.grant(goal.id, lease)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "active"

    %{grant_id: grant_id, admission_id: admission.id}
  end

  defp count_types(goal_id, run_id, types) do
    ElvesHelpers.count_events(goal_id, run_id, types)
  end

  defp renewal_decisions(goal_id, run_id) do
    Repo.aggregate(
      from(event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.run_id == ^run_id and
            event.type == "admission.decided" and
            like(event.idempotency_key, "lease-renewal-decision:%")
      ),
      :count
    )
  end

  defp dispatch_query(goal_id, run_id) do
    from(record in DispatchRecord,
      where: record.goal_id == ^goal_id and record.run_id == ^run_id
    )
  end

  defp reactive_checkpoint_count(goal_id, run_id) do
    checkpoint_events(goal_id, run_id)
    |> Enum.count(fn event ->
      event.payload["extensions"]["shoestring.elf:checkpoint_kind"] != "terminal"
    end)
  end

  defp terminal_checkpoint_count(goal_id, run_id) do
    checkpoint_events(goal_id, run_id)
    |> Enum.count(fn event ->
      event.payload["extensions"]["shoestring.elf:checkpoint_kind"] == "terminal"
    end)
  end

  defp checkpoint_events(goal_id, run_id) do
    Repo.all(
      from(event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.run_id == ^run_id and
            event.type == "checkpoint.created",
        order_by: [asc: event.sequence]
      )
    )
  end

  defp ordered_events(goal_id, run_id) do
    Repo.all(
      from(event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.run_id == ^run_id,
        order_by: [asc: event.sequence],
        select: {event.sequence, event.type, event.payload}
      )
    )
    |> Enum.map(fn {_sequence, type, payload} ->
      cond do
        type == "harness.event_recorded" ->
          {:harness, payload["source_event_id"]}

        type in ["run.completed", "run.failed", "run.interrupted", "run.cancelled"] ->
          {:terminal, nil}

        true ->
          {type, nil}
      end
    end)
  end

  defp sequence_before?(ordered, left, right) do
    left_index = Enum.find_index(ordered, &(&1 == left))
    right_index = Enum.find_index(ordered, &(&1 == right))

    assert left_index != nil, "expected event #{inspect(left)} in #{inspect(ordered)}"
    assert right_index != nil, "expected event #{inspect(right)} in #{inspect(ordered)}"
    assert left_index < right_index, "expected #{inspect(left)} before #{inspect(right)}"
  end

  defp assert_projector_caught_up(goal_id) do
    position = Repo.get_by!(ProjectorPosition, goal_id: goal_id, projector: "harness")
    assert position.status == "ok"
    assert is_nil(position.error_detail)

    last =
      Repo.one(
        from(event in TrajectoryEvent,
          where: event.goal_id == ^goal_id,
          select: max(event.sequence)
        )
      )

    assert position.last_sequence == last
  end
end
