defmodule Shoestring.Elves.InterruptionTest do
  @moduledoc """
  Regression test for the lease-boundary kill chain: an interrupted turn
  must persist as an honest `run.interrupted` terminal — never as
  `run.failed`/`task_failed` — with the completed work already durable
  before teardown.
  """

  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Elves
  alias Shoestring.Elves.{Classifier, Orchestrator}
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  defp interrupted_result(id, offset_ms) do
    Shoestring.Harness.Fake.Scenario.result_event("interrupted",
      offset_ms: offset_ms,
      source_event_id: id
    )
    |> Map.put(:extensions, %{"codex-app-server:interrupted" => true})
  end

  test "classifier keys interruption on the honest signal, never task_failed" do
    assert %{class: :interrupted} =
             Classifier.classify({:result, "interrupted"}, {:exit_status, 0}, false)

    assert %{class: :interrupted} =
             Classifier.classify({:result, "interrupted"}, :unknown, false)

    # Explicit cancellation still wins over a concurrent interruption.
    assert %{class: :cancelled} =
             Classifier.classify({:result, "interrupted"}, {:exit_status, 0}, true)

    assert Classifier.event_type(%{class: :interrupted}) == "run.interrupted"

    run_id = Ecto.UUID.generate()
    assert Classifier.event_payload(run_id, %{class: :interrupted}) == %{"run_id" => run_id}
  end

  test "interrupted turn persists run.interrupted with evidence already durable", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    scenario =
      ElvesHelpers.custom_scenario(:lease_stop, [
        %{
          kind: :command,
          offset_ms: 0,
          source_event_id: "cmd-mix-test",
          error: nil,
          result: nil,
          capacity_snapshot: nil,
          extensions: %{"shoestring.fake:command" => "mix test"}
        },
        interrupted_result("turn-interrupted", 100)
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert {:ok, run_id} =
             ElvesHelpers.wait_until(fn ->
               ElvesHelpers.run_id_for_dispatch(request.dispatch_id)
             end)

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert_receive {:elf_terminal, ^run_id, %{class: :interrupted}}, 10_000

    # The terminal is honestly recorded: interrupted, not failed, with no
    # error fields at all.
    terminal = ElvesHelpers.terminal_event(goal.id, run_id)
    assert terminal.type == "run.interrupted"
    assert terminal.payload == %{"run_id" => run_id}
    refute Map.has_key?(terminal.payload, "error_code")
    refute Map.has_key?(terminal.payload, "error_category")
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.failed"]) == 0

    # The completed work is durable and precedes the terminal: the command
    # event was persisted before teardown, not destroyed by it.
    command_event =
      Shoestring.Repo.one(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^goal.id and event.run_id == ^run_id and
              event.type == "harness.event_recorded",
          order_by: [asc: event.sequence],
          limit: 1
      )

    assert command_event.payload["kind"] == "command"
    assert command_event.payload["source_event_id"] == "cmd-mix-test"
    assert command_event.sequence < terminal.sequence

    # The orchestrator sees an interrupted (resumable, replaceable) run —
    # never a task failure.
    assert {:ok, :persisted, _observed} =
             Shoestring.Elves.Staleness.collect(run_id, "manual_probe")

    assert {:ok, packet} = Orchestrator.summarize(run_id)
    assert packet.terminal == "interrupted"
    assert packet.progress.final_response_state == "terminal_recorded"
    assert {:ok, true} = Orchestrator.can_replace?(run_id)
  end
end
