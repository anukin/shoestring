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
