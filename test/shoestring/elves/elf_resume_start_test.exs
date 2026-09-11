defmodule Shoestring.Elves.ElfResumeStartTest do
  @moduledoc """
  Hermetic Elf tests for resume-first adapter start (round-2 finding 5
  follow-up for wake continuations): when the run request carries
  `wakeup:resume_prior_session_id` and the adapter supports resume, the Elf
  resumes the prior session instead of starting fresh; a failed resume
  falls back to a fresh start (a dead session must not fail an admitted
  wake); without the extension the Elf starts as before.

  Fail-on-base: without the resume branch the Elf always starts — the
  resume-preferred test fails (starts non-empty where empty asserted). The
  fallback and fresh-start tests pass on base too (they pin preserved
  start behavior, not the new branch) — documentation, stated honestly.
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
    request = resume_request(goal, task, run_id)

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
    # stale original prompt. (Base: original prompt verbatim.)
    [started] = RequestLog.starts(log)
    assert started.prompt =~ "FALLBACK-NEXT-77"
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
  end

  defp resume_request(goal, task, run_id) do
    request = ElvesHelpers.run_request(goal, task, dispatch_id: run_id)

    %{
      request
      | extensions: %{"wakeup:resume_prior_session_id" => "fake-session-resume-1"}
    }
  end
end
