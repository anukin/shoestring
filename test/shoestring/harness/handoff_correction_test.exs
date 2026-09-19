defmodule Shoestring.Harness.HandoffCorrectionTest do
  @moduledoc """
  What `Shoestring.Elves.resume_run/2` does, and no longer does.

  Same-provider resume is unchanged and still covered here: prior-session
  reconcile, the session-mismatch refusal before any adapter call, and the
  precise `:resume_unsupported_for_provider` error for an adapter without
  `resume/3` (Claude).

  Cross-provider handoff is refused. It used to be performed inline from this
  function — bare receiver row, `handoff.created`, `adapter.start/2` — with
  no receiver capacity observation, no admission decision, no lease of its
  own, and outside the durable dispatch pipeline. That was a public,
  unsupervised way to start a provider session, so it was removed rather than
  gated behind a flag. The production path is
  `Shoestring.Cobbler.Handoffs.request/3` + `HandoffWorker`, covered by
  `Shoestring.Cobbler.HandoffProductionTest` and
  `Shoestring.Cobbler.HandoffWorkerTest`, which is where the properties the
  deleted tests asserted (fresh session, transcript-free projection, replay
  convergence) now live — against the pipeline that actually supervises the
  receiver.

  ## Lock-vs-documentation ledger

  TRUE behavioural locks against the PR's own prior head `335b56a`: both
  tests in the `"cross-provider handoff is refused by this API"` group. At
  that head the same calls returned `{:ok, %{handoff_id: ..., run: ...}}`
  and started a Fake session, so they fail there on the success tuple — the
  bypass itself, not a missing name.

  DOCUMENTATION: the same-provider group and the Claude resume test. They
  pass at both heads and pin behaviour this change must not disturb.

  Hermetic: Fake adapter and `RequestLog` only; no provider CLI, no network.
  """

  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Harness.{Continuation, Fake, RunRequest}
  alias Shoestring.Harness.CodexAppServer.Session
  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Repo
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  import Ecto.Query

  @sender_session "fake-session-sender-ALPHA7"
  @original_marker "ORIGINAL-TRANSCRIPT-ALPHA7"
  @next_action_marker "NEXTACTION-BRAVO7"

  defmodule ResumeCaptureTransport do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def send_frame(pid, frame), do: GenServer.call(pid, {:send_frame, frame})
    def os_pid(_pid), do: 99_991

    @impl GenServer
    def init(opts) do
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), owner: nil}}
    end

    @impl GenServer
    def handle_call({:send_frame, frame}, _from, state) do
      map = if is_binary(frame), do: Jason.decode!(frame), else: frame
      {:reply, :ok, handle_frame(map, state)}
    end

    defp handle_frame(%{"method" => "initialize", "id" => id}, state) do
      reply(state, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{"userAgent" => "codex-test/0.0.0"}
      })

      state
    end

    defp handle_frame(%{"method" => "initialized"}, state), do: state

    defp handle_frame(%{"method" => "thread/resume", "id" => id, "params" => params}, state) do
      thread_id = params["threadId"] || "thread-test-resume"

      reply(state, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{"thread" => %{"id" => thread_id}}
      })

      state
    end

    defp handle_frame(%{"method" => "turn/start", "id" => id, "params" => params}, state) do
      send(state.test_pid, {:captured_turn_input, params["input"]})

      reply(state, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{"turn" => %{"id" => "turn-test-1", "status" => "inProgress"}}
      })

      state
    end

    defp handle_frame(_frame, state), do: state

    defp reply(%{owner: nil}, _resp), do: :ok

    defp reply(%{owner: owner}, resp) do
      send(owner, {:codex_transport_frame, self(), Jason.encode!(resp)})
    end
  end

  describe "cross-provider handoff is refused by this API (B2)" do
    test "refused with a pointer to the production path; no run, no event, no adapter call" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      runs_before = run_count()

      assert {:error, {:handoff_requires_cobbler_command, detail}} =
               Elves.resume_run(fixture.run.id,
                 adapter: Fake,
                 adapter_opts: adapter_opts(log, Scenario.handoff_target()),
                 continuation: fixture.presented,
                 provider_session_id: @sender_session,
                 to_provider_id: "fake-harness-b",
                 reason: "quota handoff"
               )

      assert detail["from_provider_id"] == fixture.run.provider_id
      assert detail["to_provider_id"] == "fake-harness-b"
      assert detail["use"] == "Shoestring.Cobbler.Handoffs.request/3"

      assert RequestLog.count(log) == 0
      assert run_count() == runs_before

      refute Repo.exists?(
               from event in TrajectoryEvent,
                 where: event.goal_id == ^fixture.goal.id and event.type == "handoff.created"
             )
    end

    test "no option re-opens it: the refusal is not gated behind a flag" do
      # The bypass was removed rather than gated, so there is nothing to pass.
      # These are the options the old unsupervised path accepted; none of them
      # brings it back.
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()

      for extra <- [
            [handoff_id: Ecto.UUID.generate()],
            [new_run_id: Ecto.UUID.generate(), new_dispatch_id: Ecto.UUID.generate()],
            [goal_state: :working],
            [require_cobbler_command: false]
          ] do
        opts =
          [
            adapter: Fake,
            adapter_opts: adapter_opts(log, Scenario.handoff_target()),
            continuation: fixture.presented,
            provider_session_id: @sender_session,
            to_provider_id: "fake-harness-b"
          ] ++ extra

        assert {:error, {:handoff_requires_cobbler_command, _}} =
                 Elves.resume_run(fixture.run.id, opts)
      end

      assert RequestLog.count(log) == 0
    end
  end

  describe "P3: same-provider resume keeps prior-session reconcile (DOCUMENTATION)" do
    test "matching session resumes via adapter.resume; mismatch refuses before any call" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()

      opts = [
        adapter: Fake,
        adapter_opts: adapter_opts(log, Scenario.same_session_resume()),
        continuation: fixture.presented,
        provider_session_id: @sender_session
      ]

      assert {:ok, identity} = Elves.resume_run(fixture.run.id, opts)
      assert identity.provider_session_id == "fake-session-resume"
      assert RequestLog.count(log) == 1
      assert RequestLog.starts(log) == []

      {:ok, log2} = RequestLog.start()

      assert {:error, :session_mismatch} =
               Elves.resume_run(
                 fixture.run.id,
                 Keyword.merge(opts,
                   adapter_opts: adapter_opts(log2, Scenario.same_session_resume()),
                   provider_session_id: "other-session"
                 )
               )

      assert RequestLog.count(log2) == 0
    end
  end

  describe "P5: Claude path without resume/3" do
    test "same-provider Claude resume returns the precise error" do
      fixture = handoff_fixture()
      runs_before = run_count()

      assert {:error, :resume_unsupported_for_provider} =
               Elves.resume_run(fixture.run.id,
                 adapter: Shoestring.Harness.ClaudeHeadless,
                 adapter_opts: %{},
                 continuation: fixture.presented,
                 provider_session_id: @sender_session
               )

      assert run_count() == runs_before
    end

    test "cross-provider TO Claude is refused here too (B2)" do
      # The old path started Claude fresh from this call. Cross-provider is
      # cross-provider: the receiver needs an observation, an admission
      # decision and a lease of its own before anything starts.
      fixture = handoff_fixture()
      runs_before = run_count()

      assert {:error, {:handoff_requires_cobbler_command, detail}} =
               Elves.resume_run(fixture.run.id,
                 adapter: Shoestring.Harness.ClaudeHeadless,
                 adapter_opts: %{},
                 continuation: fixture.presented,
                 provider_session_id: @sender_session,
                 to_provider_id: "claude"
               )

      assert detail["to_provider_id"] == "claude"
      assert run_count() == runs_before
    end
  end

  describe "P4: Codex thread_resume turn carries the continuation" do
    test "resume turn input combines the prompt with checkpoint pointer and next action" do
      checkpoint_id = Ecto.UUID.generate()
      decision_id = Ecto.UUID.generate()
      next_action = "#{@next_action_marker} advance to step seven"
      original = "#{@original_marker} implement the widget"

      {:ok, request} =
        RunRequest.new(%{
          version: 1,
          goal_id: Ecto.UUID.generate(),
          task_id: Ecto.UUID.generate(),
          workspace_ref: "workspace/test",
          prompt: original,
          continuation: %{
            checkpoint_id: checkpoint_id,
            next_action: next_action,
            decision_refs: [decision_id]
          },
          policy: %{mode: "supervised"},
          requested_capabilities: [],
          dispatch_id: Ecto.UUID.generate(),
          extensions: %{}
        })

      prior_thread_id = "01950000-0000-7000-8000-000000000077"
      test_pid = self()

      {:ok, transport} =
        start_supervised({ResumeCaptureTransport, test_pid: test_pid})

      session =
        start_supervised!(
          {Session,
           run_request: request,
           transport_pid: transport,
           transport: ResumeCaptureTransport,
           resume: true,
           thread_id: prior_thread_id,
           auto_handshake: false,
           owner: test_pid}
        )

      :sys.replace_state(transport, fn state -> %{state | owner: session} end)
      send(session, {:codex_transport_connected, transport})

      assert {:ok, identity} = Session.await_run_identity(session, 5_000)
      assert identity.provider_session_id == prior_thread_id

      assert_receive {:captured_turn_input, input}, 5_000
      assert [%{"type" => "text", "text" => text}] = input

      # Continuation actually sent: not just the original prompt.
      assert text =~ original
      assert text =~ @next_action_marker
      assert text =~ checkpoint_id
      assert text =~ decision_id

      # Raw transcript terms never enter the turn.
      for key <- Continuation.forbidden_keys() do
        refute text =~ Atom.to_string(key)
      end
    end
  end

  # -- Fixture --

  defp handoff_fixture do
    goal = FakeHelpers.insert_goal()
    task = FakeHelpers.insert_task(goal)
    dispatch_id = Ecto.UUID.generate()
    run = FakeHelpers.insert_run_record(goal, task, dispatch_id)

    run =
      Repo.update!(Ecto.Changeset.change(run, prompt: "#{@original_marker} implement the widget"))

    snapshot_id = Ecto.UUID.generate()
    grant_id = Ecto.UUID.generate()
    checkpoint_id = Ecto.UUID.generate()
    decision_id = Ecto.UUID.generate()
    now = Shoestring.Test.FixedClock.now()

    append_event!(goal.id, run.id, "run.starting", %{"run_id" => run.id}, now)

    append_event!(
      goal.id,
      run.id,
      "run.running",
      %{"run_id" => run.id, "provider_session_id" => @sender_session},
      now
    )

    append_event!(
      goal.id,
      run.id,
      "capacity.snapshot_observed",
      %{
        "snapshot_id" => snapshot_id,
        "run_id" => run.id,
        "contract_version" => 2,
        "capacity_state" => "observed",
        "windows" => %{
          "items" => [%{"kind" => "five_hour", "state" => "observed", "used_percent" => 25.0}]
        },
        "observed_at" => "2026-08-30T12:00:00Z",
        "expires_at" => "2026-08-30T12:05:00Z",
        "freshness" => %{"max_age_seconds" => 300},
        "source" => %{
          "adapter_id" => "shoestring.harness.fake",
          "provider_id" => "fake",
          "invocation_mode" => "fake",
          "event" => "explicit_read"
        },
        "scope" => "subscription",
        "confidence" => "high",
        "support_tier" => "proactive",
        "compatibility_state" => "compatible",
        "reason" => nil,
        "extensions" => %{}
      },
      now,
      2
    )

    append_event!(
      goal.id,
      run.id,
      "lease.proposed",
      %{
        "grant_id" => grant_id,
        "run_id" => run.id,
        "admitted_snapshot_id" => snapshot_id,
        "contract_version" => 1,
        "reserves" => %{"response" => 1, "tool" => 1},
        "response_budget" => 4,
        "tool_budget" => 4,
        "deadline" => "2026-08-30T12:15:00Z",
        "checkpoint_cadence" => 2,
        "renewal_state" => "eligible",
        "extensions" => %{}
      },
      now
    )

    append_event!(goal.id, run.id, "lease.granted", %{"grant_id" => grant_id}, now)
    append_event!(goal.id, run.id, "lease.active", %{"grant_id" => grant_id}, now)

    CobblerHelpers.append_admission_event!(
      goal.id,
      CobblerHelpers.admission_payload(decision_id: decision_id)
    )

    append_event!(
      goal.id,
      run.id,
      "checkpoint.created",
      %{
        "checkpoint_id" => checkpoint_id,
        "run_id" => run.id,
        "contract_version" => 1,
        "acceptance_contract" => %{"criteria" => ["tests pass"]},
        "repository_state" => %{"revision" => "abc123", "dirty" => false},
        "evidence" => %{"items" => []},
        "decisions" => %{"items" => ["chose approach A"]},
        "unresolved_issues" => %{"items" => []},
        "next_action" => "#{@next_action_marker} advance to step seven",
        "provider_session_id" => @sender_session,
        "stop_reason" => "quota_refused",
        "artifact_ids" => %{"items" => []},
        "extensions" => %{}
      },
      now
    )

    assert {:ok, _} = Shoestring.Harness.Projector.project(goal.id)

    run = Repo.get!(Shoestring.Harness.RunRecord, run.id)

    %{
      goal: goal,
      task: task,
      run: run,
      grant_id: grant_id,
      checkpoint_id: checkpoint_id,
      decision_id: decision_id,
      presented: %{
        checkpoint_id: checkpoint_id,
        next_action: "#{@next_action_marker} advance to step seven",
        decision_refs: [decision_id]
      }
    }
  end

  defp append_event!(goal_id, run_id, type, payload, occurred_at, schema_version \\ 1) do
    assert {:ok, _event} =
             Trajectory.append(
               goal_id,
               %{
                 "type" => type,
                 "schema_version" => schema_version,
                 "actor" => "harness",
                 "occurred_at" => occurred_at,
                 "idempotency_key" =>
                   "#{type}:#{payload |> Map.values() |> inspect()}:#{System.unique_integer([:positive])}",
                 "payload" => payload
               },
               trusted: [run_id: run_id]
             )
  end

  defp adapter_opts(log, scenario) do
    %{scenario: scenario, clock: Shoestring.Test.FixedClock, request_log: log}
  end

  defp run_count do
    Repo.one!(from run in Shoestring.Harness.RunRecord, select: count(run.id))
  end
end
