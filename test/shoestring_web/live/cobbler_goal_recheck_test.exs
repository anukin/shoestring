defmodule ShoestringWeb.CobblerGoalRecheckTest do
  @moduledoc """
  Hermetic LiveView tests for the manual wake/recheck control (loop-closure
  I4, P3) plus the corrected sleep-card text (P4):

  - the recheck control renders (`#cobbler-recheck-form`,
    `#cobbler-recheck-operator`, `#cobbler-recheck-submit`);
  - submitting with an explicit operator identity schedules exactly one wake
    intent and one wakeup-queue job;
  - anonymous submissions are rejected and schedule nothing;
  - a duplicate recheck replays the queued intent instead of duplicating it
    (single row, single job);
  - the sleep card names the durable wake producer and invents no timestamp.

  Locking notes (standing contract), verified against `85437ed`: every test
  below FAILS on base for the right behavioural reason — base has no recheck
  control (element assertions find nothing; submissions cannot schedule) and
  its sleep card still names the stale T3 producer. True locks.
  """
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Cobbler.WakeupRecord
  alias Shoestring.Repo

  test "recheck control renders on the goal page", %{conn: conn} do
    goal = create_goal!(Repo, "Recheck control goal")
    _admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-recheck-form")
    assert has_element?(view, "#cobbler-recheck-operator")
    assert has_element?(view, "#cobbler-recheck-submit")
  end

  test "an attributed recheck schedules one intent and one job", %{conn: conn} do
    goal = create_goal!(Repo, "Recheck submit goal")
    _admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    html =
      view
      |> element("#cobbler-recheck-form")
      |> render_submit(%{"recheck" => %{"operator_identity" => "operator:alice"}})

    assert html =~ "Recheck requested"
    assert wakeup_count(goal.id) == 1
    assert wakeup_job_count(goal.id) == 1
    assert has_element?(view, "#cobbler-pending-wake")
  end

  test "an anonymous recheck is rejected and schedules nothing", %{conn: conn} do
    goal = create_goal!(Repo, "Recheck anonymous goal")
    _admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    html =
      view
      |> element("#cobbler-recheck-form")
      |> render_submit(%{"recheck" => %{"operator_identity" => "   "}})

    assert html =~ "attributable operator identity"
    assert wakeup_count(goal.id) == 0
    assert wakeup_job_count(goal.id) == 0
  end

  test "a duplicate recheck does not duplicate the queued task", %{conn: conn} do
    goal = create_goal!(Repo, "Recheck duplicate goal")
    _admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    params = %{"recheck" => %{"operator_identity" => "operator:alice"}}

    view |> element("#cobbler-recheck-form") |> render_submit(params)

    html =
      view
      |> element("#cobbler-recheck-form")
      |> render_submit(params)

    assert html =~ "already queued"
    assert wakeup_count(goal.id) == 1
    assert wakeup_job_count(goal.id) == 1
  end

  test "sleep card names the durable wake producer and invents no timestamp", %{
    conn: conn
  } do
    goal = create_goal!(Repo, "Sleep producer goal")
    _admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-sleep-card")
    assert has_element?(view, "#cobbler-sleep-card", "cobbler_wakeups")
    assert has_element?(view, "#cobbler-sleep-card", "No wake time is invented here")

    refute has_element?(view, "#cobbler-sleep-card", "T3")
    refute view |> element("#cobbler-sleep-card time") |> has_element?()
  end

  defp wakeup_count(goal_id) do
    Repo.aggregate(from(w in WakeupRecord, where: w.goal_id == ^goal_id), :count, :id)
  end

  defp wakeup_job_count(goal_id) do
    ids = Repo.all(from w in WakeupRecord, where: w.goal_id == ^goal_id, select: w.id)

    Enum.reduce(ids, 0, fn wakeup_id, acc ->
      acc +
        Repo.aggregate(
          from(job in Oban.Job,
            where:
              job.queue == "wakeup" and
                fragment("json_extract(?, '$.wakeup_id') = ?", job.args, ^wakeup_id)
          ),
          :count,
          :id
        )
    end)
  end
end
