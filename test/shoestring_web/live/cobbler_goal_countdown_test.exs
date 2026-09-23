defmodule ShoestringWeb.CobblerGoalCountdownTest do
  @moduledoc """
  Covers the goal page's countdown treatment of recorded instants.

  The page previously printed bare UTC timestamps, which are exact but leave
  the operator to do the subtraction. These tests pin the replacement's two
  halves: a distance the operator can read at a glance, and the same exact
  timestamp still present in the markup.

  The honesty rule for a recorded value that is not an instant is exercised in
  `ShoestringWeb.TimeDisplayTest` rather than here, because `Trajectory.append/2`
  rejects an `admission.decided` payload whose `defer_until` will not cast to a
  datetime. On this page that branch is defence in depth against a row the
  boundary would not accept today, not a state an admission decision can reach.

  Everything here is hermetic: rows are inserted through the trajectory
  boundary, no provider is contacted and nothing is executed.
  """

  use ShoestringWeb.ConnCase, async: false

  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Cobbler.WakeupRecord
  alias Shoestring.Repo

  @defer_future "2126-09-08T12:00:00.000000Z"
  @defer_past "2019-03-04T09:15:00.000000Z"

  describe "admission deferral" do
    test "renders a future deferral as a countdown that keeps its exact timestamp", %{conn: conn} do
      view = deferred_goal_view(conn, @defer_future)

      assert has_element?(view, "#cobbler-decision-defer-until-time[datetime='#{@defer_future}']")
      assert has_element?(view, "#cobbler-decision-defer-until-time[title='#{@defer_future}']")
      assert has_element?(view, "#cobbler-decision-defer-until-time-exact", @defer_future)

      assert has_element?(
               view,
               "#cobbler-decision-defer-until-time-relative[data-countdown-to='#{@defer_future}']"
             )

      assert has_element?(
               view,
               "#cobbler-decision-defer-until-time-relative[data-countdown-direction='future']"
             )
    end

    test "renders a deferral already in the past as elapsed, not as pending", %{conn: conn} do
      view = deferred_goal_view(conn, @defer_past)

      assert has_element?(
               view,
               "#cobbler-decision-defer-until-time-relative[data-countdown-direction='past']"
             )

      assert has_element?(view, "#cobbler-decision-defer-until-time-exact", @defer_past)
    end

    test "the sleep card carries the same countdown as the admission card", %{conn: conn} do
      view = deferred_goal_view(conn, @defer_future)

      assert has_element?(view, "#cobbler-goal-status[data-status='sleeping']")
      assert has_element?(view, "#cobbler-sleep-defer-time[datetime='#{@defer_future}']")

      assert has_element?(
               view,
               "#cobbler-sleep-defer-time-relative[data-countdown-to='#{@defer_future}']"
             )

      assert has_element?(view, "#cobbler-sleep-defer-time-exact", @defer_future)
    end

    test "an admitted goal shows no deferral countdown at all", %{conn: conn} do
      goal = create_goal!(Repo, "Admitted goal")
      append_admission_event!(goal.id)

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      refute has_element?(view, "#cobbler-decision-defer-until-time")
      refute has_element?(view, "#cobbler-sleep-defer-time")
      refute has_element?(view, "#cobbler-pending-wake-time")
    end
  end

  describe "wake intents" do
    test "an operator recheck renders its queued wake time as a countdown", %{conn: conn} do
      goal = create_goal!(Repo, "Recheck countdown goal")
      append_admission_event!(goal.id)

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      view
      |> element("#cobbler-recheck-form")
      |> render_submit(%{"recheck" => %{"operator_identity" => "operator:alice"}})

      wake_at =
        WakeupRecord
        |> Repo.all()
        |> Enum.find(&(&1.goal_id == goal.id))
        |> Map.fetch!(:wake_at)
        |> DateTime.to_iso8601()

      assert has_element?(view, "#cobbler-pending-wake-time[datetime='#{wake_at}']")

      assert has_element?(
               view,
               "#cobbler-pending-wake-time-relative[data-countdown-to='#{wake_at}']"
             )

      assert has_element?(view, "#cobbler-pending-wake-time-exact", wake_at)
    end
  end

  describe "error state" do
    test "an unavailable goal renders no countdown scaffolding", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/cobbler/goals/#{Ecto.UUID.generate()}")

      assert has_element?(view, "#cobbler-goal-error")
      refute has_element?(view, "[data-countdown-to]")
    end
  end

  defp deferred_goal_view(conn, defer_until) do
    goal = create_goal!(Repo, "Deferred countdown goal")

    payload =
      admission_payload()
      |> Map.put("result", "defer_until")
      |> Map.put("reason_code", "reserve_breach")
      |> Map.put("explanation", "Deferred until quota reset")
      |> Map.put("defer_until", defer_until)

    append_admission_event!(goal.id, payload)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")
    view
  end
end
