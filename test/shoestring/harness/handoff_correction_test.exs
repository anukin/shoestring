defmodule Shoestring.Harness.HandoffCorrectionTest do
  @moduledoc """
  Hermetic regression locks for the handoff loop-closure correction (I5):

    * P1 intent-first: `handoff.created` precedes `run.requested` precedes
      the adapter effect; replaying with the same `handoff_id` converges
      (one effect after a crash-between, zero duplicate adapter calls
      after success).
    * P2 cross-provider = fresh session: the target receives
      `adapter.start/2` (never resume) with a continuation-composed prompt;
      the sender's session identity appears nowhere in the recorded request.
    * P4 Codex `thread_resume` turn carries continuation content, not just
      the original prompt.
    * P5 same-provider resume without `resume/3` (Claude) returns the
      precise `:resume_unsupported_for_provider` error; cross-provider TO
      Claude goes through the fresh-start path.
    * Privacy sweeps both directions: sensitive gone AND required present.

  Every lock below FAILS on the base commit `85437ed` for the right
  behavioural reason (effect-before-intent ordering, original-prompt turn,
  generic `resume_unsupported`), except the same-provider matrix test,
  which is explicitly labeled DOCUMENTATION (it passes on base).
  """

  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Harness.{Continuation, Contract, Fake, RunRequest}
  alias Shoestring.Harness.CodexAppServer.Session
  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Harness.Security
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

  describe "P1+P2: intent-first cross-provider handoff with fresh session" do
    test "handoff.created precedes run.requested; target started fresh with composed prompt" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      handoff_id = Ecto.UUID.generate()
      new_run_id = Ecto.UUID.generate()
      new_dispatch_id = Ecto.UUID.generate()

      assert {:ok, %{handoff_id: ^handoff_id, run: new_run, run_identity: identity}} =
               Elves.resume_run(fixture.run.id,
                 adapter: Fake,
                 adapter_opts: adapter_opts(log, Scenario.handoff_target()),
                 continuation: fixture.presented,
                 provider_session_id: @sender_session,
                 to_provider_id: "fake-harness-b",
                 reason: "quota handoff",
                 handoff_id: handoff_id,
                 new_run_id: new_run_id,
                 new_dispatch_id: new_dispatch_id
               )

      assert new_run.id == new_run_id
      assert new_run.goal_id == fixture.goal.id

      # Fresh identity: the target session is new, never the sender's.
      assert identity.provider_session_id == "fake-session-handoff-b"
      refute identity.provider_session_id == @sender_session

      # Fresh session: exactly one start, zero resumes.
      assert RequestLog.count(log) == 1
      assert RequestLog.resumes(log) == []
      [recorded] = RequestLog.starts(log)

      # Exact continuation keys (3-key pointer, additive schema unchanged).
      assert Enum.sort(Map.keys(recorded.continuation)) ==
               [:checkpoint_id, :decision_refs, :next_action]

      assert recorded.continuation.checkpoint_id == fixture.checkpoint_id
      assert recorded.continuation.next_action =~ @next_action_marker
      assert recorded.continuation.decision_refs == [fixture.decision_id]

      # Composed prompt: continuation IS sent, original transcript is not.
      assert recorded.prompt =~ @next_action_marker
      assert recorded.prompt =~ fixture.checkpoint_id
      refute recorded.prompt =~ @original_marker

      # Sender session identity appears nowhere in the recorded request.
      refute inspect(recorded) =~ @sender_session

      # Ordering proof: intent (handoff.created) before durable effect
      # (run.requested) for the new run.
      handoff_seq = event_sequence!(fixture.goal.id, new_run_id, "handoff.created")
      requested_seq = event_sequence!(fixture.goal.id, new_run_id, "run.requested")
      assert handoff_seq < requested_seq

      # Pointer event: required present, sensitive gone (both directions).
      handoff_event =
        Repo.one!(
          from event in TrajectoryEvent,
            where:
              event.goal_id == ^fixture.goal.id and event.type == "handoff.created" and
                event.idempotency_key == ^"handoff:#{handoff_id}"
        )

      assert handoff_event.payload["handoff_id"] == handoff_id
      assert handoff_event.payload["run_id"] == new_run_id
      assert handoff_event.payload["checkpoint_id"] == fixture.checkpoint_id
      assert handoff_event.payload["prior_run_id"] == fixture.run.id
      assert handoff_event.payload["to_provider_id"] == "fake-harness-b"
      assert handoff_event.payload["reason"] == "quota handoff"
      assert handoff_event.payload["next_action"] =~ @next_action_marker

      for key <- Continuation.forbidden_keys() do
        refute Map.has_key?(handoff_event.payload, Atom.to_string(key)),
               "forbidden key #{key} in handoff payload"

        refute Map.has_key?(recorded.continuation, key),
               "forbidden key #{key} reached the adapter"
      end

      assert Security.scan_term(handoff_event.payload) == []
      assert Contract.safe_term?(handoff_event.payload)
      assert Security.scan_term(recorded.prompt) == []

      # The stored run continuation is a clean 3-key pointer too.
      assert :ok = Continuation.validate_attrs(new_run.continuation)
    end

    test "crash between intent and effect: replay yields one effect, no duplicates" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      handoff_id = Ecto.UUID.generate()
      new_run_id = Ecto.UUID.generate()
      new_dispatch_id = Ecto.UUID.generate()

      base_opts = [
        adapter: Fake,
        continuation: fixture.presented,
        provider_session_id: @sender_session,
        to_provider_id: "fake-harness-b",
        reason: "quota handoff",
        handoff_id: handoff_id,
        new_run_id: new_run_id,
        new_dispatch_id: new_dispatch_id
      ]

      # Attempt 1: the adapter effect fails AFTER intent is durable.
      assert {:error, _} =
               Elves.resume_run(
                 fixture.run.id,
                 Keyword.put(
                   base_opts,
                   :adapter_opts,
                   adapter_opts(log, Scenario.start_failure())
                 )
               )

      # Intent precedes effect: the pointer survived the failed effect.
      assert handoff_count(fixture.goal.id, handoff_id) == 1
      assert RequestLog.count(log) == 1

      # Replay with the same handoff_id converges: same run, zero new
      # adapter calls.
      assert {:ok, %{handoff_id: ^handoff_id, run: replayed}} =
               Elves.resume_run(
                 fixture.run.id,
                 Keyword.put(
                   base_opts,
                   :adapter_opts,
                   adapter_opts(log, Scenario.handoff_target())
                 )
               )

      assert replayed.id == new_run_id
      assert RequestLog.count(log) == 1
      assert RequestLog.resumes(log) == []
      assert handoff_count(fixture.goal.id, handoff_id) == 1
      assert requested_count(fixture.goal.id, new_dispatch_id) == 1
    end

    test "replay after success performs zero new adapter calls" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      handoff_id = Ecto.UUID.generate()
      new_run_id = Ecto.UUID.generate()
      new_dispatch_id = Ecto.UUID.generate()

      opts = [
        adapter: Fake,
        adapter_opts: adapter_opts(log, Scenario.handoff_target()),
        continuation: fixture.presented,
        provider_session_id: @sender_session,
        to_provider_id: "fake-harness-b",
        reason: "quota handoff",
        handoff_id: handoff_id,
        new_run_id: new_run_id,
        new_dispatch_id: new_dispatch_id
      ]

      assert {:ok, %{run: first}} = Elves.resume_run(fixture.run.id, opts)
      assert RequestLog.count(log) == 1

      assert {:ok, %{handoff_id: ^handoff_id, run: second}} =
               Elves.resume_run(fixture.run.id, opts)

      assert second.id == first.id
      assert RequestLog.count(log) == 1
      assert RequestLog.resumes(log) == []
      assert handoff_count(fixture.goal.id, handoff_id) == 1
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

    test "cross-provider TO Claude starts a fresh session (no fake resume)" do
      fixture = handoff_fixture()
      handoff_id = Ecto.UUID.generate()
      new_run_id = Ecto.UUID.generate()
      new_dispatch_id = Ecto.UUID.generate()

      assert {:ok, %{handoff_id: ^handoff_id, run: new_run, run_identity: identity}} =
               Elves.resume_run(fixture.run.id,
                 adapter: Shoestring.Harness.ClaudeHeadless,
                 adapter_opts: %{},
                 continuation: fixture.presented,
                 provider_session_id: @sender_session,
                 to_provider_id: "claude",
                 reason: "quota handoff",
                 handoff_id: handoff_id,
                 new_run_id: new_run_id,
                 new_dispatch_id: new_dispatch_id
               )

      assert new_run.id == new_run_id
      assert identity.provider_session_id == "aaaaaaaa-0000-4000-a000-000000000001"

      handoff_event =
        Repo.one!(
          from event in TrajectoryEvent,
            where:
              event.goal_id == ^fixture.goal.id and event.type == "handoff.created" and
                event.idempotency_key == ^"handoff:#{handoff_id}"
        )

      assert handoff_event.payload["to_provider_id"] == "claude"
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

  defp event_sequence!(goal_id, run_id, type) do
    Repo.one!(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.run_id == ^run_id and event.type == ^type,
        order_by: [asc: event.sequence],
        limit: 1,
        select: event.sequence
    )
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

  defp requested_count(goal_id, dispatch_id) do
    key = "run-requested:" <> dispatch_id

    Repo.one!(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == "run.requested" and
            event.idempotency_key == ^key,
        select: count(event.id)
    )
  end

  defp run_count do
    Repo.one!(from run in Shoestring.Harness.RunRecord, select: count(run.id))
  end
end
