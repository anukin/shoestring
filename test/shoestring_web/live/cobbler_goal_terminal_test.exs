defmodule ShoestringWeb.CobblerGoalTerminalTest do
  @moduledoc """
  LiveView coverage for loop-closure I6: finished runs keep their outcome
  class on the goal page (`completed` / `failed` instead of recycling to
  `:evaluating`), the handoff card names source/receiver from persisted
  `handoff.created` events, and the admission card shows capacity evidence
  alongside reserves — all asserted by stable element ID.

  Locking note (standing contract): the completed/failed status tests are
  TRUE regression locks. On the pre-fix commit `85437ed` run progress is
  invisible to the derivation (grouped decisions-then-commands fold), so
  a finished run renders `queued`/`dispatching` where `completed` /
  `failed` is asserted below. The handoff-card and observation tests are
  also true locks (no `#cobbler-handoff*` / `#cobbler-decision-observation`
  elements exist on base).
  """
  use ShoestringWeb.ConnCase, async: false

  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Cobbler
  alias Shoestring.Repo
  alias Shoestring.Trajectory

  @now ~U[2026-09-07 12:00:00.000000Z]

  test "a completed run renders the completed terminal state", %{conn: conn} do
    goal = create_goal!(Repo, "Completed terminal goal")
    admission = append_admission_event!(goal.id)

    assert {:ok, _} =
             Cobbler.submit_command(
               goal.id,
               claim_command(admission, command_id: "cmd-terminal-completed")
             )

    run_id = Ecto.UUID.generate()
    append_run_event!(goal.id, "run.running", run_id)
    append_run_event!(goal.id, "run.completed", run_id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-goal-status[data-status='completed']")
    assert has_element?(view, "#cobbler-handoff-empty")
  end

  test "a failed run renders the failed terminal state", %{conn: conn} do
    goal = create_goal!(Repo, "Failed terminal goal")
    admission = append_admission_event!(goal.id)

    assert {:ok, _} =
             Cobbler.submit_command(
               goal.id,
               claim_command(admission, command_id: "cmd-terminal-failed")
             )

    run_id = Ecto.UUID.generate()
    append_run_event!(goal.id, "run.running", run_id)
    append_run_event!(goal.id, "run.failed", run_id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-goal-status[data-status='failed']")
  end

  test "an interrupted run keeps the legacy evaluating recycle", %{conn: conn} do
    goal = create_goal!(Repo, "Interrupted recycle goal")
    admission = append_admission_event!(goal.id)

    assert {:ok, _} =
             Cobbler.submit_command(
               goal.id,
               claim_command(admission, command_id: "cmd-terminal-interrupted")
             )

    run_id = Ecto.UUID.generate()
    append_run_event!(goal.id, "run.running", run_id)
    append_run_event!(goal.id, "run.interrupted", run_id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-goal-status[data-status='evaluating']")
  end

  test "a handoff card names source, receiver, and the same-goal new run", %{conn: conn} do
    goal = create_goal!(Repo, "Handoff card goal")
    _admission = append_admission_event!(goal.id)

    prior_run_id = Ecto.UUID.generate()
    new_run_id = Ecto.UUID.generate()
    checkpoint_id = Ecto.UUID.generate()

    append_handoff_event!(goal.id, %{
      "from_provider_id" => "codex",
      "to_provider_id" => "claude",
      "run_id" => new_run_id,
      "prior_run_id" => prior_run_id,
      "checkpoint_id" => checkpoint_id
    })

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-goal-status[data-status='handing-off']")
    assert has_element?(view, "#cobbler-handoff")
    refute has_element?(view, "#cobbler-handoff-empty")
    assert has_element?(view, "#cobbler-handoff", "codex")
    assert has_element?(view, "#cobbler-handoff", "claude")
    assert has_element?(view, "#cobbler-handoff", "provider quota refused")
    assert has_element?(view, "#cobbler-handoff", new_run_id)
    assert has_element?(view, "#cobbler-handoff", "same goal")
  end

  test "the admission card shows capacity evidence alongside reserves", %{conn: conn} do
    goal = create_goal!(Repo, "Capacity evidence goal")
    _admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-decision-reserves", "response_budget")
    assert has_element?(view, "#cobbler-decision-observation", "freshness")
  end

  defp append_run_event!(goal_id, type, run_id) do
    payload =
      case type do
        "run.failed" ->
          %{
            "run_id" => run_id,
            "error_category" => "task_failed",
            "error_code" => "synthetic_failure"
          }

        _other ->
          %{"run_id" => run_id}
      end

    {:ok, event} =
      Trajectory.append(goal_id, %{
        "type" => type,
        "schema_version" => 1,
        "actor" => "elf",
        "occurred_at" => @now,
        "payload" => payload
      })

    event
  end

  defp append_handoff_event!(goal_id, overrides) do
    payload =
      %{
        "handoff_id" => Ecto.UUID.generate(),
        "run_id" => Ecto.UUID.generate(),
        "checkpoint_id" => Ecto.UUID.generate(),
        "from_provider_id" => "codex",
        "to_provider_id" => "claude",
        "contract_version" => 1,
        "next_action" => "Continue supervised work",
        "decision_refs" => [],
        "reason" => "provider quota refused",
        "extensions" => %{}
      }
      |> Map.merge(overrides)

    {:ok, event} =
      Trajectory.append(goal_id, %{
        "type" => "handoff.created",
        "schema_version" => 1,
        "actor" => "elf",
        "occurred_at" => @now,
        "payload" => payload
      })

    event
  end
end
