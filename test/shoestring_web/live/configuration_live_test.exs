defmodule ShoestringWeb.ConfigurationLiveTest do
  use ShoestringWeb.ConnCase, async: false
  import Shoestring.ConfigurationFixtures
  alias Shoestring.AgentProfiles

  test "product navigation contains exactly three destinations", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#nav-usage[aria-current=page]")
    assert has_element?(view, "#nav-agents[href='/agents']")
    assert has_element?(view, "#nav-settings[href='/settings']")
    refute has_element?(view, "#product-nav a:nth-child(4)")
  end

  test "create UI configuration resolves through CLI context", %{conn: conn} do
    {:ok, view, _} = live(conn, "/agents/new")
    refute has_element?(view, "#agent-errors")
    view |> form("#agent-form", agent: form_attrs(agent_attrs())) |> render_submit()
    assert_redirect(view, "/agents")
    assert {:ok, snapshot} = AgentProfiles.snapshot("builder")
    assert snapshot["configuration"]["name"] == "Builder"
    assert length(snapshot["configuration"]["roles"]) == 3
  end

  test "edit and duplicate have independent history", %{conn: conn} do
    {:ok, agent} = AgentProfiles.create(agent_attrs())
    {:ok, view, _} = live(conn, "/agents/builder/edit")
    view |> form("#agent-form", agent: %{purpose: "Edited purpose"}) |> render_submit()
    assert_redirect(view, "/agents")
    assert AgentProfiles.get(agent.id).revision == 2
    {:ok, duplicate, _} = live(conn, "/agents/builder/duplicate")
    duplicate |> form("#agent-form") |> render_submit()
    assert_redirect(duplicate, "/agents")
    copy = AgentProfiles.get_by_slug("builder-copy")
    assert copy.id != agent.id
    assert copy.revision == 1
    assert copy.purpose == "Edited purpose"
    assert {:ok, original} = AgentProfiles.snapshot_by_id(agent.id, 1)
    assert original["configuration"]["purpose"] == agent_attrs()["purpose"]
  end

  test "role add/remove and provider change preserve draft", %{conn: conn} do
    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{
        "claude_models" => "claude-choice",
        "codex_models" => "codex-choice"
      })

    {:ok, view, _} = live(conn, "/agents/new")
    view |> form("#agent-form", agent: %{name: "Draft name"}) |> render_change()
    view |> element("#add-role") |> render_click()
    assert has_element?(view, "#agent_name[value='Draft name']")
    assert has_element?(view, "#remove-role-3")
    refute has_element?(view, "#remove-role-0")
    view |> element("#remove-role-3") |> render_click()
    refute has_element?(view, "#remove-role-3")

    view
    |> form("#agent-form", agent: %{roles: %{"0" => %{provider: "codex"}}})
    |> render_change(%{"_target" => ["agent", "roles", "0", "provider"]})

    assert has_element?(view, "#agent_roles_0_model option[selected][value='codex-choice']")
    assert has_element?(view, "#agent_name[value='Draft name']")
  end

  test "stale edit preserves draft and reload recovers", %{conn: conn} do
    {:ok, agent} = AgentProfiles.create(agent_attrs())
    {:ok, view, _} = live(conn, "/agents/builder/edit")
    {:ok, _} = AgentProfiles.update(agent, %{"purpose" => "Concurrent change"})
    view |> form("#agent-form", agent: %{name: "Unsaved name"}) |> render_submit()
    assert has_element?(view, "#agent-errors", "agent changed")
    assert has_element?(view, "#agent_name[value='Unsaved name']")
    assert AgentProfiles.get(agent.id).purpose == "Concurrent change"
    view |> element("#reload-agent") |> render_click()
    assert has_element?(view, "#agent_purpose[value='Concurrent change']")
    refute has_element?(view, "#agent-errors")
  end

  test "settings save default and model catalog; stale settings cannot replace them", %{
    conn: conn
  } do
    {:ok, agent} = AgentProfiles.create(agent_attrs())
    {:ok, view, _} = live(conn, "/settings")

    view
    |> form("#settings-form",
      settings: %{
        default_agent_id: agent.id,
        codex_models: "default\nconfigured-model",
        refresh_seconds: "0"
      }
    )
    |> render_submit()

    assert AgentProfiles.settings().default_agent_id == agent.id
    assert AgentProfiles.catalog()["codex"] == ["default", "configured-model"]
    {:ok, _} = AgentProfiles.save_settings(AgentProfiles.settings(), %{"refresh_seconds" => 300})
    view |> form("#settings-form", settings: %{refresh_seconds: "60"}) |> render_submit()
    assert has_element?(view, "#settings-errors", "settings changed")
    assert AgentProfiles.settings().refresh_seconds == 300
    view |> element("#reload-settings") |> render_click()
    assert has_element?(view, "#settings_refresh_seconds option[selected][value='300']")
  end

  test "invalid fields remain editable and missing agent returns to library", %{conn: conn} do
    {:ok, view, _} = live(conn, "/agents/new")

    view
    |> form("#agent-form", agent: form_attrs(agent_attrs(%{"slug" => "Bad Slug"})))
    |> render_submit()

    assert has_element?(view, "#agent_slug[value='Bad Slug']")
    assert has_element?(view, "#agent-errors")
    assert AgentProfiles.list() == []
    assert {:error, {:live_redirect, %{to: "/agents"}}} = live(conn, "/agents/missing/edit")
    {:ok, settings, _} = live(conn, "/settings")
    settings |> form("#settings-form", settings: %{codex_models: "invalid!"}) |> render_submit()
    assert has_element?(settings, "#settings-errors")
    assert AgentProfiles.settings().codex_models == "default"
  end
end
