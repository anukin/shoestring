defmodule Shoestring.Cobbler.HandoffConfirmationTest do
  @moduledoc """
  The operator's attributable confirmation travels on the durable
  `run.handoff` intent, so a confirmation-class receiver refusal is
  answerable through the PRODUCTION delivery path.

  Hermetic: `Fake` sender, injected snapshots, no provider CLI, no network,
  no Elf, no quota. The receiver dispatch is asserted as a persisted row and
  a queued delivery attempt; it is never executed here.

  ## Why this exists

  `Shoestring.Cobbler.Handoffs.perform/3` reads the operator's confirmation
  from `opts[:override]`. `Shoestring.Cobbler.HandoffWorker` — the only thing
  that consumes a handoff intent in production — passes no such option and
  has no channel for one. Any receiver whose measured capacity is less than
  automatically safe therefore produced `require_confirmation` forever, no
  matter what the operator decided, and the transfer was unreachable.

  That is not a hypothetical class. The production Claude capacity source
  (`Shoestring.Harness.Capacity.ClaudeMonitor`) is passive by design and
  declares `support_tier: :conservative_partial` unconditionally
  (`claude_monitor.ex`, `support_tier/0`), so EVERY Claude receiver lands in
  it. Observed live: see
  `plans/evidence/05-quota-aware-mvp/live-cross-provider-handoff.md`.

  ## Lock-vs-documentation ledger

  Measured against base `6f1653fed931d120d463676ec40e95e6b8ad7327`.

  **TRUE behavioural locks** (base reaches the same surface and does the
  wrong thing there — it silently drops the `confirmation` key from the
  payload rather than rejecting it, so the operator's decision is accepted
  and then ignored):

    * `"the production worker admits a confirmation-class receiver when the
      intent carries an attributable confirmation"` — base refuses with
      `require_confirmation` and writes no `handoff.created`.
    * `"an unattributed confirmation is rejected at request time"` — base
      records the intent as `resolved`.
    * `"a confirmation naming a different provider is rejected at request
      time"` / `"... a different scope ..."` — base records both as
      `resolved`.
    * `"re-submitting the same command id with a different confirmation is a
      conflict"` — base computes the same digest for both, so the second
      submission replays instead of conflicting.

  **DOCUMENTATION, not locks** (these pass on base too; they are the
  both-directions controls that keep the fix from being fail-open):

    * `"without a confirmation the same intent is refused, and leaves no
      effect behind"` — the control the locks are measured against.
    * `"a confirmation never lifts a hard stop"` — base also refuses, for the
      different reason that it has no confirmation at all.
    * `"an explicit :override option still wins over the intent"` — the
      in-process path base already had.

  The exact base output for each is recorded in
  `plans/evidence/05-quota-aware-mvp/live-cross-provider-handoff.md`.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Commands, HandoffWorker}

  alias Shoestring.Harness.{
    CapacitySnapshot,
    DispatchRecord,
    ExecutionLeaseRecord,
    Projector,
    RunRecord
  }

  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @t0 ~U[2026-09-21 12:00:00.000000Z]

  @sender_provider "shoestring.harness.fake"
  @receiver_provider "claude"
  @receiver_adapter "claude_headless_stream_json"
  @receiver_scope "subscription"

  @confirmed_by "user:operator-live"

  setup do
    previous = Application.get_env(:shoestring, :handoff_observe)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:shoestring, :handoff_observe)
        value -> Application.put_env(:shoestring, :handoff_observe, value)
      end
    end)

    :ok
  end

  # ----------------------------------------------------------------------------
  # The lock
  # ----------------------------------------------------------------------------

  describe "an attributable confirmation on the durable intent" do
    test "the production worker admits a confirmation-class receiver when the intent carries one" do
      fixture = fixture()
      observe!(conservative_partial_snapshot!())

      {:ok, handoff_id} = request!(fixture, confirmation: confirmation())

      assert :ok = HandoffWorker.perform(job!(handoff_id))

      # The transfer happened: pointer, receiver run, receiver lease, one
      # durable dispatch.
      assert [pointer] = events(fixture.goal.id, "handoff.created")
      assert pointer.payload["to_provider_id"] == @receiver_provider
      assert pointer.payload["prior_run_id"] == fixture.run.id

      receiver = Repo.get!(RunRecord, pointer.payload["run_id"])
      assert receiver.provider_id == @receiver_adapter
      refute receiver.id == fixture.run.id

      assert %ExecutionLeaseRecord{} = Repo.get_by(ExecutionLeaseRecord, run_id: receiver.id)
      assert [dispatch] = Repo.all(DispatchRecord)
      assert dispatch.run_id == receiver.id

      # And it happened as an ATTRIBUTED confirmation, not as an automatic
      # admit: the persisted decision names who confirmed and says the
      # admission was not automatically safe.
      assert [decision] = handoff_decisions(fixture.goal.id)
      assert decision.payload["result"] == "admit"
      assert decision.payload["reason_code"] == "confirmed_support_tier_conservative_partial"
      assert decision.payload["override"]["confirmed_by"] == @confirmed_by
      assert decision.payload["override"]["valid"] == true
      assert decision.payload["override"]["target_provider_id"] == @receiver_provider
      assert decision.payload["override"]["target_scope"] == @receiver_scope
    end

    test "without a confirmation the same intent is refused, and leaves no effect behind" do
      fixture = fixture()
      observe!(conservative_partial_snapshot!())

      {:ok, handoff_id} = request!(fixture)

      # A recorded refusal is a successful production outcome, so the worker
      # reports :ok and settles rather than retrying behind the operator.
      assert :ok = HandoffWorker.perform(job!(handoff_id))

      assert [decision] = handoff_decisions(fixture.goal.id)
      assert decision.payload["result"] == "require_confirmation"
      assert decision.payload["reason_code"] == "support_tier_conservative_partial"

      assert events(fixture.goal.id, "handoff.created") == []
      assert run_ids(fixture.goal.id) == [fixture.run.id]
      assert Repo.all(DispatchRecord) == []
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 0
    end

    test "a confirmation never lifts a hard stop" do
      fixture = fixture()
      observe!(incompatible_snapshot!())

      {:ok, handoff_id} = request!(fixture, confirmation: confirmation())

      assert :ok = HandoffWorker.perform(job!(handoff_id))

      assert [decision] = handoff_decisions(fixture.goal.id)
      refute decision.payload["result"] == "admit"

      assert events(fixture.goal.id, "handoff.created") == []
      assert Repo.all(DispatchRecord) == []
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 0
    end
  end

  # ----------------------------------------------------------------------------
  # Fail-closed at request time
  # ----------------------------------------------------------------------------

  describe "the confirmation is validated where the intent is recorded" do
    test "an unattributed confirmation is rejected at request time" do
      fixture = fixture()

      assert {:error, changeset} =
               submit(fixture, confirmation: %{"intent" => "supervised_execution"})

      assert %{confirmed_by: ["can't be blank"]} = errors_on(changeset)
      assert command_rows(fixture.goal.id) == []
    end

    test "a confirmation naming a different provider is rejected at request time" do
      fixture = fixture()

      assert {:error, changeset} =
               submit(fixture,
                 confirmation: %{
                   "confirmed_by" => @confirmed_by,
                   "target_provider_id" => "some-other-provider"
                 }
               )

      assert %{target_provider_id: ["must match the handoff receiver"]} = errors_on(changeset)
      assert command_rows(fixture.goal.id) == []
    end

    test "a confirmation naming a different scope is rejected at request time" do
      fixture = fixture()

      assert {:error, changeset} =
               submit(fixture,
                 confirmation: %{
                   "confirmed_by" => @confirmed_by,
                   "target_scope" => "account:someone-else"
                 }
               )

      assert %{target_scope: ["must match the handoff receiver"]} = errors_on(changeset)
      assert command_rows(fixture.goal.id) == []
    end

    test "re-submitting the same command id with a different confirmation is a conflict" do
      fixture = fixture()
      command_id = "cmd-handoff-" <> Ecto.UUID.generate()

      assert {:ok, %{command: first}} =
               submit(fixture, command_id: command_id, confirmation: confirmation())

      assert first.status == "resolved"

      assert {:error, {:command_conflict, detail}} =
               submit(fixture,
                 command_id: command_id,
                 confirmation: confirmation(confirmed_by: "user:someone-else")
               )

      assert detail["command_id"] == command_id
    end

    test "an intent with no confirmation keeps the payload it always had" do
      fixture = fixture()

      assert {:ok, %{command: command}} = submit(fixture)
      refute Map.has_key?(command.payload, "confirmation")
      refute Map.has_key?(command.result, "confirmation")
    end
  end

  # ----------------------------------------------------------------------------
  # Precedence
  # ----------------------------------------------------------------------------

  describe "precedence" do
    test "an explicit :override option still wins over the intent" do
      fixture = fixture()
      snapshot = conservative_partial_snapshot!()
      observe!(snapshot)

      {:ok, _handoff_id} = request!(fixture, confirmation: confirmation())

      command_id = command_id_of(fixture.goal.id)

      assert {:ok, %{outcome: :dispatched}} =
               Shoestring.Cobbler.Handoffs.perform(fixture.goal.id, command_id,
                 observe: fn _scoping -> {:ok, snapshot} end,
                 override: confirmation(confirmed_by: "user:option-wins")
               )

      assert [decision] = handoff_decisions(fixture.goal.id)
      assert decision.payload["override"]["confirmed_by"] == "user:option-wins"
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
          status: "completed",
          requested_capabilities: %{"items" => ["resume", "cancel"]}
        )
      )

    decision = admission_payload(provider_id: @sender_provider, adapter_id: @sender_provider)
    admission = append_admission_event!(goal.id, decision)

    {:ok, %{command: claim}} = Commands.submit(goal.id, claim_command(admission))
    assert claim.status == "resolved"

    checkpoint_id = Ecto.UUID.generate()
    append_checkpoint!(goal, run, checkpoint_id)
    {:ok, _} = Projector.project(goal.id)

    %{goal: goal, task: task, run: Repo.get!(RunRecord, run.id), checkpoint_id: checkpoint_id}
  end

  defp append_checkpoint!(goal, run, checkpoint_id) do
    {:ok, event} =
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
            "acceptance_contract" => %{"criteria" => ["the CLI plays a full game"]},
            "repository_state" => %{"revision" => "abc123", "dirty" => true},
            "evidence" => %{"items" => ["package tests pass"]},
            "decisions" => %{"items" => ["core package first, CLI second"]},
            "unresolved_issues" => %{"items" => ["no CLI entry point yet"]},
            "next_action" => "add the CLI entry point and make the suite pass",
            "provider_session_id" => nil,
            "stop_reason" => "handoff_boundary",
            "artifact_ids" => %{"items" => []},
            "extensions" => %{}
          }
        },
        trusted: [run_id: run.id]
      )

    event
  end

  defp confirmation(opts \\ []) do
    %{
      "confirmed_by" => Keyword.get(opts, :confirmed_by, @confirmed_by),
      "intent" => "supervised_execution",
      "target_provider_id" => @receiver_provider,
      "target_scope" => @receiver_scope
    }
  end

  defp submit(fixture, opts \\ []) do
    payload = %{
      "run_id" => fixture.run.id,
      "checkpoint_id" => fixture.checkpoint_id,
      "decision_refs" => decision_refs(fixture.goal.id),
      "to_provider_id" => @receiver_provider,
      "to_adapter_id" => @receiver_adapter,
      "scope" => @receiver_scope,
      "reason" => "sender leg complete at the named boundary",
      "requested_by" => "user:operator-live"
    }

    payload =
      case Keyword.get(opts, :confirmation) do
        nil -> payload
        confirmation -> Map.put(payload, "confirmation", confirmation)
      end

    attrs = %{
      "command_id" =>
        Keyword.get_lazy(opts, :command_id, fn -> "cmd-" <> Ecto.UUID.generate() end),
      "payload" => payload
    }

    Shoestring.Cobbler.Handoffs.request(fixture.goal.id, attrs)
  end

  defp request!(fixture, opts \\ []) do
    assert {:ok, %{handoff_id: handoff_id, command: command}} = submit(fixture, opts)
    assert command.status == "resolved"
    {:ok, handoff_id}
  end

  # The production delivery attempt, taken from the row the request wrote.
  defp job!(handoff_id) do
    Repo.one!(
      from job in Job,
        where:
          job.queue == "handoff" and
            fragment("json_extract(?, '$.handoff_id')", job.args) == ^handoff_id
    )
  end

  # The worker's ONLY observation channel.
  defp observe!(snapshot) do
    Application.put_env(:shoestring, :handoff_observe, fn _scoping -> {:ok, snapshot} end)
  end

  defp decision_refs(goal_id), do: Shoestring.Harness.Continuation.decision_refs(Repo, goal_id)

  defp command_id_of(goal_id) do
    Repo.one!(
      from command in Shoestring.Cobbler.CommandRecord,
        where: command.goal_id == ^goal_id and command.type == "run.handoff",
        select: command.command_id
    )
  end

  defp command_rows(goal_id) do
    Repo.all(
      from command in Shoestring.Cobbler.CommandRecord,
        where: command.goal_id == ^goal_id and command.type == "run.handoff"
    )
  end

  defp events(goal_id, type) do
    Repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == ^type,
        order_by: [asc: event.sequence]
    )
  end

  defp handoff_decisions(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == "admission.decided" and
            like(event.idempotency_key, "handoff-decision:%"),
        order_by: [asc: event.sequence]
    )
  end

  defp run_ids(goal_id) do
    Repo.all(from run in RunRecord, where: run.goal_id == ^goal_id, select: run.id)
  end

  # The receiver observation shape the real passive Claude source produces:
  # `conservative_partial` support, which is confirmation-class rather than a
  # hard stop.
  defp conservative_partial_snapshot! do
    snapshot!(
      capacity_state: :unknown,
      windows: [],
      support_tier: :conservative_partial,
      compatibility_state: :degraded,
      confidence: :none,
      reason: "rate limits absent before the first response"
    )
  end

  defp incompatible_snapshot! do
    now = DateTime.utc_now()

    snapshot!(
      capacity_state: :degraded,
      windows: [
        %{
          kind: "five_hour",
          state: :observed,
          used_percent: 10.0,
          reset_at: DateTime.add(now, 7_200, :second)
        }
      ],
      support_tier: :conservative_partial,
      compatibility_state: :incompatible,
      confidence: :medium,
      reason: "receiver CLI version is incompatible with this adapter"
    )
  end

  # `observed_at` is real `now`: the production worker judges freshness with
  # `SystemClock`, so a fixed past timestamp would be refused as stale and
  # the test would measure the wrong refusal.
  defp snapshot!(opts) do
    now = DateTime.utc_now()

    attrs = %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: Keyword.fetch!(opts, :capacity_state),
      windows: Keyword.fetch!(opts, :windows),
      observed_at: now,
      freshness: %{max_age_seconds: 300},
      source: %{
        adapter_id: "claude_interactive_status_line",
        provider_id: @receiver_provider,
        invocation_mode: "interactive_status_line",
        event: :status_line_input
      },
      scope: @receiver_scope,
      confidence: Keyword.fetch!(opts, :confidence),
      support_tier: Keyword.fetch!(opts, :support_tier),
      compatibility_state: Keyword.fetch!(opts, :compatibility_state),
      reason: Keyword.fetch!(opts, :reason),
      extensions: %{}
    }

    {:ok, snapshot} = CapacitySnapshot.new(attrs, now: now)
    snapshot
  end
end
