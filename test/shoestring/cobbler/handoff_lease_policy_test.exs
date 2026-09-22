defmodule Shoestring.Cobbler.HandoffLeasePolicyTest do
  @moduledoc """
  The durable per-transfer handoff lease policy: its 2700-second default, its
  bounded caller override, its fail-closed validation, and its survival
  across enqueue, replay and boot reconciliation.

  ## Lock-vs-documentation ledger (base `733c39b`, measured)

  Stated precisely, because "it fails on base" and "it locks a behaviour" are
  not the same claim. Run against base, this file is 17 failures of 22.

  **TRUE BEHAVIOURAL LOCKS (12)** — they fail on a VALUE or on base
  accepting what should be refused, never on a missing name:

    * the four deadline/bound tests report base's actual grant
      (`left: 300` against 2700/600/900/1800; `left: 25` against a
      99 `tool_budget`). At base the receiver's lease is minted from
      `AdmissionPolicy.default()`, whose 300-second deadline was chosen for a
      warm *wake* and is spent entirely on harness startup by a cold
      cross-provider session — and `Shoestring.Cobbler.HandoffWorker` passes
      no `:policy`, so no operator could say otherwise;
    * `"the stored policy is normalized, and digest-covered"` reports
      `left: nil`: base stores no policy at all, so nothing is digest-covered;
    * the five fail-closed tests fail because base **ACCEPTS** every one of
      them — an unknown field, an unknown reserve key, an out-of-range bound,
      a non-object, a reserve at or above its budget all return `{:ok, ...}`.
      Base does not reject unknown payload keys; it silently DROPS them, so
      an operator's `lease_policy` was accepted and then ignored entirely.
      That is the more dangerous half of the defect and these lock it;
    * `"a malformed durable policy is a permanent error"` fails on the value:
      base's `permanent_error?/1` returns `false` for the tag.

  **DOCUMENTATION, NOT LOCKS (5)** — they fail at base on
  `UndefinedFunctionError` because `Shoestring.Cobbler.HandoffLeasePolicy`
  does not exist there. They pin the new module's surface; they do not prove
  a defect, and are not claimed to: `default/0`, `from_intent/1`,
  `to_admission_policy/2`, `policy_keys/0`, and the payload-shape test that
  calls `from_intent/1`.

  **PASSES AT BASE (5)**, correctly — they are guards, not defect locks:
  `"the other bounds and the reserve rule are unchanged"` (base already
  granted 10/25/1/1), the three refusal/hard-stop twins (a lease policy has
  never been able to lift a refusal), and the identical-policy replay.

  Delivery always goes through `HandoffWorker.perform/1`, never through
  `Handoffs.perform/3` directly, so what is asserted is what production does.

  Hermetic: Oban `testing: :manual`, an injected snapshot fun, and no adapter
  start. Never a provider CLI, never the network.
  """
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Commands, HandoffLeasePolicy, Handoffs}
  alias Shoestring.Harness.{CapacitySnapshot, DispatchRecord, ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Harness.Projector
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @t0 Shoestring.Test.FixedClock.now()

  @sender_provider "codex_app_server_stdio"
  @receiver_provider "fake"
  @receiver_adapter "shoestring.harness.fake"
  @receiver_scope "account:fake"

  setup do
    previous = %{
      observe: Application.get_env(:shoestring, :handoff_observe),
      clock: Application.get_env(:shoestring, :dispatch_clock)
    }

    Application.put_env(:shoestring, :dispatch_clock, Shoestring.Test.FixedClock)

    Application.put_env(:shoestring, :handoff_observe, fn _scoping ->
      {:ok, eligible_snapshot!()}
    end)

    on_exit(fn ->
      restore(:handoff_observe, previous.observe)
      restore(:dispatch_clock, previous.clock)
    end)

    :ok
  end

  # ----------------------------------------------------------------------------
  # The default
  # ----------------------------------------------------------------------------

  describe "the handoff default deadline is 2700 seconds" do
    test "a transfer carrying no lease policy grants a 2700-second deadline" do
      fixture = fixture()

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))
      assert :ok = perform_delivery(job)

      lease = receiver_lease!(fixture)

      # 2700, not the wake-shaped 300. A cold cross-provider session spends
      # the first minutes on harness startup; a 300-second lease was dead on
      # arrival.
      assert DateTime.diff(lease.deadline, @t0, :second) == 2700
      assert HandoffLeasePolicy.default_deadline_seconds() == 2700
    end

    test "the other bounds and the reserve rule are unchanged by the relaxed deadline" do
      fixture = fixture()

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))
      assert :ok = perform_delivery(job)

      lease = receiver_lease!(fixture)

      # Relaxing the clock does not relax the spend.
      assert lease.response_budget == 10
      assert lease.tool_budget == 25
      assert lease.checkpoint_cadence == 1
      assert lease.response_reserve == 1
      assert lease.tool_reserve == 1

      # And the reserve stays strictly below its budget, so the receiver is
      # not renewal-due at zero spend.
      assert lease.response_reserve < lease.response_budget
      assert lease.tool_reserve < lease.tool_budget
    end

    test "an unpoliced intent keeps its previous payload shape, so its digest is unchanged" do
      fixture = fixture()
      attrs = handoff_attrs(fixture)

      {:ok, %{command: command}} = Handoffs.request(fixture.goal.id, attrs)

      # Absent stays absent: the field does not appear on a payload that did
      # not ask for it, so an intent submitted before this field existed still
      # replays under the same digest.
      refute Map.has_key?(command.payload, "lease_policy")
      refute Map.has_key?(command.result, "lease_policy")

      # And the default still applies to it.
      assert {:ok, policy} = HandoffLeasePolicy.from_intent(command.result)
      assert policy.deadline_seconds == 2700
    end
  end

  # ----------------------------------------------------------------------------
  # The bounded override
  # ----------------------------------------------------------------------------

  describe "an explicit bounded override is honoured" do
    test "a caller policy sets the receiver's deadline, budgets, cadence and reserves" do
      fixture = fixture()

      policy = %{
        "deadline_seconds" => 600,
        "response_budget" => 40,
        "tool_budget" => 80,
        "checkpoint_cadence" => 4,
        "reserves" => %{"response" => 3, "tool" => 5}
      }

      {:ok, %{job: job}} =
        Handoffs.request(fixture.goal.id, handoff_attrs(fixture, %{"lease_policy" => policy}))

      assert :ok = perform_delivery(job)

      lease = receiver_lease!(fixture)
      assert DateTime.diff(lease.deadline, @t0, :second) == 600
      assert lease.response_budget == 40
      assert lease.tool_budget == 80
      assert lease.checkpoint_cadence == 4
      assert lease.response_reserve == 3
      assert lease.tool_reserve == 5
    end

    test "the policy the live 2026-09-21 transfer actually used is expressible" do
      fixture = fixture()

      # The bounds are not invented. `live-cross-provider-handoff.md` §6.3
      # records leg 2 stopping mid-task on the 300-second default, and leg 3
      # completing with exactly this operator policy passed as `perform/3`'s
      # `:policy` option — which it had to go direct for, because the worker
      # had no channel for one. This asserts the allow-list and the ranges
      # accommodate that real transfer through the WORKER.
      {:ok, %{job: job}} =
        Handoffs.request(
          fixture.goal.id,
          handoff_attrs(fixture, %{
            "lease_policy" => %{
              "deadline_seconds" => 2700,
              "response_budget" => 400,
              "tool_budget" => 1000,
              "checkpoint_cadence" => 50
            }
          })
        )

      assert :ok = perform_delivery(job)

      lease = receiver_lease!(fixture)
      assert DateTime.diff(lease.deadline, @t0, :second) == 2700
      assert lease.response_budget == 400
      assert lease.tool_budget == 1000
      assert lease.checkpoint_cadence == 50
    end

    test "a partial policy takes the handoff defaults for everything it omits" do
      fixture = fixture()

      {:ok, %{job: job}} =
        Handoffs.request(
          fixture.goal.id,
          handoff_attrs(fixture, %{"lease_policy" => %{"tool_budget" => 99}})
        )

      assert :ok = perform_delivery(job)

      lease = receiver_lease!(fixture)
      assert lease.tool_budget == 99
      assert DateTime.diff(lease.deadline, @t0, :second) == 2700
      assert lease.response_budget == 10
    end

    test "the stored policy is normalized, and digest-covered" do
      fixture = fixture()
      policy = %{"deadline_seconds" => 900}

      attrs = handoff_attrs(fixture, %{"lease_policy" => policy})
      {:ok, %{command: command}} = Handoffs.request(fixture.goal.id, attrs)

      # Normalized at request time: the stored object is complete, so a replay
      # compares equal instead of re-deriving defaults.
      assert command.payload["lease_policy"] == %{
               "deadline_seconds" => 900,
               "response_budget" => 10,
               "tool_budget" => 25,
               "checkpoint_cadence" => 1,
               "reserves" => %{"response" => 1, "tool" => 1}
             }

      # Carried onto the resolved result, which is what `perform/3` replays
      # against.
      assert command.result["lease_policy"] == command.payload["lease_policy"]

      # Digest-covered: the SAME command id with a DIFFERENT policy is a
      # conflict, not a silent re-bounding of an intent that may be executing.
      conflicting =
        attrs
        |> put_in(["payload", "lease_policy"], %{"deadline_seconds" => 1200})

      assert {:error, _reason} = Handoffs.request(fixture.goal.id, conflicting)

      # The original intent is untouched.
      assert Repo.get!(Shoestring.Cobbler.CommandRecord, command.id).result["lease_policy"][
               "deadline_seconds"
             ] == 900
    end

    test "re-requesting the identical policy replays the intent and appends nothing" do
      fixture = fixture()
      attrs = handoff_attrs(fixture, %{"lease_policy" => %{"deadline_seconds" => 900}})

      {:ok, %{command: first}} = Handoffs.request(fixture.goal.id, attrs)
      events_before = Repo.aggregate(TrajectoryEvent, :count, :id)

      {:ok, %{command: second, outcome: outcome}} = Handoffs.request(fixture.goal.id, attrs)

      assert outcome == :replayed
      assert second.id == first.id
      assert second.digest == first.digest
      assert Repo.aggregate(TrajectoryEvent, :count, :id) == events_before
    end
  end

  # ----------------------------------------------------------------------------
  # Fail closed
  # ----------------------------------------------------------------------------

  describe "a malformed or unknown policy fails closed at request time" do
    test "an unknown field rejects the command and records no intent" do
      fixture = fixture()

      assert {:error, _reason} =
               Handoffs.request(
                 fixture.goal.id,
                 handoff_attrs(fixture, %{
                   "lease_policy" => %{"deadline_secondz" => 600}
                 })
               )

      # A rejected command is not an intent: nothing to deliver, nothing to
      # reconcile, nothing enqueued.
      assert Repo.aggregate(from(j in Job, where: j.queue == "handoff"), :count, :id) == 0
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 0
    end

    test "an unknown reserve field is refused, not dropped" do
      fixture = fixture()

      assert {:error, _reason} =
               Handoffs.request(
                 fixture.goal.id,
                 handoff_attrs(fixture, %{
                   "lease_policy" => %{"reserves" => %{"response" => 1, "tokens" => 5}}
                 })
               )
    end

    test "out-of-range and non-integer bounds are refused" do
      fixture = fixture()

      bad = [
        # below the 60-second floor: a deadline that cannot outlive startup
        %{"deadline_seconds" => 30},
        %{"deadline_seconds" => 14_401},
        %{"deadline_seconds" => 0},
        %{"deadline_seconds" => -1},
        %{"deadline_seconds" => "600"},
        %{"deadline_seconds" => 600.0},
        %{"response_budget" => 0},
        %{"response_budget" => 1_001},
        %{"tool_budget" => 0},
        %{"tool_budget" => 10_001},
        %{"checkpoint_cadence" => 0},
        %{"checkpoint_cadence" => 1_001},
        %{"reserves" => %{"response" => -1}},
        %{"reserves" => "none"},
        %{"reserves" => %{"tool" => "1"}}
      ]

      for policy <- bad do
        assert {:error, _reason} =
                 Handoffs.request(
                   fixture.goal.id,
                   handoff_attrs(fixture, %{"lease_policy" => policy})
                 ),
               "expected #{inspect(policy)} to be refused"
      end

      assert Repo.aggregate(from(j in Job, where: j.queue == "handoff"), :count, :id) == 0
    end

    test "a non-object policy is refused" do
      fixture = fixture()

      for policy <- ["default", 2700, [600]] do
        assert {:error, _reason} =
                 Handoffs.request(
                   fixture.goal.id,
                   handoff_attrs(fixture, %{"lease_policy" => policy})
                 ),
               "expected #{inspect(policy)} to be refused"
      end
    end

    test "a reserve at or above its budget is refused: it would be renewal-due at zero spend" do
      fixture = fixture()

      # `LeaseBounds` fires renewal-due at `responses >= budget - reserve`, so
      # a reserve equal to the budget makes the receiver due before it has
      # produced anything.
      for policy <- [
            %{"response_budget" => 5, "reserves" => %{"response" => 5, "tool" => 1}},
            %{"response_budget" => 5, "reserves" => %{"response" => 6, "tool" => 1}},
            %{"tool_budget" => 4, "reserves" => %{"response" => 1, "tool" => 4}}
          ] do
        assert {:error, _reason} =
                 Handoffs.request(
                   fixture.goal.id,
                   handoff_attrs(fixture, %{"lease_policy" => policy})
                 ),
               "expected #{inspect(policy)} to be refused"
      end

      # One below the budget is the boundary that IS allowed.
      assert {:ok, %{job: job}} =
               Handoffs.request(
                 fixture.goal.id,
                 handoff_attrs(fixture, %{
                   "lease_policy" => %{
                     "response_budget" => 5,
                     "reserves" => %{"response" => 4, "tool" => 1}
                   }
                 })
               )

      assert :ok = perform_delivery(job)
      lease = receiver_lease!(fixture)
      assert lease.response_budget == 5
      assert lease.response_reserve == 4
    end
  end

  # ----------------------------------------------------------------------------
  # Across enqueue, replay and boot
  # ----------------------------------------------------------------------------

  describe "the policy survives delivery, replay and boot repair" do
    test "a replayed delivery re-grants nothing and keeps the original bounds" do
      fixture = fixture()

      {:ok, %{job: job}} =
        Handoffs.request(
          fixture.goal.id,
          handoff_attrs(fixture, %{"lease_policy" => %{"deadline_seconds" => 900}})
        )

      assert :ok = perform_delivery(job)
      lease = receiver_lease!(fixture)

      assert :ok = perform_delivery(job)

      # Exactly one of everything, and the lease is the SAME grant with the
      # SAME bounds — not re-minted, not re-bounded.
      assert length(receiver_runs(fixture)) == 1
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1
      assert length(handoff_events(fixture.goal.id)) == 1

      replayed = receiver_lease!(fixture)
      assert replayed.id == lease.id
      assert replayed.deadline == lease.deadline
      assert DateTime.diff(replayed.deadline, @t0, :second) == 900
    end

    test "a boot-repaired delivery reaches the identical policy" do
      fixture = fixture()

      {:ok, %{handoff_id: handoff_id, job: job}} =
        Handoffs.request(
          fixture.goal.id,
          handoff_attrs(fixture, %{"lease_policy" => %{"deadline_seconds" => 1800}})
        )

      # Lose the delivery attempt, as a crash between the command commit and
      # the Oban insert would.
      Repo.delete!(job)
      assert {:ok, %{repaired_count: 1, failures: []}} = Handoffs.reconcile()

      assert [restored] = Repo.all(from j in Job, where: j.queue == "handoff")
      assert restored.args["handoff_id"] == handoff_id

      # The job carries no bounds of its own: the rebuilt attempt reads the
      # policy off the durable intent, so it cannot drift from it.
      refute Map.has_key?(restored.args, "lease_policy")

      assert :ok = perform_delivery(restored)
      assert DateTime.diff(receiver_lease!(fixture).deadline, @t0, :second) == 1800
    end
  end

  # ----------------------------------------------------------------------------
  # Twins: a policy never lifts a refusal
  # ----------------------------------------------------------------------------

  describe "a lease policy proposes bounds and never lifts a refusal" do
    test "a confirmation-class refusal stays refused, however generous the policy" do
      fixture = fixture()

      Application.put_env(:shoestring, :handoff_observe, fn _scoping ->
        {:ok, degraded_snapshot!()}
      end)

      {:ok, %{job: job}} =
        Handoffs.request(
          fixture.goal.id,
          handoff_attrs(fixture, %{
            "lease_policy" => %{"deadline_seconds" => 14_400, "tool_budget" => 10_000}
          })
        )

      # A recorded refusal is a completed delivery, not a retriable failure.
      assert :ok = perform_delivery(job)

      assert [decision] = decision_events(fixture.goal.id)
      assert decision.payload["result"] == "require_confirmation"
      assert receiver_runs(fixture) == []
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 0
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 0
    end

    test "a hard stop stays a hard stop, however generous the policy" do
      fixture = fixture()

      Application.put_env(:shoestring, :handoff_observe, fn _scoping ->
        {:ok, incompatible_snapshot!()}
      end)

      {:ok, %{job: job}} =
        Handoffs.request(
          fixture.goal.id,
          handoff_attrs(fixture, %{
            "lease_policy" => %{"deadline_seconds" => 14_400},
            "confirmation" => %{"intent" => "supervised_execution"}
          })
        )

      assert :ok = perform_delivery(job)

      assert [decision] = decision_events(fixture.goal.id)
      assert decision.payload["result"] == "reject"
      assert receiver_runs(fixture) == []
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 0
    end

    test "a refused transfer grants no lease at all, so no bounds are proposed durably" do
      fixture = fixture()

      Application.put_env(:shoestring, :handoff_observe, fn _scoping ->
        {:ok, degraded_snapshot!()}
      end)

      {:ok, %{job: job}} =
        Handoffs.request(
          fixture.goal.id,
          handoff_attrs(fixture, %{"lease_policy" => %{"deadline_seconds" => 600}})
        )

      assert :ok = perform_delivery(job)
      assert Repo.all(ExecutionLeaseRecord) == []
    end
  end

  # ----------------------------------------------------------------------------
  # The pure policy module
  # ----------------------------------------------------------------------------

  describe "HandoffLeasePolicy validation is pure and total" do
    test "default/0 is the 2700-second policy" do
      policy = HandoffLeasePolicy.default()

      assert policy.deadline_seconds == 2700
      assert policy.response_budget == 10
      assert policy.tool_budget == 25
      assert policy.checkpoint_cadence == 1
      assert policy.reserves == %{response: 1, tool: 1}
    end

    test "from_intent/1 defaults an absent policy and errors on a malformed one" do
      assert {:ok, default} = HandoffLeasePolicy.from_intent(%{})
      assert default.deadline_seconds == 2700

      assert {:ok, explicit} =
               HandoffLeasePolicy.from_intent(%{"lease_policy" => %{"deadline_seconds" => 120}})

      assert explicit.deadline_seconds == 120

      # A durable policy that no longer validates is an ERROR, never a silent
      # fall back: the stored intent and this code disagree, and granting a
      # lease on a guess is how a receiver executes under bounds nobody
      # authorized.
      assert {:error, {:invalid_handoff_lease_policy, _}} =
               HandoffLeasePolicy.from_intent(%{"lease_policy" => %{"deadline_seconds" => 1}})

      assert {:error, {:invalid_handoff_lease_policy, _}} =
               HandoffLeasePolicy.from_intent(%{"lease_policy" => "600"})
    end

    test "a malformed durable policy is a permanent error, not an endless retry" do
      # It will not start validating on the next attempt, so the worker
      # cancels rather than burning five deliveries on it.
      assert Handoffs.permanent_error?({:invalid_handoff_lease_policy, %{}})
    end

    test "to_admission_policy/2 replaces only the lease bounds" do
      base = Shoestring.Cobbler.AdmissionPolicy.default()

      {:ok, policy} =
        HandoffLeasePolicy.new(%{"deadline_seconds" => 600, "response_budget" => 3})

      merged = HandoffLeasePolicy.to_admission_policy(policy, base)

      assert merged.deadline_seconds == 600
      assert merged.response_budget == 3

      # Admission strictness is untouched: a longer lease is not a licence to
      # admit on an older reading or a lower reserve.
      assert merged.stale_after_seconds == base.stale_after_seconds
      assert merged.five_hour_reserve_percent == base.five_hour_reserve_percent
      assert merged.weekly_reserve_percent == base.weekly_reserve_percent
      assert merged.five_hour_max_used_percent == base.five_hour_max_used_percent
      assert merged.weekly_max_used_percent == base.weekly_max_used_percent
      assert merged.supported_capabilities == base.supported_capabilities
      assert merged.delayed_recheck_seconds == base.delayed_recheck_seconds
    end

    test "the allow-list names exactly the bound fields" do
      assert Enum.sort(HandoffLeasePolicy.policy_keys()) ==
               Enum.sort(~w(
                 deadline_seconds
                 response_budget
                 tool_budget
                 checkpoint_cadence
                 reserves
               ))
    end
  end

  # ----------------------------------------------------------------------------
  # Fixture
  # ----------------------------------------------------------------------------

  defp fixture do
    goal = FakeHelpers.insert_goal(Ecto.UUID.generate())
    task = FakeHelpers.insert_task(goal, Ecto.UUID.generate())

    run =
      FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate()
      )

    run =
      Repo.update!(
        Ecto.Changeset.change(run,
          provider_id: @sender_provider,
          prompt: "implement the widget",
          status: "suspended",
          requested_capabilities: %{"items" => ["resume", "cancel"]}
        )
      )

    checkpoint_id = Ecto.UUID.generate()
    decision = admission_payload(provider_id: "codex", adapter_id: "codex_app_server")
    admission = append_admission_event!(goal.id, decision)

    {:ok, %{command: claim}} = Commands.submit(goal.id, claim_command(admission))
    assert claim.status == "resolved"

    {:ok, _} =
      Trajectory.append(
        goal.id,
        %{
          "type" => "checkpoint.created",
          "schema_version" => 1,
          "actor" => "harness",
          "occurred_at" => @t0,
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
            "next_action" => "advance to step seven",
            "provider_session_id" => "codex-session-sender",
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
      run: Repo.get!(RunRecord, run.id),
      checkpoint_id: checkpoint_id,
      decision_id: decision["decision_id"]
    }
  end

  defp handoff_attrs(fixture, payload_overrides \\ %{}) do
    %{
      "command_id" => "cmd-handoff-" <> Ecto.UUID.generate(),
      "payload" =>
        Map.merge(
          %{
            "run_id" => fixture.run.id,
            "checkpoint_id" => fixture.checkpoint_id,
            "decision_refs" => [fixture.decision_id],
            "to_provider_id" => @receiver_provider,
            "to_adapter_id" => @receiver_adapter,
            "scope" => @receiver_scope,
            "reason" => "sender quota exhausted",
            "requested_by" => "user:operator-1"
          },
          payload_overrides
        )
    }
  end

  defp receiver_lease!(fixture) do
    [receiver] = receiver_runs(fixture)
    Repo.get_by!(ExecutionLeaseRecord, run_id: receiver.id)
  end

  defp receiver_runs(fixture) do
    sender_id = fixture.run.id
    goal_id = fixture.goal.id

    Repo.all(
      from run in RunRecord,
        where: run.goal_id == ^goal_id and run.id != ^sender_id,
        order_by: [asc: run.inserted_at, asc: run.id]
    )
  end

  defp handoff_events(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == "handoff.created",
        order_by: [asc: event.sequence]
    )
  end

  defp decision_events(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == "admission.decided" and
            like(event.idempotency_key, "handoff-decision:%"),
        order_by: [asc: event.sequence]
    )
  end

  # ----------------------------------------------------------------------------
  # Snapshots
  # ----------------------------------------------------------------------------

  defp eligible_snapshot!, do: snapshot!(:observed, :compatible, :high, nil)

  defp degraded_snapshot!,
    do: snapshot!(:degraded, :degraded, :medium, "receiver adapter surface is degraded")

  defp incompatible_snapshot!,
    do:
      snapshot!(
        :degraded,
        :incompatible,
        :medium,
        "receiver CLI version is incompatible with this adapter"
      )

  defp snapshot!(capacity_state, compatibility_state, confidence, reason) do
    reset_at = DateTime.add(@t0, 7_200, :second)

    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: capacity_state,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: 10.0, reset_at: reset_at},
            %{kind: "weekly", state: :observed, used_percent: 12.0, reset_at: reset_at}
          ],
          observed_at: @t0,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @receiver_adapter,
            provider_id: @receiver_provider,
            invocation_mode: "headless",
            event: :explicit_read
          },
          scope: @receiver_scope,
          confidence: confidence,
          support_tier: :proactive,
          compatibility_state: compatibility_state,
          reason: reason,
          extensions: %{}
        },
        now: @t0
      )

    snapshot
  end

  defp perform_delivery(%Job{} = job) do
    job
    |> Map.put(:attempted_at, @t0)
    |> Map.put(:scheduled_at, @t0)
    |> perform_job()
  end

  defp restore(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore(key, value), do: Application.put_env(:shoestring, key, value)
end
