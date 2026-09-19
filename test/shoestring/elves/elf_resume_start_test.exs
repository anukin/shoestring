defmodule Shoestring.Elves.NoResumeFake do
  @moduledoc false
  # Fake transport surface without resume/3 (like ClaudeHeadless): exercises
  # the fresh-start branch for requests that carry a continuation.
  @behaviour Shoestring.Harness.Adapter
  alias Shoestring.Harness.Fake
  def identity, do: Fake.identity()
  def capabilities, do: Fake.capabilities() |> MapSet.delete(:resume)
  def probe(opts), do: Fake.probe(opts)
  def start(request, opts), do: Fake.start(request, opts)
  def status(identity, opts), do: Fake.status(identity, opts)
  def stream(identity, opts), do: Fake.stream(identity, opts)
end

defmodule Shoestring.Elves.ElfResumeStartTest do
  @moduledoc """
  Hermetic Elf tests for resume-first adapter start (round-2 finding 5
  follow-up for wake continuations): when the run request carries
  `wakeup:resume_prior_session_id` and the adapter supports resume, the Elf
  resumes the prior session instead of starting fresh; a failed resume
  falls back to a fresh start (a dead session must not fail an admitted
  wake); without the extension the Elf starts as before.

  Fail-on-base: without the resume branch the Elf always starts — the
  resume-preferred test fails (starts non-empty where empty asserted),
  and the native-resume and no-resume-adapter prompt assertions fail with
  the original prompt verbatim. The failed-resume fallback assertions
  pass on base too (R4.4 already composed that path — documentation of
  preserved behavior), as does the no-extension fresh-start prompt pin.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Harness.Fake
  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Test.ElvesHelpers

  @terminal_timeout 15_000

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "prior session extension prefers adapter resume over fresh start", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    {:ok, log} = RequestLog.start()
    run_id = Ecto.UUID.generate()

    # A wake-style request: prior session plus a continuation triple. The
    # native resume must receive the composed bounded projection (not the
    # bare original prompt, never a transcript) with resume-truthful
    # constraints. (Base: resume receives the original prompt verbatim.)
    base = resume_request(goal, task, run_id)

    request = %{
      base
      | continuation: %{
          checkpoint_id: Ecto.UUID.generate(),
          next_action: "RESUME-NEXT-11 finish the widget",
          decision_refs: []
        }
    }

    scenario =
      ElvesHelpers.custom_scenario(:resume_preferred, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("working", source_event_id: "evt-out"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: Fake,
               adapter_opts: %{scenario: scenario, request_log: log},
               command: ["sleep", "30"],
               runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000],
               notify: self()
             )

    assert {:ok, true} =
             ElvesHelpers.wait_until(fn ->
               if RequestLog.resumes(log) != [], do: true
             end)

    assert RequestLog.starts(log) == []
    # Resumed, streamed, and terminated normally on the fast lifecycle.
    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, @terminal_timeout

    # The native resume received the composed projection: checkpoint
    # pointer + next action with resume-truthful constraints (retained
    # session context acknowledged, checkpoint authoritative) — never the
    # bare original prompt, never a transcript.
    [resumed] = RequestLog.resumes(log)
    assert resumed.prompt =~ "RESUME-NEXT-11"
    assert resumed.prompt =~ "Continue from checkpoint"
    assert resumed.prompt =~ "authoritative"
    refute resumed.prompt == "Do the deterministic thing."
    refute resumed.prompt =~ "no prior transcript available"
  end

  test "failed resume falls back to a fresh start", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    {:ok, log} = RequestLog.start()
    run_id = Ecto.UUID.generate()

    base_request = resume_request(goal, task, run_id)

    request = %{
      base_request
      | extensions: %{"wakeup:resume_prior_session_id" => "fake-session-dead-9"},
        continuation: %{
          checkpoint_id: Ecto.UUID.generate(),
          next_action: "FALLBACK-NEXT-77 finish the widget",
          decision_refs: []
        }
    }

    base_scenario =
      ElvesHelpers.custom_scenario(:resume_fallback, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    scenario = %{
      base_scenario
      | resume_error: Shoestring.Harness.Error.new(:task_failed, "resume_failed", "dead session")
    }

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: Fake,
               adapter_opts: %{scenario: scenario, request_log: log},
               command: ["sleep", "30"],
               runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000],
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, @terminal_timeout
    assert RequestLog.starts(log) != []

    # The fallback replacement carries the checkpoint context, not the
    # stale original prompt — and truthfully describes a NEW session with
    # no retained transcript (the resume failed). (Base: original prompt
    # verbatim.)
    [started] = RequestLog.starts(log)
    assert started.prompt =~ "FALLBACK-NEXT-77"
    assert started.prompt =~ "Continue from checkpoint"
    assert started.prompt =~ "no prior transcript available"
    refute started.prompt == "Do the deterministic thing."
  end

  test "no resume extension starts fresh without attempting resume", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    {:ok, log} = RequestLog.start()
    run_id = Ecto.UUID.generate()
    request = ElvesHelpers.run_request(goal, task, dispatch_id: run_id)

    scenario =
      ElvesHelpers.custom_scenario(:fresh_start, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: Fake,
               adapter_opts: %{scenario: scenario, request_log: log},
               command: ["sleep", "30"],
               runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000],
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, @terminal_timeout
    assert RequestLog.starts(log) != []
    assert RequestLog.resumes(log) == []

    # No continuation, no prior session: the original prompt stands
    # verbatim. (Passes on base too — documentation of the preserved
    # non-continuation path.)
    [started] = RequestLog.starts(log)
    assert started.prompt == "Do the deterministic thing."
  end

  test "fresh start without resume support still carries the continuation", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # Adapters without resume/3 (like ClaudeHeadless) take the fresh branch
    # even when the request carries a prior session: the started request
    # must still carry the composed checkpoint prompt, not the original.
    # (Base: original prompt verbatim.)
    {:ok, log} = RequestLog.start()
    run_id = Ecto.UUID.generate()
    base = ElvesHelpers.run_request(goal, task, dispatch_id: run_id)

    request = %{
      base
      | extensions: %{"wakeup:resume_prior_session_id" => "fake-session-x"},
        continuation: %{
          checkpoint_id: Ecto.UUID.generate(),
          next_action: "FRESH-NEXT-42 finish the widget",
          decision_refs: []
        }
    }

    scenario =
      ElvesHelpers.custom_scenario(:fresh_composed, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: Shoestring.Elves.NoResumeFake,
               adapter_opts: %{scenario: scenario, request_log: log},
               command: ["sleep", "30"],
               runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000],
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, @terminal_timeout
    [started] = RequestLog.starts(log)
    assert started.prompt =~ "FRESH-NEXT-42"
    assert started.prompt =~ "Continue from checkpoint"
    assert started.prompt =~ "no prior transcript available"
    refute started.prompt == "Do the deterministic thing."
  end

  defp resume_request(goal, task, run_id) do
    request = ElvesHelpers.run_request(goal, task, dispatch_id: run_id)

    %{
      request
      | extensions: %{"wakeup:resume_prior_session_id" => "fake-session-resume-1"}
    }
  end
end
