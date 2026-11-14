defmodule ShoestringWeb.DecisionPaneTest do
  @moduledoc """
  A decision's own pane (`/decisions/:id`): it asks one thing and is done.
  Pending: only the question, the candidates and their buttons. Chosen: the
  next task's OK when the plan holds it for the person, as one button, then
  "done" and nothing more. Rejected, withdrawn, answered elsewhere and
  unknown decisions end it too. Also: the goal page links to the pane
  instead of answering among its details, and a new decision opens the pane
  in the browser only under the browser-on-start rule.

  Hermetic: fixture goals, an injected gate runner, synthetic PNG
  candidates, a fixture agent profile, appended admission events; no
  provider and no network.
  """
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Shoestring.Test.DecisionHelpers

  alias Shoestring.{AgentProfiles, Decisions, Repo}
  alias Shoestring.Cobbler.ExecutionControl
  alias Shoestring.Decisions.{Decision, NextStep}
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  @moduletag :tmp_dir

  setup %{tmp_dir: worktree} do
    assert {:ok, _} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{
               "codex_models" => "fixture-codex"
             })

    attrs = Shoestring.ConfigurationFixtures.agent_attrs()

    roles =
      Enum.map(
        attrs["roles"],
        &Map.merge(&1, %{"provider" => "codex", "model" => "fixture-codex"})
      )

    assert {:ok, agent} = AgentProfiles.create(Map.put(attrs, "roles", roles))
    assert {:ok, profile} = AgentProfiles.snapshot_by_id(agent.id)

    goal = CobblerHelpers.create_goal!()
    write_candidates!(worktree)

    assert %{disposition: :accepted} =
             run_sheets!(goal, worktree, decision_plan(),
               repository_path: worktree,
               agent_profile: Map.put(profile, "role", "Worker"),
               admission: %{"candidate" => candidate(profile)}
             )

    [decision] = Decisions.list(goal_ids: [goal.id])
    %{goal: goal, decision: decision, worktree: worktree, profile: profile}
  end

  # What the plan's Worker resolves to: a codex role through its adapter.
  defp candidate(_profile),
    do: %{
      "provider_id" => "codex",
      "adapter_id" =>
        Shoestring.Cobbler.ExecutionProfile.identity(%{"provider" => "codex"}).adapter_id,
      "support_tier" => "proactive",
      "compatibility_state" => "compatible"
    }

  defp pane(id), do: "/decisions/#{id}"
  defp card(decision), do: "#decision-#{decision.id}"

  # The plan's next task held for the person, as the executor records it
  # when its provider's remaining usage cannot be read.
  defp hold_next!(goal, profile) do
    CobblerHelpers.admission_payload()
    |> Map.merge(%{
      "candidate" => candidate(profile),
      "result" => "require_confirmation",
      "reason_code" => "stale_observation",
      "explanation" => "Capacity observation is stale."
    })
    |> then(&CobblerHelpers.append_admission_event!(goal.id, &1))
  end

  describe "a pending decision" do
    test "shows only its question and candidates, no goal details", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, pane(ctx.decision.id))

      assert has_element?(view, "#decision-pane #{card(ctx.decision)}")

      for key <- ["red", "green", "blue"],
          do: assert(has_element?(view, "#{card(ctx.decision)}-choose-#{key}"))

      assert has_element?(view, "#{card(ctx.decision)}-reject")

      # None of the goal page's diagnostics, and no product navigation.
      for id <- ~w(cobbler-lease cobbler-checkpoint cobbler-decision-result product-nav),
          do: refute(has_element?(view, "##{id}"))
    end

    test "choosing ends it: the answer counts once and the plan is queued", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, pane(ctx.decision.id))
      view |> element("#{card(ctx.decision)}-choose-green") |> render_click()

      assert %Decision{state: "answered", answer_key: "green", decided_by: "human:" <> _} =
               Decisions.get(ctx.decision.id)

      refute has_element?(view, card(ctx.decision))
      assert has_element?(view, "#decision-chosen", "You chose A green sheet.")

      assert Repo.exists?(
               from j in Oban.Job,
                 where:
                   j.worker == "Shoestring.Cobbler.PlanExecutionWorker" and
                     fragment("json_extract(?, '$.goal_id')", j.args) == ^ctx.goal.id
             )
    end

    test "none of these needs a note, then points at the goal", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, pane(ctx.decision.id))
      view |> element("#{card(ctx.decision)}-reject") |> render_click()
      view |> form("#{card(ctx.decision)}-reject-form", %{"note" => " "}) |> render_submit()
      assert has_element?(view, "#{card(ctx.decision)}-reject-error")

      view
      |> form("#{card(ctx.decision)}-reject-form", %{"note" => "None fit."})
      |> render_submit()

      assert has_element?(view, "#decision-outcome[data-state='rejected'][data-step='done']")
      assert has_element?(view, "#decision-goal-link[href='/cobbler/goals/#{ctx.goal.id}']")
      refute has_element?(view, "#decision-start-next")
    end

    test "an answer made elsewhere shows at once, and a late click does not count",
         %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, pane(ctx.decision.id))

      assert {:ok, _} = Decisions.answer(ctx.decision.id, "blue", nil, "human:elsewhere")
      assert has_element?(view, "#decision-chosen", "You chose A blue sheet.")
      refute has_element?(view, card(ctx.decision))

      assert %Decision{answer_key: "blue", decided_by: "human:elsewhere"} =
               Decisions.get(ctx.decision.id)
    end
  end

  describe "after choosing" do
    test "the next task held for the person is one button; pressing it confirms and queues",
         %{conn: conn} = ctx do
      assert {:ok, _} = Decisions.answer(ctx.decision.id, "red", nil, "human:test")
      {:ok, view, _} = live(conn, pane(ctx.decision.id))

      # Chosen, the plan not held yet: it is starting its next task.
      assert has_element?(view, "#decision-outcome[data-step='starting']")

      hold_next!(ctx.goal, ctx.profile)
      assert has_element?(view, "#decision-outcome[data-step='confirm']")
      assert has_element?(view, "#decision-next", "Use the chosen sheet")
      assert has_element?(view, "#decision-why", "could not tell how much Codex usage is left")

      view |> element("#decision-start-next") |> render_click()

      assert [confirmed] =
               Repo.all(
                 from e in TrajectoryEvent,
                   where:
                     e.goal_id == ^ctx.goal.id and e.type == "cobbler.plan.capacity.confirmed"
               )
               |> Enum.filter(&(&1.payload["plan_task_id"] == "story"))

      assert confirmed.payload["attempt"] == 1
      assert "human:" <> _ = confirmed.payload["confirmed_by"]
      refute has_element?(view, "#decision-start-next")
      assert has_element?(view, "#decision-outcome[data-step='starting']")

      # Pressing again (a second tab) records nothing more.
      decision = Decisions.get(ctx.decision.id)

      assert {:error, :nothing_to_confirm} =
               NextStep.confirm(decision, confirmed.payload["confirmed_by"])
    end

    test "nothing held and nothing left to do: it is done", %{conn: conn} = ctx do
      assert {:ok, _} = Decisions.answer(ctx.decision.id, "red", nil, "human:test")

      done = fn _goal_id ->
        {:ok, status} = ExecutionControl.status(ctx.goal.id)
        {:ok, %{status | completed?: true}}
      end

      assert NextStep.step(Decisions.get(ctx.decision.id), status: done) == :done

      {:ok, view, _} = live(conn, pane(ctx.decision.id))
      refute has_element?(view, "#decision-start-next")
    end

    test "a confirmation that no longer applies is refused, not recorded", ctx do
      assert {:ok, _} = Decisions.answer(ctx.decision.id, "red", nil, "human:test")
      # Not held: nothing to confirm.
      assert {:error, :nothing_to_confirm} =
               NextStep.confirm(Decisions.get(ctx.decision.id), "human:test")

      refute Repo.exists?(
               from e in TrajectoryEvent,
                 where:
                   e.goal_id == ^ctx.goal.id and e.type == "cobbler.plan.capacity.confirmed" and
                     fragment("json_extract(?, '$.plan_task_id')", e.payload) == "story"
             )
    end
  end

  test "an unknown or malformed decision says so", %{conn: conn} do
    {:ok, view, _} = live(conn, pane(Ecto.UUID.generate()))
    assert has_element?(view, "#decision-missing")
    {:ok, view, _} = live(conn, pane("nonsense"))
    assert has_element?(view, "#decision-missing")
  end

  describe "a new decision comes to the person" do
    test "its pane opens once, only under the browser-on-start rule", %{worktree: worktree} do
      test = self()
      opener = fn url -> send(test, {:opened, url}) end

      for {env, allowed?, expect} <- [{"1", true, true}, {"0", true, false}, {"1", false, false}] do
        goal = CobblerHelpers.create_goal!()
        write_candidates!(worktree)

        run_sheets!(goal, worktree, decision_plan(),
          complete_opts: [
            browser_opts: [env: fn _ -> env end, allowed?: allowed?, opener: opener]
          ]
        )

        [decision] = Decisions.list(goal_ids: [goal.id])

        if expect do
          assert_receive {:opened, url}, 2_000
          assert url =~ ~r"\Ahttp://localhost:\d+/decisions/#{decision.id}\z"
        else
          refute_receive {:opened, _}, 200
        end
      end
    end
  end

  describe "the goal page" do
    test "links a pending decision to its pane, at the top, instead of answering it",
         %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/cobbler/goals/#{ctx.goal.id}")
      link = "#plan-decision-#{ctx.decision.id}-open[href='#{pane(ctx.decision.id)}']"
      assert has_element?(view, "#cobbler-plan-decisions #{link}")
      refute has_element?(view, card(ctx.decision))
      assert has_element?(view, "#cobbler-goal-status[data-status='plan-needs-user']")

      assert {:ok, _} = Decisions.answer(ctx.decision.id, "blue", nil, "human:test")

      assert has_element?(
               view,
               "#plan-decision-#{ctx.decision.id}-state[data-state='answered']",
               "Chosen: blue"
             )
    end
  end
end
