defmodule ShoestringWeb.SessionsLiveTest do
  @moduledoc """
  The Sessions pages: the list and its days setting, a session's agents and
  dispatches, the feed and its filters, live refresh, and the links in from
  the Agents and run pages. Hermetic: fixture records only.
  """
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query
  import Shoestring.SessionsFixtures

  alias Shoestring.{AgentProfiles, Repo}
  alias Shoestring.Conversations.Conversation
  alias Shoestring.Dispatches.Dispatch
  alias Shoestring.Grants.Grant

  setup do
    ctx = session()
    builder = dispatch_fixture(ctx, "implement", "builder", "Make add return the sum")

    worker_event(builder.goal_id, "command", %{
      "codex-app-server:item_id" => "call_1",
      "codex-app-server:command" => "python3 -m pytest -q",
      "codex-app-server:exit_code" => 0
    })

    worker_event(builder.goal_id, "output", %{"codex-app-server:text" => "The tests pass now."})
    Map.put(ctx, :builder, builder)
  end

  defp age!(session, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds)

    for schema <- [Grant, Conversation, Dispatch] do
      Repo.update_all(from(r in schema, where: r.session_id == ^session),
        set: [inserted_at: at, updated_at: at]
      )
    end
  end

  describe "the list" do
    test "lists the session and links to its page", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions")
      assert has_element?(view, "#nav-sessions[aria-current=page]")
      assert has_element?(view, "#session-#{ctx.session} a[href='/sessions/#{ctx.session}']")
      assert has_element?(view, "#session-#{ctx.session}", "1 dispatch")
      assert has_element?(view, "#session-days[value='7']")
    end

    test "the days field saves the setting and hides older sessions", %{conn: conn} = ctx do
      age!(ctx.session, 3 * 86_400)
      {:ok, view, _} = live(conn, "/sessions")
      assert has_element?(view, "#session-#{ctx.session}")

      view |> element("#sessions-days-form") |> render_change(%{"days" => "2"})
      assert AgentProfiles.settings().session_days == 2
      refute has_element?(view, "#session-#{ctx.session}")
      assert has_element?(view, "#sessions-hidden", "1 older session is hidden")

      view |> element("#sessions-days-form") |> render_change(%{"days" => "0"})
      assert has_element?(view, "#session-days-error")
      assert AgentProfiles.settings().session_days == 2
    end

    test "Settings has the same setting", %{conn: conn} do
      {:ok, view, _} = live(conn, "/settings")
      assert has_element?(view, "#settings_session_days[value='7']")

      settings = AgentProfiles.settings()

      params = %{
        "settings" => %{
          "claude_models" => settings.claude_models,
          "codex_models" => settings.codex_models,
          "opencode_models" => settings.opencode_models,
          "refresh_seconds" => settings.refresh_seconds,
          "lessons_space_mb" => settings.lessons_space_mb,
          "parallel_tasks" => settings.parallel_tasks,
          "session_days" => "30"
        }
      }

      view |> element("#settings-form") |> render_submit(params)
      assert AgentProfiles.settings().session_days == 30
    end
  end

  describe "a session" do
    test "the agent with live work is open, with its dispatch and feed", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")

      assert has_element?(view, "#agent-lead", "Lead")
      assert has_element?(view, "#agent-builder[aria-current=true]")
      assert has_element?(view, "#agent-scout", "no dispatches")
      assert has_element?(view, "#dispatch-#{ctx.builder.id}.ss-open", "Make add return the sum")
      assert has_element?(view, "#feed .ss-feed-command", "python3 -m pytest -q")
      assert has_element?(view, "#feed .ss-feed-command", "exit 0")
      assert has_element?(view, "#feed .ss-feed-message", "The tests pass now.")
      assert has_element?(view, "#feed .ss-feed-step")
      assert has_element?(view, "#feed-live")
    end

    test "a filter narrows the feed to one kind", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      view |> element("#feed-filter-command") |> render_click()

      assert has_element?(view, "#feed-filter-command[aria-pressed=true]")
      assert has_element?(view, "#feed .ss-feed-command")
      refute has_element?(view, "#feed .ss-feed-message")
      refute has_element?(view, "#feed .ss-feed-step")
    end

    test "picking the coordinator shows its turns, tools and messages", %{conn: conn} = ctx do
      conversation_event(ctx.conversation, "conversation.message.human", %{
        "message_id" => "m1",
        "text" => "Please fix add()"
      })

      conversation_event(ctx.conversation, "conversation.tool.called", %{
        "turn_id" => "t1",
        "call_id" => "call-1",
        "tool" => "dispatch"
      })

      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      view |> element("#agent-lead") |> render_click()

      assert_patch(view, "/sessions/#{ctx.session}?agent=lead")
      assert has_element?(view, "#agent-lead[aria-current=true]")
      assert has_element?(view, "#dispatch-coordinator")
      assert has_element?(view, "#feed .ss-feed-you", "Please fix add()")
      assert has_element?(view, "#feed .ss-feed-tool", "dispatch")
      assert has_element?(view, "#feed-filter-tool")
      refute has_element?(view, "#feed-filter-command")
    end

    test "a committed event refreshes the open feed", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      refute has_element?(view, "#feed", "git status")

      event =
        worker_event(ctx.builder.goal_id, "command", %{
          "codex-app-server:item_id" => "call_2",
          "codex-app-server:command" => "git status"
        })

      broadcast(event)
      # The page heard the open dispatch's goal and scheduled a refresh.
      assert :sys.get_state(view.pid).socket.assigns.refresh_pending
      send(view.pid, :refresh)
      assert has_element?(view, "#feed .ss-feed-command", "git status")
    end

    test "an unknown session goes back to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/sessions"}}} = live(conn, "/sessions/no-such")
    end
  end

  describe "what needs you" do
    setup ctx do
      {:ok, _} =
        Shoestring.Agents.create(%{
          "name" => "Builder",
          "slug" => "builder",
          "kind" => "implementer",
          "provider" => "codex",
          "model" => "gpt-6-luna"
        })

      Map.put(ctx, :ask, waiting_ask(ctx.builder))
    end

    test "an ask is listed at the top and answered on its dispatch: allow once",
         %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      card = "#ask-#{ctx.ask.id}"

      assert has_element?(
               view,
               "#needs-you #needs-ask-#{ctx.ask.id}",
               "Run outside its sandbox: npm ci"
             )

      assert has_element?(view, "#dispatch-#{ctx.builder.id} #{card}", "$ npm ci")
      assert has_element?(view, card, "nothing decides this on a timer")
      assert has_element?(view, "#{card}-allow-agent")
      assert has_element?(view, "#nav-needs-you", "1")

      view |> element("#{card}-allow") |> render_click()

      id = ctx.ask.id
      assert_receive {:permission_decision, ^id, :allow, nil}
      assert Repo.get(Shoestring.PermissionAsks.Ask, id).state == "allowed"
      refute has_element?(view, card)
      refute has_element?(view, "#needs-you")
      refute has_element?(view, "#nav-needs-you")
      assert render(view) =~ "Allowed once."
    end

    test "allow for this agent writes its rule", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      view |> element("#ask-#{ctx.ask.id}-allow-agent") |> render_click()

      id = ctx.ask.id
      assert_receive {:permission_decision, ^id, :allow, nil}
      assert Shoestring.Agents.get_by_slug("builder").allowed_commands == ["npm ci"]
    end

    test "deny with a reason asks for the reason, then tells the worker", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      card = "#ask-#{ctx.ask.id}"
      view |> element("#{card}-deny-reason") |> render_click()
      assert has_element?(view, "#{card}-reason-form")

      view
      |> element("#{card}-reason-form")
      |> render_submit(%{"ask" => ctx.ask.id, "note" => "  "})

      assert has_element?(view, "#{card}-reason-error")
      assert Repo.get(Shoestring.PermissionAsks.Ask, ctx.ask.id).state == "pending"

      view
      |> element("#{card}-reason-form")
      |> render_submit(%{"ask" => ctx.ask.id, "note" => "Use the lockfile cache."})

      id = ctx.ask.id
      assert_receive {:permission_decision, ^id, :deny, "Use the lockfile cache."}
      refute has_element?(view, card)
    end

    test "a plain deny tells the worker no reason", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      view |> element("#ask-#{ctx.ask.id}-deny") |> render_click()
      id = ctx.ask.id
      assert_receive {:permission_decision, ^id, :deny, nil}
    end

    test "a network ask offers allow for this run and deny, never allow for this agent",
         %{conn: conn} = ctx do
      network =
        waiting_ask(ctx.builder, %{
          kind: "network",
          provider: "claude",
          command: "registry.npmjs.org"
        })

      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      card = "#ask-#{network.id}"
      assert has_element?(view, "#{card}-allow", "Allow for this run")
      assert has_element?(view, "#{card}-deny")
      refute has_element?(view, "#{card}-allow-agent")
      refute has_element?(view, "#{card}-deny-reason")
    end

    test "an ask answered in the chat screen first is refused here", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")
      id = ctx.ask.id

      # The chat channel's own path, as `decide_ask` takes it.
      {:ok, _} = Shoestring.Attention.answer(ctx.session, id, "deny", "human:operator")
      assert_receive {:permission_decision, ^id, :deny, nil}

      view |> element("#ask-#{id}-allow") |> render_click()
      assert render(view) =~ "already answered"
      refute_receive {:permission_decision, ^id, _, _}, 100
      assert Repo.get(Shoestring.PermissionAsks.Ask, id).state == "denied"
    end

    test "a held dispatch is started from its card", %{conn: conn} = ctx do
      held = held_fixture(ctx)
      {:ok, view, _} = live(conn, "/sessions/#{ctx.session}?agent=scout&dispatch=#{held.id}")

      assert has_element?(view, "#needs-held-#{held.id}")
      assert has_element?(view, "#held-#{held.id}", "Start this held dispatch?")
      view |> element("#held-#{held.id}-start") |> render_click()

      assert Shoestring.Dispatches.Calls.get(held.id).confirmed_by ==
               Shoestring.CLI.WorkLoop.default_human()

      refute has_element?(view, "#held-#{held.id}")
      refute has_element?(view, "#needs-held-#{held.id}")
    end

    test "the nav's count is on every product page and follows answers", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, "/agents")
      assert has_element?(view, "#nav-sessions #nav-needs-you", "1")

      {:ok, _} = Shoestring.Attention.answer(ctx.session, ctx.ask.id, "allow", "human:operator")
      refute has_element?(view, "#nav-needs-you")
    end
  end

  describe "links in" do
    test "the Agents page's recent work opens the dispatch in its session", %{conn: conn} = ctx do
      {:ok, _} =
        Shoestring.Agents.create(%{
          "name" => "Builder",
          "slug" => "builder",
          "kind" => "implementer",
          "provider" => "codex",
          "model" => "gpt-6-luna"
        })

      {:ok, view, _} = live(conn, "/agents/builder")

      assert has_element?(
               view,
               "#work-#{ctx.builder.id}-session[href='/sessions/#{ctx.session}?agent=builder&dispatch=#{ctx.builder.id}']"
             )
    end
  end
end
