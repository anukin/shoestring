defmodule ShoestringWeb.CobblerDashboardLiveTest do
  use ShoestringWeb.ConnCase, async: false

  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Cobbler
  alias Shoestring.Repo

  test "empty: no goals render an explicit empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/cobbler")

    assert has_element?(view, "#cobbler-empty")
    assert has_element?(view, "#cobbler-refresh")
    refute has_element?(view, "#cobbler-goals-list > div")
  end

  test "goals render one row each with a presentational status", %{conn: conn} do
    goal = create_goal!(Repo, "Dashboard goal")
    _admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler")

    assert has_element?(view, "#cobbler-goals-list")
    assert has_element?(view, "#cobbler-goal-#{goal.id}[data-status='queued']")
    assert has_element?(view, "#cobbler-goal-#{goal.id}", "Dashboard goal")
    refute has_element?(view, "#cobbler-empty")
  end

  test "refresh re-reads without persisting anything", %{conn: conn} do
    goal = create_goal!(Repo, "Refresh goal")
    admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler")
    assert has_element?(view, "#cobbler-goal-#{goal.id}[data-status='queued']")

    commands_before = Repo.aggregate(Shoestring.Cobbler.CommandRecord, :count)
    events_before = Repo.aggregate(Shoestring.Trajectory.TrajectoryEvent, :count)

    view |> element("#cobbler-refresh") |> render_click()

    assert Repo.aggregate(Shoestring.Cobbler.CommandRecord, :count) == commands_before
    assert Repo.aggregate(Shoestring.Trajectory.TrajectoryEvent, :count) == events_before
    assert has_element?(view, "#cobbler-goal-#{goal.id}[data-status='queued']")
    assert admission.id != nil
  end

  test "a claimed goal renders the dispatching state with its claim", %{conn: conn} do
    goal = create_goal!(Repo, "Claimed goal")
    admission = append_admission_event!(goal.id)

    assert {:ok, _} =
             Cobbler.submit_command(
               goal.id,
               claim_command(admission, command_id: "cmd-dashboard-claim")
             )

    {:ok, view, _html} = live(conn, "/cobbler")

    assert has_element?(view, "#cobbler-goal-#{goal.id}[data-status='dispatching']")
    assert has_element?(view, "#cobbler-goal-#{goal.id}", "held by this goal")
  end

  test "goal titles are redacted at the UI boundary", %{conn: conn} do
    goal = create_goal!(Repo, "Probe at /Users/eve/.config/provider with Dashboard marker")

    {:ok, _view, html} = live(conn, "/cobbler")

    refute html =~ "/Users/eve"
    assert html =~ "[REDACTED]"
    assert html =~ "Dashboard marker"
    assert goal.id != nil
  end
end
