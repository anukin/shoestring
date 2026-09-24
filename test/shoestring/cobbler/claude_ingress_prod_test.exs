defmodule Shoestring.Cobbler.ClaudeIngressProdTest do
  @moduledoc """
  How a Claude reading reaches the production handoff probe, end to end.

  The deployed node observes a handoff receiver only through the Observatory
  ledger (`:handoff_observe` = `{WakeupObserve, :observe, []}` in
  `config/runtime.exs`). Nothing writes a Claude reading there except
  `ClaudeMonitor`, and at base it only ingests on a statusLine callback that no
  route delivers. So every production handoff to Claude failed with
  `{:observation_failed, :no_observation_for_provider}` and could never succeed
  (`live-production-rerun.md` §3.1).

  The chosen integration is the smallest supported one: the monitor's
  existing `auto_ingest_initial` option, turned on in `config/config.exs`. It
  ingests the monitor's honest pre-first-response reading — `unknown`,
  `conservative_partial`, no windows, no `observed_at`, confidence `:none` —
  which admission turns into `require_confirmation`. These tests pin both
  halves: the reading now arrives, and it never admits on its own.

  The monitor is started through `Capacity.Supervisor.claude_child_spec/1`
  with the `:prod` entry read from the config files themselves
  (`Config.Reader`), a stub version runner (never the `claude` CLI), and the
  real Observatory sink. Delivery goes through `HandoffWorker.perform/1`.

  LOCK tests fail on base for the behavioural reason (no Claude reading in
  the ledger → `:no_observation` / `:no_observation_for_provider`). DOC tests
  pass on base: they pin the fail-closed rules the new reading must not
  loosen.

  Hermetic: Oban `testing: :manual` (the receiver's `dispatch` job is inserted,
  never performed), no provider CLI, no network.
  """
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Commands, Handoffs, WakeupObserve}

  alias Shoestring.Harness.{
    CapacitySnapshot,
    DispatchRecord,
    ExecutionLeaseRecord,
    Observatory,
    Projector,
    RunRecord
  }

  alias Shoestring.Harness.Capacity.{ClaudeMonitor, Supervisor}
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @t0 Shoestring.Test.FixedClock.now()
  @prod_observe {WakeupObserve, :observe, []}
  @receiver %{provider: "claude", adapter: "claude_headless_stream_json", scope: "subscription"}

  setup do
    previous = %{
      observe: Application.get_env(:shoestring, :handoff_observe),
      clock: Application.get_env(:shoestring, :dispatch_clock)
    }

    Application.put_env(:shoestring, :dispatch_clock, Shoestring.Test.FixedClock)
    Application.put_env(:shoestring, :handoff_observe, @prod_observe)

    on_exit(fn ->
      restore(:handoff_observe, previous.observe)
      restore(:dispatch_clock, previous.clock)
    end)

    :ok
  end

  describe "the production monitor configuration" do
    test "LOCK: :prod enables the Claude monitor with auto_ingest_initial" do
      assert Keyword.get(prod_claude_opts(), :enabled) == true
      assert Keyword.get(prod_claude_opts(), :auto_ingest_initial) == true
    end

    test "LOCK: booted with that entry, the ledger holds Claude's honest unknown reading" do
      start_prod_claude_monitor!()

      assert {:ok, %CapacitySnapshot{} = snapshot} =
               WakeupObserve.observe(%{provider_id: "claude", scope: "subscription"})

      # Never invented capacity: no windows, no observation time, no confidence.
      assert snapshot.capacity_state == :unknown
      assert snapshot.support_tier == :conservative_partial
      assert snapshot.confidence == :none
      assert snapshot.windows == []
      assert snapshot.observed_at == nil
      assert snapshot.source.provider_id == "claude"
      assert snapshot.reason =~ "rate_limits_absent_before_first_response"
    end

    test "DOC: the test environment still never auto-starts the monitor" do
      configured = Application.get_env(:shoestring, :capacity_monitors)
      assert Keyword.get(configured[:claude], :enabled) == false
      assert Supervisor.claude_child_spec([]) == nil
    end
  end

  describe "a production handoff to Claude on that reading" do
    test "LOCK: without a confirmation it is refused as unknown capacity — never auto-approved" do
      start_prod_claude_monitor!()
      fixture = fixture()

      {:ok, %{job: job}} = Handoffs.request(fixture.goal.id, handoff_attrs(fixture))
      assert :ok = perform_delivery(job)

      assert [decision] = decision_events(fixture.goal.id)
      assert decision.payload["result"] == "require_confirmation"
      # The conservative-partial tier is judged first; the reading is also
      # unknown. Either is confirmation-class, never an admit.
      assert decision.payload["reason_code"] == "support_tier_conservative_partial"
      assert decision.payload["observation"]["confidence"] == "none"
      assert receiver_runs(fixture) == []
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 0
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 0
    end

    test "LOCK: with the owner-bound confirmation it is admitted, leased and dispatched" do
      start_prod_claude_monitor!()
      fixture = fixture()

      {:ok, %{handoff_id: handoff_id, job: job, command: command}} =
        Handoffs.request(
          fixture.goal.id,
          handoff_attrs(fixture, %{"confirmation" => %{"intent" => "supervised_execution"}})
        )

      # Attribution comes from the goal's durable owner, not the request.
      assert command.result["confirmation"]["confirmed_by"] == "owner:" <> fixture.goal.owner_id

      assert :ok = perform_delivery(job)

      assert [decision] = decision_events(fixture.goal.id)
      assert decision.payload["result"] == "admit"
      assert decision.payload["observation"]["confidence"] == "none"

      [receiver] = receiver_runs(fixture)
      assert receiver.provider_id == @receiver.adapter
      assert receiver.dispatch_id == handoff_id

      lease = Repo.get_by!(ExecutionLeaseRecord, run_id: receiver.id)
      assert lease.goal_id == fixture.goal.id
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1

      assert Repo.aggregate(from(j in Job, where: j.queue == "dispatch"), :count, :id) == 1
      assert {:ok, _} = Projector.project(fixture.goal.id)
    end

    test "DOC: a refused Claude reading defers even with a confirmation (quota fails closed)" do
      start_prod_claude_monitor!()
      {:ok, :persisted, _} = Observatory.ingest(refused_claude_snapshot!(), now: @t0)
      fixture = fixture()

      {:ok, %{job: job}} =
        Handoffs.request(
          fixture.goal.id,
          handoff_attrs(fixture, %{"confirmation" => %{"intent" => "supervised_execution"}})
        )

      assert :ok = perform_delivery(job)

      assert [decision] = decision_events(fixture.goal.id)
      assert decision.payload["result"] == "defer_until"
      assert receiver_runs(fixture) == []
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 0
    end

    test "DOC: a confirmation for another capability does not answer the refusal" do
      start_prod_claude_monitor!()
      fixture = fixture()

      {:ok, %{job: job}} =
        Handoffs.request(
          fixture.goal.id,
          handoff_attrs(fixture, %{"confirmation" => %{"intent" => "read_only"}})
        )

      _ = perform_delivery(job)

      assert receiver_runs(fixture) == []
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 0
    end
  end

  # ----------------------------------------------------------------------------
  # Monitor
  # ----------------------------------------------------------------------------

  # The `:prod` entry exactly as the config files resolve it.
  defp prod_claude_opts do
    Path.join([File.cwd!(), "config", "config.exs"])
    |> Config.Reader.read!(env: :prod, target: :host)
    |> get_in([:shoestring, :capacity_monitors, :claude])
  end

  defp start_prod_claude_monitor! do
    test_pid = self()

    # Version discovery is the one command the monitor may run; it is stubbed.
    runner = fn cmd, args, _opts ->
      send(test_pid, {:cli_invoked, cmd, args})
      {"2.1.281 (Claude Code)", 0}
    end

    spec =
      Supervisor.claude_child_spec(
        claude: Keyword.merge(prod_claude_opts(), name: nil, runner: runner, clock: fn -> @t0 end)
      )

    pid = start_supervised!(spec)
    # Discovery and the deferred initial ingest run in `handle_continue/2`.
    _ = :sys.get_state(pid)
    assert_received {:cli_invoked, "claude", ["--version"]}
    assert ClaudeMonitor.status(pid).sink_status == :ok
    pid
  end

  defp refused_claude_snapshot! do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :refused,
          windows: [
            %{kind: "five_hour", state: :unknown, reason: "quota refused by provider"},
            %{kind: "weekly", state: :unknown, reason: "quota refused by provider"}
          ],
          observed_at: @t0,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "claude_interactive_status_line",
            provider_id: "claude",
            invocation_mode: "interactive_status_line",
            event: :status_line_input
          },
          scope: @receiver.scope,
          confidence: :low,
          support_tier: :conservative_partial,
          compatibility_state: :degraded,
          reason: "quota refused by provider",
          extensions: %{}
        },
        now: @t0
      )

    snapshot
  end

  # ----------------------------------------------------------------------------
  # Sender fixture: a finished Codex run with its canonical checkpoint
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
          provider_id: "codex_app_server_stdio",
          prompt: "build the Go Tic-Tac-Toe CLI",
          status: "completed",
          requested_capabilities: %{"items" => ["cancel"]}
        )
      )

    decision = admission_payload(provider_id: "codex", adapter_id: "codex_app_server")
    admission = append_admission_event!(goal.id, decision)
    {:ok, %{command: claim}} = Commands.submit(goal.id, claim_command(admission))
    assert claim.status == "resolved"

    checkpoint_id = Ecto.UUID.generate()

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
            "acceptance_contract" => %{"criteria" => ["go test ./... passes"]},
            "repository_state" => %{"revision" => "abc123", "dirty" => false},
            "evidence" => %{"items" => []},
            "decisions" => %{"items" => []},
            "unresolved_issues" => %{"items" => []},
            "next_action" => "finish the CLI game loop",
            "provider_session_id" => "codex-session-sender",
            "stop_reason" => "completed",
            "artifact_ids" => %{"items" => []},
            "extensions" => %{}
          }
        },
        trusted: [run_id: run.id]
      )

    {:ok, _} = Projector.project(goal.id)

    %{goal: goal, run: run, checkpoint_id: checkpoint_id, decision_id: decision["decision_id"]}
  end

  defp handoff_attrs(fixture, overrides \\ %{}) do
    %{
      "command_id" => "cmd-claude-handoff-" <> Ecto.UUID.generate(),
      "payload" =>
        Map.merge(
          %{
            "run_id" => fixture.run.id,
            "checkpoint_id" => fixture.checkpoint_id,
            "decision_refs" => [fixture.decision_id],
            "to_provider_id" => @receiver.provider,
            "to_adapter_id" => @receiver.adapter,
            "scope" => @receiver.scope,
            "reason" => "continue on Claude",
            "requested_by" => "operator"
          },
          overrides
        )
    }
  end

  defp receiver_runs(fixture) do
    sender_id = fixture.run.id
    goal_id = fixture.goal.id

    Repo.all(from run in RunRecord, where: run.goal_id == ^goal_id and run.id != ^sender_id)
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

  defp perform_delivery(%Job{} = job) do
    job
    |> Map.put(:attempted_at, @t0)
    |> Map.put(:scheduled_at, @t0)
    |> perform_job()
  end

  defp restore(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore(key, value), do: Application.put_env(:shoestring, key, value)
end
