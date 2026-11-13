defmodule ShoestringWeb.DecisionsWebTest do
  @moduledoc """
  Iteration 19 Package B: a person sees a decision's candidates and answers
  it on the web. The artifact route (loopback only, candidates only, exact
  bytes, refusals), the decision as an attention item and card, the
  needs-you count, and answering from the Sessions page and the goal page.

  Hermetic: fixture sessions and dispatches, an injected gate runner, and
  synthetic solid-colour PNG candidates in a temporary worktree.
  """
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Shoestring.SessionsFixtures
  import Shoestring.Test.DecisionHelpers

  alias Shoestring.{Attention, Decisions, Repo}
  alias Shoestring.Decisions.Decision
  alias Shoestring.Trajectory.{Artifact, ArtifactStore}
  alias ShoestringWeb.AttentionComponents

  @moduletag :tmp_dir

  setup %{tmp_dir: worktree} do
    ctx = session()
    # A dispatch whose goal runs the deciding plan (its own fixture goal
    # already carries a one-task plan).
    goal = Shoestring.Test.CobblerHelpers.create_goal!()
    builder = dispatch_fixture(ctx, "implement", "builder", "Draw the reference sheets")

    Repo.update_all(from(d in Shoestring.Dispatches.Dispatch, where: d.id == ^builder.id),
      set: [goal_id: goal.id]
    )

    builder = Shoestring.Dispatches.get(builder.id)
    write_candidates!(worktree)

    assert %{disposition: :accepted} =
             run_sheets!(goal, worktree, decision_plan(), repository_path: worktree)

    [decision] = Decisions.list(goal_ids: [goal.id])
    Map.merge(ctx, %{builder: builder, goal: goal, worktree: worktree, decision: decision})
  end

  defp local(conn), do: %{conn | host: "localhost"}
  defp artifact_path(goal_id, artifact_id), do: "/goals/#{goal_id}/artifacts/#{artifact_id}"
  defp option(decision, key), do: Enum.find(decision.options, &(&1["key"] == key))

  # --------------------------------------------------------------------------
  # The artifact route
  # --------------------------------------------------------------------------

  describe "GET /goals/:goal_id/artifacts/:artifact_id" do
    test "serves a candidate's exact bytes inline with its type, sandboxed", ctx do
      red = option(ctx.decision, "red")
      bytes = File.read!(Path.join(ctx.worktree, red["file"]))

      conn = get(local(build_conn()), artifact_path(ctx.goal.id, red["artifact_id"]))

      assert conn.status == 200
      assert conn.resp_body == bytes
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
      assert get_resp_header(conn, "content-security-policy") == ["sandbox; default-src 'none'"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "is refused off loopback and to a non-local host name", ctx do
      path = artifact_path(ctx.goal.id, option(ctx.decision, "red")["artifact_id"])

      remote = %{local(build_conn()) | remote_ip: {10, 0, 0, 5}}
      assert get(remote, path).status == 403

      # DNS rebinding: a loopback connection naming another host.
      assert get(%{build_conn() | host: "evil.example"}, path).status == 403
    end

    test "is 404 for another goal, for an artifact no decision offers, and for nonsense", ctx do
      red = option(ctx.decision, "red")
      other = Shoestring.Test.CobblerHelpers.create_goal!()

      # A goal that does not own the candidate.
      assert get(local(build_conn()), artifact_path(other.id, red["artifact_id"])).status == 404

      # An artifact of this goal that is not a candidate (evidence, a log).
      {:ok, log} =
        ArtifactStore.put(ctx.goal.id, "secret log", %{media_type: "text/plain", redacted: false})

      assert get(local(build_conn()), artifact_path(ctx.goal.id, log.id)).status == 404
      assert get(local(build_conn()), artifact_path(ctx.goal.id, "not-a-uuid")).status == 404

      assert get(local(build_conn()), artifact_path(ctx.goal.id, Ecto.UUID.generate())).status ==
               404
    end

    test "never serves another goal's artifact, even if a decision row names it", ctx do
      other = Shoestring.Test.CobblerHelpers.create_goal!()

      {:ok, foreign} =
        ArtifactStore.put(other.id, "another goal's bytes", %{
          media_type: "text/plain",
          redacted: false
        })

      [first | rest] = ctx.decision.options

      Repo.update_all(from(d in Decision, where: d.id == ^ctx.decision.id),
        set: [options: [%{first | "artifact_id" => foreign.id} | rest]]
      )

      assert get(local(build_conn()), artifact_path(ctx.goal.id, foreign.id)).status == 404
    end

    test "refuses a redacted artifact", ctx do
      red = option(ctx.decision, "red")

      Repo.update_all(from(a in Artifact, where: a.id == ^red["artifact_id"]),
        set: [redacted: true]
      )

      assert get(local(build_conn()), artifact_path(ctx.goal.id, red["artifact_id"])).status ==
               403
    end

    test "serves markup as a download, never inline", %{goal: goal, worktree: worktree} do
      # A second decision on another goal, offering HTML and SVG candidates.
      other = Shoestring.Test.CobblerHelpers.create_goal!()
      dir = Path.join(worktree, ".shoestring/decisions/sheet")
      File.write!(Path.join(dir, "page.html"), "<script>alert(1)</script>")
      File.write!(Path.join(dir, "art.svg"), "<svg xmlns='http://www.w3.org/2000/svg'/>")

      write_candidates!(worktree,
        file: %{
          "id" => "sheet",
          "options" => [
            %{
              "key" => "page",
              "label" => "Page",
              "file" => ".shoestring/decisions/sheet/page.html",
              "media_type" => "text/html"
            },
            %{
              "key" => "art",
              "label" => "Art",
              "file" => ".shoestring/decisions/sheet/art.svg",
              "media_type" => "image/svg+xml"
            }
          ]
        }
      )

      _ = goal
      run_sheets!(other, worktree)
      [decision] = Decisions.list(goal_ids: [other.id])

      for key <- ["page", "art"] do
        conn =
          get(local(build_conn()), artifact_path(other.id, option(decision, key)["artifact_id"]))

        assert conn.status == 200
        assert [disposition] = get_resp_header(conn, "content-disposition")
        assert disposition =~ "attachment"
        assert get_resp_header(conn, "content-security-policy") == ["sandbox; default-src 'none'"]
      end
    end
  end

  # --------------------------------------------------------------------------
  # Attention: items, the count, the card
  # --------------------------------------------------------------------------

  describe "attention" do
    test "the decision is an item of the session in place of the stopped dispatch", ctx do
      items = Attention.items(ctx.session)
      assert [%{kind: :decision} = item] = items
      assert item.id == "decision-" <> ctx.decision.id
      assert item.dispatch_id == ctx.builder.id

      assert item.choices == [
               {"red", "A red sheet"},
               {"green", "A green sheet"},
               {"blue", "A blue sheet"},
               {"reject", "None of these"}
             ]

      assert item.note =~ "nothing decides this on a timer"
      assert Attention.items(session().session) == []
    end

    test "the needs-you count includes decisions, also of goals no session owns", ctx do
      before = Attention.count()
      assert before >= 1

      other = Shoestring.Test.CobblerHelpers.create_goal!()
      write_candidates!(ctx.worktree)
      run_sheets!(other, ctx.worktree)
      assert Attention.count() == before + 1

      [loose] = Decisions.list(goal_ids: [other.id])

      assert {:ok, _} =
               Attention.answer_decision(nil, loose.id, "red", "human:test")

      assert Attention.count() == before
    end

    test "answering from another session is refused", ctx do
      other = session()

      assert {:error, :decision_not_found} =
               Attention.answer_decision(other.session, ctx.decision.id, "red", "human:test")

      assert %Decision{state: "pending"} = Decisions.get(ctx.decision.id)
    end

    test "the card shows each candidate and offers none of these only when allowed", ctx do
      html =
        render_component(&AttentionComponents.card/1, item: Attention.decision_item(ctx.decision))

      doc = LazyHTML.from_fragment(html)
      card = "#decision-#{ctx.decision.id}"

      for key <- ["red", "green", "blue"] do
        src = artifact_path(ctx.goal.id, option(ctx.decision, key)["artifact_id"])

        assert LazyHTML.query(doc, "#{card}-option-#{key} img[src='#{src}']") |> Enum.count() ==
                 1

        assert LazyHTML.query(doc, "#{card}-choose-#{key}") |> Enum.count() == 1
      end

      assert LazyHTML.query(doc, "#{card}-reject") |> Enum.count() == 1

      closed = %{ctx.decision | allow_reject: false}
      html = render_component(&AttentionComponents.card/1, item: Attention.decision_item(closed))
      assert LazyHTML.query(LazyHTML.from_fragment(html), "#{card}-reject") |> Enum.count() == 0
    end
  end

  # --------------------------------------------------------------------------
  # Answering on the web
  # --------------------------------------------------------------------------

  describe "the Sessions page" do
    test "answers a pending decision with one click and the plan is queued again",
         %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      card = "#decision-#{ctx.decision.id}"

      assert has_element?(view, "#needs-you #needs-decision-#{ctx.decision.id}")
      assert has_element?(view, "#dispatch-#{ctx.builder.id} #{card}")
      assert has_element?(view, "#nav-needs-you")

      view |> element("#{card}-choose-green") |> render_click()

      assert %Decision{state: "answered", answer_key: "green", decided_by: "human:" <> _} =
               Decisions.get(ctx.decision.id)

      refute has_element?(view, card)
      assert render(view) =~ "Chosen. The next tasks start with it."

      # The executor resumes: its execution job is queued again.
      assert Repo.exists?(
               from j in Oban.Job,
                 where:
                   j.worker == "Shoestring.Cobbler.PlanExecutionWorker" and
                     fragment("json_extract(?, '$.goal_id')", j.args) == ^ctx.goal.id
             )
    end

    test "none of these asks for the note first", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      card = "#decision-#{ctx.decision.id}"

      view |> element("#{card}-reject") |> render_click()
      assert has_element?(view, "#{card}-reject-form")

      view |> form("#{card}-reject-form", %{"note" => "  "}) |> render_submit()
      assert has_element?(view, "#{card}-reject-error")
      assert %Decision{state: "pending"} = Decisions.get(ctx.decision.id)

      view |> form("#{card}-reject-form", %{"note" => "None fit the story."}) |> render_submit()

      assert %Decision{state: "rejected", answer_note: "None fit the story."} =
               Decisions.get(ctx.decision.id)
    end
  end

  describe "the goal page" do
    test "shows the decision inline, answers it, then shows who answered", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/cobbler/goals/#{ctx.goal.id}")
      card = "#decision-#{ctx.decision.id}"
      assert has_element?(view, "#cobbler-plan-decisions #{card}")

      # The header says the plan waits for a person, not "Unknown goal state."
      assert has_element?(view, "#cobbler-goal-status[data-status='plan-needs-user']")

      view |> element("#{card}-choose-blue") |> render_click()

      assert has_element?(
               view,
               "#plan-decision-#{ctx.decision.id}-state[data-state='answered']",
               "Chosen: blue"
             )
    end
  end
end
