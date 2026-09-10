defmodule Shoestring.Harness.HandoffCorrectionTest do
  @moduledoc """
  Hermetic regression locks for the handoff loop-closure correction (I5),
  plus the round-2 finding-5 replay honesty fix:

    * P1 intent-first: `handoff.created` precedes `run.requested` precedes
      the adapter effect.
    * Replay honesty (finding 5): a present receiver row is NOT success.
      On replay the receiver is returned with zero new calls only with
      terminal/result evidence or an observably live session; otherwise
      the effect is re-attempted with the same handoff/run/dispatch ids
      (at-least-once, idempotent convergence). Fake exposes no sessions,
      so Fake replays re-attempt whenever no terminal evidence exists.
    * P2 cross-provider = fresh session: the target receives
      `adapter.start/2` (never resume) with a continuation-composed prompt;
      the sender's session identity appears nowhere in the recorded request.
    * P4 Codex `thread_resume` turn carries continuation content, not just
      the original prompt.
    * P5 same-provider resume without `resume/3` (Claude) returns the
      precise `:resume_unsupported_for_provider` error; cross-provider TO
      Claude goes through the fresh-start path.
    * Privacy sweeps both directions: sensitive gone AND required present.

  Lock-vs-documentation ledger (base commit `4d2df5a`): the failed-start,
  crash-before-start, no-terminal re-attempt, and dead-session tests are
  TRUE locks — they FAIL on base, which replays any present receiver row
  to success with zero new calls. The post-terminal and live-session
  tests are DOCUMENTATION: they pass on base (base also returned success
  with zero calls there) and pin the preserved success path. The
  same-provider matrix test is DOCUMENTATION (passes on base).
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

  defmodule SilentStartFailureAdapter do
    @moduledoc false
    @behaviour Shoestring.Harness.Adapter

    alias Shoestring.Harness.{Error, Fake}

    @impl true
    def identity, do: Fake.identity()
    @impl true
    def capabilities, do: Fake.capabilities()
    @impl true
    def probe(opts), do: Fake.probe(opts)

    @impl true
    def start(_request, _opts) do
      # Crash between row insert and adapter start: durable state persists,
      # but zero attempts are recorded in the RequestLog.
      {:error, Error.new(:transport, "process_launch_failed", "silent start failure")}
    end

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
  end

  defmodule LiveSessionStubAdapter do
    @moduledoc false
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

    @doc "Marks a receiver run id as having a live session (test process registry)."
    def mark_live(run_id, pid \\ self()) do
      live = Process.get(:live_session_stub_live, %{})
      Process.put(:live_session_stub_live, Map.put(live, run_id, pid))
      :ok
    end

    @doc "Session liveness read, mirroring CodexAppServer.lookup_session/1."
    def lookup_session(run_id) do
      case Process.get(:live_session_stub_live, %{}) do
        %{^run_id => pid} when is_pid(pid) -> {:ok, pid}
        _ -> {:error, :not_found}
      end
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

    test "failed start replays to a re-attempt: same run, one new effect, no duplicates" do
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

      # Replay with the same handoff_id re-attempts the effect: the failed
      # start left no terminal/result evidence and Fake exposes no live
      # sessions, so replaying to success here would report an effect that
      # never ran (round-2 finding 5).
      assert {:ok, %{handoff_id: ^handoff_id, run: replayed, run_identity: identity}} =
               Elves.resume_run(
                 fixture.run.id,
                 Keyword.put(
                   base_opts,
                   :adapter_opts,
                   adapter_opts(log, Scenario.handoff_target())
                 )
               )

      assert replayed.id == new_run_id
      assert identity.provider_session_id == "fake-session-handoff-b"

      # At-least-once: exactly one NEW adapter call (failed attempt + success).
      assert RequestLog.count(log) == 2
      assert RequestLog.resumes(log) == []

      # Idempotent convergence: still exactly one of each durable effect.
      assert handoff_count(fixture.goal.id, handoff_id) == 1
      assert requested_count(fixture.goal.id, new_dispatch_id) == 1
    end

    test "crash before adapter start (row exists, zero logged attempts): replay performs the effect once" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      handoff_id = Ecto.UUID.generate()
      new_run_id = Ecto.UUID.generate()
      new_dispatch_id = Ecto.UUID.generate()

      base_opts = [
        continuation: fixture.presented,
        provider_session_id: @sender_session,
        to_provider_id: "fake-harness-b",
        reason: "quota handoff",
        handoff_id: handoff_id,
        new_run_id: new_run_id,
        new_dispatch_id: new_dispatch_id
      ]

      # Attempt 1: crash between row insert and adapter start — the receiver
      # row and intent are durable, but the adapter records zero attempts.
      assert {:error, _} =
               Elves.resume_run(
                 fixture.run.id,
                 base_opts
                 |> Keyword.put(:adapter, SilentStartFailureAdapter)
                 |> Keyword.put(:adapter_opts, adapter_opts(log, Scenario.handoff_target()))
               )

      assert handoff_count(fixture.goal.id, handoff_id) == 1
      assert RequestLog.count(log) == 0

      # Replay performs the effect exactly once with the same ids.
      assert {:ok, %{handoff_id: ^handoff_id, run: replayed, run_identity: identity}} =
               Elves.resume_run(
                 fixture.run.id,
                 base_opts
                 |> Keyword.put(:adapter, Fake)
                 |> Keyword.put(:adapter_opts, adapter_opts(log, Scenario.handoff_target()))
               )

      assert replayed.id == new_run_id
      assert identity.provider_session_id == "fake-session-handoff-b"
      assert RequestLog.count(log) == 1
      assert RequestLog.resumes(log) == []
      assert handoff_count(fixture.goal.id, handoff_id) == 1
      assert requested_count(fixture.goal.id, new_dispatch_id) == 1
    end

    test "replay without terminal evidence re-attempts the effect (Fake exposes no live sessions)" do
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

      # No terminal/result evidence exists for the receiver and Fake has no
      # session lookup, so an immediate replay must re-attempt rather than
      # report the unexecuted effect as a success.
      assert {:ok, %{handoff_id: ^handoff_id, run: second, run_identity: identity}} =
               Elves.resume_run(fixture.run.id, opts)

      assert second.id == first.id
      assert identity.provider_session_id == "fake-session-handoff-b"
      assert RequestLog.count(log) == 2
      assert RequestLog.resumes(log) == []
      assert handoff_count(fixture.goal.id, handoff_id) == 1
      assert requested_count(fixture.goal.id, new_dispatch_id) == 1
    end

    test "replay after terminal evidence performs zero new adapter calls" do
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

      # Downstream completion: terminal evidence for the receiver run.
      :ok = FakeHelpers.append_run_completed(fixture.goal, first)

      assert {:ok, %{handoff_id: ^handoff_id, run: second}} =
               Elves.resume_run(fixture.run.id, opts)

      assert second.id == first.id
      assert RequestLog.count(log) == 1
      assert RequestLog.resumes(log) == []
      assert handoff_count(fixture.goal.id, handoff_id) == 1
    end

    test "live receiver session replays to success with zero new calls (DOCUMENTATION)" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      handoff_id = Ecto.UUID.generate()
      new_run_id = Ecto.UUID.generate()
      new_dispatch_id = Ecto.UUID.generate()

      opts = [
        adapter: LiveSessionStubAdapter,
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

      # The receiver session is observably live: replay succeeds without a
      # new adapter call. This documents the preserved success path — it
      # passes on base too, since base also returned success here.
      :ok = LiveSessionStubAdapter.mark_live(first.id)

      assert {:ok, %{handoff_id: ^handoff_id, run: second}} =
               Elves.resume_run(fixture.run.id, opts)

      assert second.id == first.id
      assert RequestLog.count(log) == 1
      assert RequestLog.resumes(log) == []
      assert handoff_count(fixture.goal.id, handoff_id) == 1
    end

    test "dead receiver session does not mask: replay re-attempts" do
      fixture = handoff_fixture()
      {:ok, log} = RequestLog.start()
      handoff_id = Ecto.UUID.generate()
      new_run_id = Ecto.UUID.generate()
      new_dispatch_id = Ecto.UUID.generate()

      opts = [
        adapter: LiveSessionStubAdapter,
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

      # A registry entry pointing at a dead pid is not a live session.
      {:ok, dead} = Agent.start(fn -> :ok end)
      :ok = Agent.stop(dead)
      :ok = LiveSessionStubAdapter.mark_live(first.id, dead)

      assert {:ok, %{handoff_id: ^handoff_id, run: second, run_identity: identity}} =
               Elves.resume_run(fixture.run.id, opts)

      assert second.id == first.id
      assert identity.provider_session_id == "fake-session-handoff-b"
      assert RequestLog.count(log) == 2
      assert handoff_count(fixture.goal.id, handoff_id) == 1
      assert requested_count(fixture.goal.id, new_dispatch_id) == 1
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
