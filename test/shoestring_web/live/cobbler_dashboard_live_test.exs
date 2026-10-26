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

  test "coordinator sessions show their grant's use and each dispatch's state", %{conn: conn} do
    {:ok, _} = Shoestring.ModelCatalog.add("codex", "gpt-6-luna")

    grant_attrs = fn session ->
      %{
        session_id: session,
        repository_root: "/tmp/dashboard-repo",
        models: ["codex:gpt-6-luna"],
        purposes: ["implement"],
        max_dispatches: 4,
        max_parallel: 2,
        max_total_seconds: 7200,
        max_dispatch_seconds: 3600,
        unread_usage: 1
      }
    end

    {:ok, grant} = Shoestring.Grants.create(grant_attrs.("s-dash"), "human:operator")
    {:ok, empty} = Shoestring.Grants.create(grant_attrs.("s-empty"), "human:operator")

    dispatch =
      Repo.insert!(%Shoestring.Dispatches.Dispatch{
        grant_id: grant.id,
        session_id: "s-dash",
        request_id: "r1",
        purpose: "implement",
        provider: "codex",
        model: "gpt-6-luna",
        reviewer_provider: "claude",
        reviewer_model: "opus",
        title: "Make add return the sum",
        brief: "IMPLEMENT - add",
        brief_digest: "d",
        repository_root: "/tmp/dashboard-repo",
        base_revision: "0a1b2c3",
        max_attempts: 1,
        max_duration_seconds: 1800,
        plan: %{},
        plan_digest: "p",
        state: "failed",
        error: "goal_not_created"
      })

    {:ok, view, _html} = live(conn, "/cobbler")

    assert has_element?(view, "#coordinator-sessions")
    # A dispatch that failed to start reserves nothing.
    assert has_element?(view, "#session-#{grant.id}", "Attempts 0 of 4")

    assert has_element?(
             view,
             "#dispatch-#{dispatch.id}[data-state='failed_to_start']",
             "Make add return the sum"
           )

    assert has_element?(view, "#dispatch-#{dispatch.id}", "reviewed by claude:opus")
    assert has_element?(view, "#session-#{empty.id}", "No dispatches yet.")
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
