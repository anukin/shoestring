defmodule Shoestring.Cobbler.ReservationsTest do
  @moduledoc """
  New-capability checks against real, independent SQLite connections. Scratch
  databases are retained; no cleanup/reaper behavior or provider calls. These
  exercise the reservation boundary, not parallel production dispatch.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  import Shoestring.Test.CobblerHelpers, only: [create_goal!: 1, admission_payload: 1]

  alias Shoestring.Cobbler.{
    ReservationPolicy,
    ReservationRecord,
    Reservations,
    ReservationReconciler,
    ReservationSettlementRecord
  }

  alias Shoestring.Harness.{Dispatches, DispatchRecord, Fake, Identity, RunRecord, Runs}
  alias Shoestring.Test.MigrationRepo
  alias Shoestring.Trajectory.{EventRegistry, TrajectoryEvent}

  @now ~U[2026-10-13 12:00:00.000000Z]

  @migrations [
    {20_260_830_012_112, Shoestring.Repo.Migrations.CreateTrajectoryFoundation},
    {20_260_830_023_603, Shoestring.Repo.Migrations.AddProjectorStatusAndFailureDetails},
    {20_260_831_050_006, Shoestring.Repo.Migrations.AddHarnessFoundation},
    {20_260_901_232_504, Shoestring.Repo.Migrations.AddObanDispatch},
    {20_260_901_232_628, Shoestring.Repo.Migrations.EvolveCapacitySnapshotContractV2},
    {20_260_902_232_748, Shoestring.Repo.Migrations.AddHarnessRunRequestExtensions},
    {20_260_903_000_650, Shoestring.Repo.Migrations.HardenCapacitySnapshotContractV2},
    {20_260_903_054_508, Shoestring.Repo.Migrations.CreateCapacityObservatorySingleton},
    {20_260_903_061_948, Shoestring.Repo.Migrations.AddCapacityObservatoryLookupIndex},
    {20_260_903_231_739, Shoestring.Repo.Migrations.RepairCapacityObservatorySingletonTriggers},
    {20_260_905_162_804, Shoestring.Repo.Migrations.AddInterruptedRunStatus},
    {20_260_907_234_352, Shoestring.Repo.Migrations.CreateCobblerFoundation},
    {20_260_907_234_724, Shoestring.Repo.Migrations.AddCobblerCommands},
    {20_260_908_061_716, Shoestring.Repo.Migrations.CreateCobblerWakeups},
    {20_260_909_035_800, Shoestring.Repo.Migrations.AddResponseAttributionToCobblerCommands},
    {20_260_919_034_454, Shoestring.Repo.Migrations.WidenCobblerCommandTypes},
    {20_261_001_014_010, Shoestring.Repo.Migrations.AddCobblerPlanRevisions},
    {20_261_004_192_021, Shoestring.Repo.Migrations.AddPlannerRequests},
    {20_261_007_024_346, Shoestring.Repo.Migrations.AddAgentProfiles},
    {20_261_013_225_751, Shoestring.Repo.Migrations.AddCobblerCapacityReservations},
    {20_261_013_232_327, Shoestring.Repo.Migrations.AddCobblerReservationSettlements},
    {20_261_014_032_811, Shoestring.Repo.Migrations.AddReservationParentOwnership},
    {20_261_014_034_936, Shoestring.Repo.Migrations.AddReservationOperations}
  ]

  setup do
    directory = Path.join(System.tmp_dir!(), "shoestring-reservations-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)

    repo_opts = [
      database: Path.join(directory, "reservations.db"),
      pool_size: 8,
      journal_mode: :wal,
      busy_timeout: 5_000
    ]

    # Historical SQLite table rebuilds use connection-local PRAGMA switches.
    # Migrate on one connection, then reopen with eight independent writers.
    start_supervised!({MigrationRepo, Keyword.put(repo_opts, :pool_size, 1)})
    Ecto.Migrator.run(MigrationRepo, @migrations, :up, all: true, log: false)
    stop_supervised!(MigrationRepo)
    start_supervised!({MigrationRepo, repo_opts})

    goal = create_goal!(MigrationRepo)
    %{goal: goal, repo_opts: repo_opts, opts: [repo: MigrationRepo, now: @now]}
  end

  defp policy(changes \\ %{}) do
    {:ok, policy} = ReservationPolicy.new(changes)
    policy
  end

  defp candidate(goal, changes \\ %{}, payload_changes \\ %{}) do
    payload = admission_payload(provider_id: "codex", scope: "subscription")

    payload =
      Map.merge(payload, %{
        "evaluated_at" => DateTime.to_iso8601(@now),
        "observation" => %{
          "snapshot_id" => Ecto.UUID.generate(),
          "age_seconds" => 5,
          "observed_at" => DateTime.to_iso8601(DateTime.add(@now, -5)),
          "confidence" => "none",
          "freshness" => "fresh"
        },
        "proposed_bounds" => %{
          "response_budget" => 10,
          "tool_budget" => 25,
          "deadline" => DateTime.to_iso8601(DateTime.add(@now, 300))
        }
      })
      |> Map.merge(payload_changes)

    assert {:ok, payload} =
             EventRegistry.validate_payload("admission.decided", 1, payload, now: @now)

    sequence =
      (MigrationRepo.one(
         from e in TrajectoryEvent, where: e.goal_id == ^goal.id, select: max(e.sequence)
       ) || 0) + 1

    event =
      %TrajectoryEvent{
        id: Ecto.UUID.generate(),
        goal_id: goal.id,
        sequence: sequence,
        type: "admission.decided",
        actor: "cobbler",
        schema_version: 1,
        occurred_at: @now,
        payload: payload
      }
      |> TrajectoryEvent.changeset(%{})
      |> MigrationRepo.insert!()

    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        goal_id: goal.id,
        execution_id: Ecto.UUID.generate(),
        plan_task_id: "alpha",
        attempt: 1,
        run_id: Ecto.UUID.generate(),
        admission_event_id: event.id
      },
      changes
    )
  end

  test "hold retains exact admission provenance and ignores caller attempts to choose allowance",
       c do
    attrs = candidate(c.goal)

    assert {:ok, row} =
             Reservations.hold(
               Map.merge(attrs, %{units: 0, scope: "invented", provider_id: "other"}),
               policy(),
               c.opts
             )

    event = MigrationRepo.get!(TrajectoryEvent, attrs.admission_event_id)
    assert row.provider_id == "codex"
    assert row.scope == "subscription"
    assert row.units == 1
    assert row.snapshot_id == event.payload["observation"]["snapshot_id"]
    assert row.observation_age_seconds == 5
    assert row.admission_policy == event.payload["policy"]
    assert row.lease_bounds == event.payload["proposed_bounds"]
    assert row.concurrency_policy == ReservationPolicy.to_map(policy())
    assert row.status == "held"
    assert MigrationRepo.aggregate("harness_runs", :count) == 0
  end

  test "exact replay survives repository restart without acquiring another allowance", c do
    attrs = candidate(c.goal)
    assert {:ok, row} = Reservations.hold(attrs, policy(), c.opts)
    stop_supervised!(MigrationRepo)
    start_supervised!({MigrationRepo, c.repo_opts})

    assert {:ok, same} =
             Reservations.hold(
               attrs,
               policy(),
               Keyword.put(c.opts, :now, DateTime.add(@now, 600))
             )

    assert same == row
    assert Reservations.outstanding(c.opts) == [row]
    assert MigrationRepo.aggregate(ReservationRecord, :count) == 1
  end

  test "replay cannot rebind any ownership field or policy", c do
    attrs = candidate(c.goal)
    assert {:ok, _} = Reservations.hold(attrs, policy(), c.opts)

    for changes <- [
          %{goal_id: Ecto.UUID.generate()},
          %{execution_id: Ecto.UUID.generate()},
          %{run_id: Ecto.UUID.generate()},
          %{plan_task_id: "other"},
          %{attempt: 2},
          %{admission_event_id: Ecto.UUID.generate()}
        ] do
      assert {:error, :reservation_identity_mismatch} =
               Reservations.hold(Map.merge(attrs, changes), policy(), c.opts)
    end

    assert {:error, :reservation_identity_mismatch} =
             Reservations.hold(attrs, policy(%{global_limit: 2}), c.opts)

    assert MigrationRepo.aggregate(ReservationRecord, :count) == 1
  end

  test "global cap spans providers and goals", c do
    assert {:ok, _} = Reservations.hold(candidate(c.goal), policy(), c.opts)
    other = create_goal!(MigrationRepo)

    attrs =
      candidate(other, %{}, %{
        "candidate" => %{
          "provider_id" => "claude",
          "adapter_id" => "claude_code",
          "support_tier" => "reactive_only",
          "compatibility_state" => "compatible"
        }
      })

    assert {:error, {:reservation_blocked, :global_limit}} =
             Reservations.hold(attrs, policy(), c.opts)

    assert MigrationRepo.aggregate(ReservationRecord, :count) == 1
  end

  test "provider-account cap spans goals while unrelated provider can proceed", c do
    policy = policy(%{global_limit: 3, goal_limit: 3, account_units: 3})
    assert {:ok, _} = Reservations.hold(candidate(c.goal), policy, c.opts)
    other = create_goal!(MigrationRepo)

    assert {:error, {:reservation_blocked, :provider_account_limit}} =
             Reservations.hold(candidate(other), policy, c.opts)

    claude = %{
      "provider_id" => "claude",
      "adapter_id" => "claude_code",
      "support_tier" => "reactive_only",
      "compatibility_state" => "compatible"
    }

    assert {:ok, row} =
             Reservations.hold(candidate(other, %{}, %{"candidate" => claude}), policy, c.opts)

    assert row.provider_id == "claude"
    assert MigrationRepo.aggregate(ReservationRecord, :count) == 2
  end

  test "goal cap spans provider buckets", c do
    policy = policy(%{global_limit: 3, provider_account_limit: 3, account_units: 3})
    assert {:ok, _} = Reservations.hold(candidate(c.goal), policy, c.opts)

    claude = %{
      "provider_id" => "claude",
      "adapter_id" => "claude_code",
      "support_tier" => "reactive_only",
      "compatibility_state" => "compatible"
    }

    assert {:error, {:reservation_blocked, :goal_limit}} =
             Reservations.hold(candidate(c.goal, %{}, %{"candidate" => claude}), policy, c.opts)

    assert {:ok, _} = Reservations.hold(candidate(create_goal!(MigrationRepo)), policy, c.opts)
  end

  test "configured weighted units share an account across different observations", c do
    policy =
      policy(%{
        global_limit: 4,
        provider_account_limit: 4,
        goal_limit: 4,
        account_units: 3,
        task_units: 2
      })

    a = candidate(c.goal)
    b = candidate(create_goal!(MigrationRepo))
    assert {:ok, row} = Reservations.hold(a, policy, c.opts)
    assert row.units == 2
    assert {:error, {:reservation_blocked, :account_units}} = Reservations.hold(b, policy, c.opts)

    refute MigrationRepo.get!(TrajectoryEvent, a.admission_event_id).payload["observation"][
             "snapshot_id"
           ] ==
             MigrationRepo.get!(TrajectoryEvent, b.admission_event_id).payload["observation"][
               "snapshot_id"
             ]

    assert MigrationRepo.aggregate(ReservationRecord, :count) == 1
  end

  test "deadline and uncertain ownership never free allowance or authorize replacement", c do
    attrs = candidate(c.goal)
    assert {:ok, row} = Reservations.hold(attrs, policy(), c.opts)
    later = Keyword.put(c.opts, :now, DateTime.add(@now, 600))
    assert Reservations.outstanding(later) == [row]

    assert {:ok, uncertain} =
             Reservations.require_reconciliation(
               row.id,
               "deadline observed; owner unresolved",
               later
             )

    assert uncertain.status == "reconciliation_required"

    assert {:ok, ^uncertain} =
             Reservations.require_reconciliation(row.id, uncertain.reconciliation_reason, later)

    assert {:error, :reconciliation_reason_mismatch} =
             Reservations.require_reconciliation(row.id, "different evidence", later)

    # Give the new candidate a still-valid admission deadline; only ownership blocks it.
    next =
      candidate(create_goal!(MigrationRepo), %{}, %{
        "proposed_bounds" => %{"deadline" => DateTime.to_iso8601(DateTime.add(@now, 900))}
      })

    assert {:error, {:reservation_blocked, :global_limit}} =
             Reservations.hold(next, policy(), later)

    assert Reservations.outstanding(later) == [uncertain]
    assert {:ok, ^uncertain} = Reservations.hold(attrs, policy(), later)
  end

  test "changing configured policy cannot erase outstanding ownership", c do
    assert {:ok, row} = Reservations.hold(candidate(c.goal), policy(), c.opts)

    changed =
      policy(%{global_limit: 2, provider_account_limit: 2, goal_limit: 2, account_units: 2})

    assert {:error, :reservation_policy_change_requires_reconciliation} =
             Reservations.hold(candidate(create_goal!(MigrationRepo)), changed, c.opts)

    assert Reservations.outstanding(c.opts) == [row]
  end

  test "invalid ownership, foreign goals, rejected, expired and missing observation admissions fail closed",
       c do
    valid = candidate(c.goal)

    for changes <- [%{id: "invalid"}, %{attempt: 0}, %{plan_task_id: "../escape"}] do
      assert {:error, :invalid_reservation_identity} =
               Reservations.hold(Map.merge(valid, changes), policy(), c.opts)
    end

    for changes <- [%{goal_id: Ecto.UUID.generate()}, %{admission_event_id: Ecto.UUID.generate()}] do
      assert {:error, :reservation_admission_mismatch} =
               Reservations.hold(Map.merge(valid, changes), policy(), c.opts)
    end

    for payload <- [
          %{"result" => "reject"},
          %{"run_id" => Ecto.UUID.generate()},
          %{"observation" => %{"snapshot_id" => nil}},
          %{"policy" => %{}},
          %{"proposed_bounds" => %{"deadline" => 123}},
          %{"proposed_bounds" => %{"deadline" => DateTime.to_iso8601(@now)}}
        ] do
      assert {:error, :reservation_admission_mismatch} =
               Reservations.hold(candidate(c.goal, %{}, payload), policy(), c.opts)
    end

    assert Reservations.outstanding(c.opts) == []
  end

  test "attempt, run and admission IDs cannot be consumed twice under new reservation IDs", c do
    policy =
      policy(%{global_limit: 8, provider_account_limit: 8, goal_limit: 8, account_units: 8})

    attrs = candidate(c.goal)
    assert {:ok, _} = Reservations.hold(attrs, policy, c.opts)

    for next <- [
          Map.put(attrs, :id, Ecto.UUID.generate()),
          Map.merge(attrs, %{
            id: Ecto.UUID.generate(),
            execution_id: Ecto.UUID.generate(),
            run_id: Ecto.UUID.generate()
          }),
          candidate(c.goal, %{run_id: attrs.run_id}),
          candidate(c.goal, %{execution_id: attrs.execution_id})
        ] do
      assert {:error, {:reservation_conflict, %Ecto.Changeset{}}} =
               Reservations.hold(next, policy, c.opts)
    end

    assert MigrationRepo.aggregate(ReservationRecord, :count) == 1
  end

  test "missing observation time stays unknown and invalid reconciliation creates no facts", c do
    attrs =
      candidate(c.goal, %{}, %{
        "observation" => %{"snapshot_id" => Ecto.UUID.generate(), "confidence" => "none"}
      })

    assert {:ok, row} = Reservations.hold(attrs, policy(), c.opts)
    assert row.observation_age_seconds == nil

    assert {:error, :invalid_reconciliation} =
             Reservations.require_reconciliation(row.id, "", c.opts)

    assert {:error, :invalid_reconciliation} =
             Reservations.require_reconciliation("invalid", "unresolved", c.opts)

    assert {:error, :reservation_not_found} =
             Reservations.require_reconciliation(Ecto.UUID.generate(), "unresolved", c.opts)

    assert Reservations.outstanding(c.opts) == [row]

    assert {:error, _} =
             Reservations.hold(candidate(c.goal), %ReservationPolicy{global_limit: 0}, c.opts)
  end

  test "eight concurrent independent connections cannot double-claim three shared units", c do
    policy =
      policy(%{global_limit: 8, provider_account_limit: 8, goal_limit: 8, account_units: 3})

    candidates = Enum.map(1..8, fn _ -> candidate(create_goal!(MigrationRepo)) end)
    results = race(candidates, policy, c.opts)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 3
    assert Enum.count(results, &(&1 == {:error, {:reservation_blocked, :account_units}})) == 5
    assert MigrationRepo.aggregate(ReservationRecord, :sum, :units) == 3
  end

  test "eight concurrent exact replays converge on one durable reservation", c do
    attrs = candidate(c.goal)
    results = race(List.duplicate(attrs, 8), policy(), c.opts)
    assert Enum.all?(results, &match?({:ok, %{id: id}} when id == attrs.id, &1))
    assert MigrationRepo.aggregate(ReservationRecord, :count) == 1
  end

  test "no-intent orphan release is durable, frees allowance and cannot be revived", c do
    attrs = candidate(c.goal)
    assert {:ok, held} = Reservations.hold(attrs, policy(), c.opts)

    assert {:ok, %{disposition: :released, settlement: settlement}} =
             Reservations.reconcile(attrs.id, c.opts)

    assert settlement.kind == "released"
    assert settlement.evidence["basis"] == "no_run_intent_or_activity"
    assert Reservations.outstanding(c.opts) == []
    assert MigrationRepo.get!(ReservationRecord, held.id) == held
    stop_supervised!(MigrationRepo)
    start_supervised!({MigrationRepo, c.repo_opts})

    assert {:ok, %{disposition: :replayed, settlement: ^settlement}} =
             Reservations.reconcile(attrs.id, c.opts)

    assert {:error, :reservation_settled} = Reservations.hold(attrs, policy(), c.opts)

    assert {:error, :reservation_settled} =
             Reservations.require_reconciliation(attrs.id, "late probe", c.opts)

    {request, identity} = request(c, attrs)

    assert {:error, :reservation_settled} =
             Runs.request(request, identity, Keyword.put(c.opts, :run_id, attrs.run_id))

    assert MigrationRepo.get(RunRecord, attrs.run_id) == nil

    assert {:error, :reservation_settled} =
             Dispatches.enqueue(request, identity, Keyword.put(c.opts, :run_id, attrs.run_id))

    assert MigrationRepo.get(RunRecord, attrs.run_id) == nil
    assert {:ok, _} = Reservations.hold(candidate(create_goal!(MigrationRepo)), policy(), c.opts)
  end

  test "all canonical terminal classes close only after absence evidence", c do
    open = policy(%{global_limit: 8, provider_account_limit: 8, goal_limit: 8, account_units: 8})

    for type <- ~w(run.completed run.failed run.cancelled run.interrupted) do
      attrs = candidate(c.goal)
      assert {:ok, held} = Reservations.hold(attrs, open, c.opts)
      run = intent!(c, attrs)
      running = run_event!(run, "run.running", %{"process_id" => "pgid:123456"})

      fields =
        if type == "run.failed",
          do: %{"error_category" => "transport", "error_code" => "supervisor_crash"},
          else: %{}

      terminal = run_event!(run, type, fields)
      opts = Keyword.put(c.opts, :group_probe, fn [123_456] -> :absent end)

      assert {:ok, %{disposition: :closed, settlement: settlement}} =
               Reservations.reconcile(attrs.id, opts)

      assert settlement.kind == "consumed_closed"
      assert settlement.evidence["terminal_event_id"] == terminal.id
      assert settlement.evidence["running_event_ids"] == [running.id]
      refute Map.has_key?(settlement.evidence, "pgid")
      assert MigrationRepo.get!(ReservationRecord, held.id) == held
      assert {:error, :reservation_settled} = Reservations.authorize(MigrationRepo, run)

      assert {:error, :reserved_run_requires_coordinator} =
               Shoestring.Elves.resume_run(run.id, c.opts)

      assert {:ok, %{disposition: :replayed, settlement: ^settlement}} =
               Reservations.reconcile(
                 attrs.id,
                 Keyword.put(c.opts, :group_probe, fn _ -> flunk("replay must not probe") end)
               )
    end

    assert Reservations.outstanding(c.opts) == []
    assert MigrationRepo.aggregate(ReservationSettlementRecord, :count) == 4
  end

  test "live Elf, live group and unknown probes retain consumption and never cancel work", c do
    attrs = candidate(c.goal)
    assert {:ok, _} = Reservations.hold(attrs, policy(), c.opts)
    run = intent!(c, attrs)
    run_event!(run, "run.running", %{"process_id" => "123456"})

    run_event!(run, "run.failed", %{
      "error_category" => "transport",
      "error_code" => "supervisor_crash"
    })

    assert {:ok, %{disposition: :retained, reason: :elf_running}} =
             Reservations.reconcile(
               attrs.id,
               Keyword.put(c.opts, :elf_lookup, fn _ -> self() end)
             )

    for {probe, reason} <- [
          {fn _ -> :alive end, :process_group_alive},
          {fn _ -> :unknown end, :process_group_unknown},
          {fn _ -> raise "probe failed" end, :process_group_unknown}
        ] do
      assert {:ok, %{disposition: :retained, reason: ^reason}} =
               Reservations.reconcile(attrs.id, Keyword.put(c.opts, :group_probe, probe))

      assert length(Reservations.outstanding(c.opts)) == 1
      assert MigrationRepo.aggregate(ReservationSettlementRecord, :count) == 0
    end

    uncertain = MigrationRepo.get!(ReservationRecord, attrs.id)
    assert uncertain.reconciliation_reason == "process_group_alive"

    assert {:error, {:reservation_blocked, :global_limit}} =
             Reservations.hold(candidate(create_goal!(MigrationRepo)), policy(), c.opts)

    assert {:ok, %{disposition: :closed}} =
             Reservations.reconcile(
               attrs.id,
               Keyword.put(c.opts, :group_probe, fn _ -> :absent end)
             )
  end

  test "delivered and cancelled jobs are not run termination evidence", c do
    attrs = candidate(c.goal)
    assert {:ok, _} = Reservations.hold(attrs, policy(), c.opts)
    run = intent!(c, attrs)

    for status <- ["effect_completed", "effect_unknown", "cancelled"] do
      dispatch =
        MigrationRepo.get(DispatchRecord, run.dispatch_id) ||
          %DispatchRecord{
            dispatch_id: run.dispatch_id,
            goal_id: run.goal_id,
            task_id: run.task_id,
            run_id: run.id,
            request_version: 1
          }

      dispatch |> Ecto.Changeset.change(status: status) |> MigrationRepo.insert_or_update!()

      assert {:ok, %{disposition: :retained, reason: :run_not_terminal}} =
               Reservations.reconcile(attrs.id, c.opts)
    end

    assert length(Reservations.outstanding(c.opts)) == 1
    assert MigrationRepo.get!(RunRecord, run.id).status == "requested"
    assert MigrationRepo.aggregate(ReservationSettlementRecord, :count) == 0
  end

  test "missing, malformed and post-terminal process identities fail closed", c do
    open = policy(%{global_limit: 8, provider_account_limit: 8, goal_limit: 8, account_units: 8})

    for {process_id, reason} <- [
          {nil, :process_identity_invalid},
          {"pgid:123abc", :process_identity_invalid},
          {"pgid:1", :process_identity_invalid},
          {"missing", :process_identity_missing},
          {"after", :activity_after_terminal}
        ] do
      attrs = candidate(c.goal)
      assert {:ok, _} = Reservations.hold(attrs, open, c.opts)
      run = intent!(c, attrs)

      unless process_id in ["missing", "after"],
        do: run_event!(run, "run.running", %{"process_id" => process_id})

      run_event!(run, "run.completed", %{})

      if process_id == "after",
        do: run_event!(run, "run.running", %{"process_id" => "pgid:123456"})

      assert {:ok, %{disposition: :retained, reason: ^reason}} =
               Reservations.reconcile(
                 attrs.id,
                 Keyword.put(c.opts, :group_probe, fn _ ->
                   flunk("invalid identity must never be probed")
                 end)
               )
    end

    assert length(Reservations.outstanding(c.opts)) == 5
  end

  test "every recorded group is probed, with a bounded fail-closed history", c do
    attrs = candidate(c.goal)
    assert {:ok, _} = Reservations.hold(attrs, policy(), c.opts)
    run = intent!(c, attrs)
    run_event!(run, "run.running", %{"process_id" => "pgid:123456"})
    run_event!(run, "run.running", %{"process_id" => "pgid:123457"})
    run_event!(run, "run.completed", %{})

    assert {:ok, %{disposition: :retained}} =
             Reservations.reconcile(
               attrs.id,
               Keyword.put(c.opts, :group_probe, fn ids ->
                 assert Enum.sort(ids) == [123_456, 123_457]
                 :alive
               end)
             )

    assert {:ok, %{disposition: :closed}} =
             Reservations.reconcile(
               attrs.id,
               Keyword.put(c.opts, :group_probe, fn ids ->
                 assert Enum.sort(ids) == [123_456, 123_457]
                 :absent
               end)
             )

    next = candidate(c.goal)
    assert {:ok, _} = Reservations.hold(next, policy(), c.opts)
    next_run = intent!(c, next)

    Enum.each(1..65, fn _ ->
      run_event!(next_run, "run.running", %{"process_id" => "pgid:123456"})
    end)

    run_event!(next_run, "run.completed", %{})

    assert {:ok, %{disposition: :retained, reason: :process_identity_bound_exceeded}} =
             Reservations.reconcile(next.id, c.opts)
  end

  test "orphan activity or unavailable Elf ownership is uncertainty, never release", c do
    attrs = candidate(c.goal)
    assert {:ok, _} = Reservations.hold(attrs, policy(), c.opts)

    assert {:ok, %{disposition: :retained, reason: :elf_ownership_unknown}} =
             Reservations.reconcile(
               attrs.id,
               Keyword.put(c.opts, :elf_lookup, fn _ -> raise "registry unavailable" end)
             )

    run_event!(%{id: attrs.run_id, goal_id: c.goal.id, task_id: nil}, "run.starting", %{})

    assert {:ok, %{disposition: :retained, reason: :orphan_has_activity}} =
             Reservations.reconcile(attrs.id, c.opts)

    assert length(Reservations.outstanding(c.opts)) == 1
    assert MigrationRepo.aggregate(ReservationSettlementRecord, :count) == 0
    assert {:error, :reservation_not_found} = Reservations.reconcile(Ecto.UUID.generate(), c.opts)
    assert {:error, :invalid_reservation_identity} = Reservations.reconcile("invalid", c.opts)
  end

  test "reservation must precede intent and is bound to goal and admitted adapter", c do
    attrs = candidate(c.goal)
    assert {:ok, _} = Reservations.hold(attrs, policy(), c.opts)
    run = intent!(c, attrs)
    assert :ok = Reservations.authorize(MigrationRepo, run)

    assert {:error, :reservation_owner_mismatch} =
             Reservations.authorize(MigrationRepo, %{run | goal_id: Ecto.UUID.generate()})

    assert {:error, :reservation_provider_mismatch} =
             Reservations.authorize(MigrationRepo, %{run | provider_id: "other"})

    assert :ok = Reservations.authorize(MigrationRepo, %{run | id: Ecto.UUID.generate()})

    assert {:error, :reservation_run_already_exists} =
             Reservations.hold(candidate(c.goal, %{run_id: run.id}), policy(), c.opts)

    assert {:error, :reserved_run_requires_coordinator} =
             Shoestring.Elves.resume_run(run.id, c.opts)

    assert :ok =
             Reservations.authorize_direct_resume(MigrationRepo, %{run | id: Ecto.UUID.generate()})

    assert {:ok, _} = Reservations.require_reconciliation(attrs.id, "owner uncertain", c.opts)

    assert {:error, :reservation_requires_reconciliation} =
             Reservations.authorize(MigrationRepo, run)
  end

  test "concurrent orphan reconciliation creates exactly one append-only settlement", c do
    attrs = candidate(c.goal)
    assert {:ok, _} = Reservations.hold(attrs, policy(), c.opts)

    results =
      race_calls(Enum.map(1..8, fn _ -> fn -> Reservations.reconcile(attrs.id, c.opts) end end))

    assert Enum.count(results, &match?({:ok, %{disposition: :released}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{disposition: :replayed}}, &1)) == 7
    assert MigrationRepo.aggregate(ReservationSettlementRecord, :count) == 1
  end

  test "concurrent intent creation and orphan release cannot both win", c do
    attrs = candidate(c.goal)
    assert {:ok, _} = Reservations.hold(attrs, policy(), c.opts)
    {request, identity} = request(c, attrs)

    {:ok, changeset} =
      Runs.build_intent_changeset(request, identity, Keyword.put(c.opts, :run_id, attrs.run_id))

    [intent, reconciliation] =
      race_calls([
        fn -> Runs.insert_or_recover(MigrationRepo, changeset) end,
        fn -> Reservations.reconcile(attrs.id, c.opts) end
      ])

    case intent do
      {:ok, run} ->
        assert run.id == attrs.run_id
        assert {:ok, %{disposition: :retained, reason: :run_not_terminal}} = reconciliation
        assert MigrationRepo.get(ReservationSettlementRecord, attrs.id) == nil

      {:error, :reservation_settled} ->
        assert {:ok, %{disposition: :released}} = reconciliation
        assert MigrationRepo.get(RunRecord, attrs.run_id) == nil
    end
  end

  test "production probe distinguishes a live local group from its verified exit" do
    assert ReservationReconciler.probe_groups([]) == :unknown
    assert ReservationReconciler.probe_groups([1]) == :unknown
    assert ReservationReconciler.probe_groups(["123"]) == :unknown
    {:ok, runner} = Shoestring.Elves.PortRunner.spawn(["sleep", "30"])

    try do
      assert ReservationReconciler.probe_groups([runner.pgid]) == :alive

      assert {:ok, _} =
               Shoestring.Elves.PortRunner.terminate(runner,
                 kill_grace_ms: 100,
                 reap_timeout_ms: 1000
               )

      assert ReservationReconciler.probe_groups([runner.pgid]) == :absent
    after
      Shoestring.Elves.PortRunner.terminate(runner, kill_grace_ms: 100, reap_timeout_ms: 1000)
      Shoestring.Elves.PortRunner.close(runner)
    end
  end

  defp request(c, attrs) do
    task =
      %Shoestring.Trajectory.Task{goal_id: c.goal.id, title: "Fixture task"}
      |> Ecto.Changeset.change()
      |> MigrationRepo.insert!()

    request = Shoestring.Test.ElvesHelpers.run_request(c.goal, task)
    candidate = MigrationRepo.get!(TrajectoryEvent, attrs.admission_event_id).payload["candidate"]

    %Identity{} = fake = Fake.identity()

    identity = %Identity{
      fake
      | provider: candidate["provider_id"],
        adapter_id: candidate["adapter_id"]
    }

    {request, identity}
  end

  defp intent!(c, attrs) do
    {request, identity} = request(c, attrs)

    assert {:ok, changeset} =
             Runs.build_intent_changeset(
               request,
               identity,
               Keyword.put(c.opts, :run_id, attrs.run_id)
             )

    assert {:ok, run} = Runs.insert_or_recover(MigrationRepo, changeset)
    run
  end

  defp run_event!(run, type, fields) do
    payload = Map.put(fields, "run_id", run.id)
    assert {:ok, payload} = EventRegistry.validate_payload(type, 1, payload, now: @now)

    sequence =
      (MigrationRepo.one(
         from e in TrajectoryEvent, where: e.goal_id == ^run.goal_id, select: max(e.sequence)
       ) || 0) + 1

    %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: run.goal_id,
      task_id: run.task_id,
      run_id: run.id,
      sequence: sequence,
      type: type,
      actor: "elf",
      schema_version: 1,
      occurred_at: @now,
      payload: payload
    }
    |> TrajectoryEvent.changeset(%{})
    |> MigrationRepo.insert!()
  end

  test "one closed predecessor admits at most one successor while keeping its original attempt",
       c do
    policy =
      policy(%{global_limit: 4, provider_account_limit: 4, goal_limit: 4, account_units: 4})

    attrs = candidate(c.goal)
    assert {:ok, parent} = Reservations.hold(attrs, policy, c.opts)
    run = intent!(c, attrs)
    run_event!(run, "run.running", %{"process_id" => "pgid:123456"})
    run_event!(run, "run.interrupted", %{})

    assert {:ok, %{disposition: :closed}} =
             Reservations.reconcile(
               parent.id,
               Keyword.put(c.opts, :group_probe, fn _ -> :absent end)
             )

    successors =
      for _ <- 1..2 do
        candidate(
          c.goal,
          %{
            parent_id: parent.id,
            execution_id: parent.execution_id,
            plan_task_id: parent.plan_task_id,
            attempt: parent.attempt
          },
          %{"run_id" => parent.run_id}
        )
      end

    results = race(successors, policy, c.opts)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:reservation_conflict, _}}, &1)) == 1
    assert [child] = Reservations.outstanding(c.opts)
    assert child.parent_id == parent.id
    assert child.attempt == parent.attempt
    assert MigrationRepo.aggregate(ReservationRecord, :count) == 2
    assert MigrationRepo.get!(ReservationRecord, parent.id) == parent
  end

  test "a successor cannot change its predecessor goal, execution, task or attempt", c do
    attrs = candidate(c.goal)
    assert {:ok, parent} = Reservations.hold(attrs, policy(), c.opts)
    run = intent!(c, attrs)
    run_event!(run, "run.running", %{"process_id" => "pgid:123456"})
    run_event!(run, "run.interrupted", %{})

    assert {:ok, %{disposition: :closed}} =
             Reservations.reconcile(
               parent.id,
               Keyword.put(c.opts, :group_probe, fn _ -> :absent end)
             )

    for changes <- [
          %{execution_id: Ecto.UUID.generate()},
          %{plan_task_id: "foreign"},
          %{attempt: 2}
        ] do
      identity =
        Map.merge(
          %{
            parent_id: parent.id,
            execution_id: parent.execution_id,
            plan_task_id: parent.plan_task_id,
            attempt: parent.attempt
          },
          changes
        )

      assert {:error, :reservation_admission_mismatch} =
               Reservations.hold(
                 candidate(c.goal, identity, %{"run_id" => parent.run_id}),
                 policy(),
                 c.opts
               )
    end

    other = create_goal!(MigrationRepo)

    assert {:error, :reservation_admission_mismatch} =
             Reservations.hold(
               candidate(
                 other,
                 %{
                   parent_id: parent.id,
                   execution_id: parent.execution_id,
                   plan_task_id: parent.plan_task_id,
                   attempt: parent.attempt
                 },
                 %{"run_id" => parent.run_id}
               ),
               policy(),
               c.opts
             )

    assert Reservations.outstanding(c.opts) == []
    assert MigrationRepo.aggregate(ReservationRecord, :count) == 1
  end

  test "upgrading a populated reservation table preserves every existing value", c do
    attrs = candidate(c.goal)
    assert {:ok, held} = Reservations.hold(attrs, policy(), c.opts)
    stop_supervised!(MigrationRepo)

    older_opts =
      c.repo_opts |> Keyword.put(:pool_size, 1) |> Keyword.update!(:database, &(&1 <> ".upgrade"))

    start_supervised!({MigrationRepo, older_opts})
    Ecto.Migrator.run(MigrationRepo, Enum.drop(@migrations, -2), :up, all: true, log: false)
    goal = create_goal!(MigrationRepo)
    admission = candidate(goal)

    values =
      held
      |> Map.from_struct()
      |> Map.take(ReservationRecord.__schema__(:fields))
      |> Map.delete(:parent_id)

    values =
      Map.merge(values, %{goal_id: goal.id, admission_event_id: admission.admission_event_id})

    assert {1, nil} = MigrationRepo.insert_all(ReservationRecord, [values])

    before =
      Ecto.Adapters.SQL.query!(MigrationRepo, "SELECT * FROM cobbler_capacity_reservations")

    Ecto.Migrator.run(MigrationRepo, @migrations, :up, all: true, log: false)
    columns = Enum.map_join(before.columns, ",", &~s("#{&1}"))

    after_upgrade =
      Ecto.Adapters.SQL.query!(
        MigrationRepo,
        "SELECT #{columns} FROM cobbler_capacity_reservations"
      )

    assert after_upgrade.rows == before.rows
    assert MigrationRepo.get!(ReservationRecord, held.id).parent_id == nil

    assert {:ok, replay} =
             Reservations.hold(
               Map.merge(attrs, %{
                 goal_id: goal.id,
                 admission_event_id: admission.admission_event_id
               }),
               policy(),
               c.opts
             )

    assert replay.id == held.id
  end

  defp race(candidates, policy, opts) do
    race_calls(
      Enum.map(candidates, fn attrs -> fn -> Reservations.hold(attrs, policy, opts) end end)
    )
  end

  test "independent writers cannot commit both foreign legacy and reserved ownership", c do
    other = create_goal!(MigrationRepo)
    attrs = candidate(c.goal)
    legacy = candidate(other)
    admission = MigrationRepo.get!(TrajectoryEvent, legacy.admission_event_id)
    command = Shoestring.Test.CobblerHelpers.claim_command(admission)

    [held, claimed] =
      race_calls([
        fn -> Reservations.hold(attrs, policy(), c.opts) end,
        fn -> Shoestring.Cobbler.Commands.submit(other.id, command, c.opts) end
      ])

    case held do
      {:ok, owner} ->
        assert {:ok,
                %{
                  command: %{
                    status: "rejected",
                    result: %{"reason" => "reservation_ownership_held"}
                  }
                }} = claimed

        assert Shoestring.Cobbler.Commands.active_claim(repo: MigrationRepo) == nil
        assert Reservations.outstanding(c.opts) == [owner]

      {:error, {:reservation_blocked, :legacy_claim}} ->
        assert {:ok, %{command: %{status: "resolved", result: %{"kind" => "claimed"}}}} = claimed
        assert Shoestring.Cobbler.Commands.active_claim(repo: MigrationRepo).goal_id == other.id
        assert Reservations.outstanding(c.opts) == []
    end
  end

  defp race_calls(calls) do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    tasks =
      Enum.map(calls, fn call ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> call.()
          after
            10_000 -> raise "reservation race start timed out"
          end
        end)
      end)

    Enum.each(tasks, fn %{pid: pid} -> assert_receive {:ready, ^pid}, 10_000 end)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end
end
