defmodule ShoestringWeb.ConfigurationAccessibilityTest do
  use ShoestringWeb.ConnCase, async: false

  import Shoestring.ConfigurationFixtures
  alias Shoestring.AgentProfiles

  test "product pages expose a skip destination and a named page heading", %{conn: conn} do
    for path <- ["/usage", "/agents", "/agents/new", "/settings"] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#skip-to-content[href='#product-main']", "Skip to content")
      assert has_element?(view, "#product-main[tabindex='-1'][aria-labelledby='page-heading']")
      assert has_element?(view, "#page-heading[tabindex='-1']")
    end
  end

  test "library actions and role groups carry their agent and role context", %{conn: conn} do
    {:ok, agent} = AgentProfiles.create(agent_attrs())
    {:ok, view, _} = live(conn, "/agents")
    assert has_element?(view, "#edit-#{agent.id}[aria-label='Edit #{agent.name}']")
    assert has_element?(view, "#duplicate-#{agent.id}[aria-label='Duplicate #{agent.name}']")

    {:ok, edit, _} = live(conn, "/agents/builder/edit")
    assert has_element?(edit, "#role-editor-0 legend", "Coordinator")
    assert has_element?(edit, "#role-editor-1 legend", "Worker")
  end

  test "invalid fields identify their errors and submit focuses the summary", %{conn: conn} do
    {:ok, view, _} = live(conn, "/agents/new")

    view
    |> form("#agent-form", agent: form_attrs(agent_attrs(%{"slug" => "Bad Slug"})))
    |> render_submit()

    assert has_element?(view, "#agent-errors[tabindex='-1'][role='alert']")
    assert_push_event(view, "ss:focus", %{id: "agent-errors"})

    assert has_element?(
             view,
             "#agent_slug[aria-invalid='true'][aria-describedby='agent_slug-errors']"
           )

    assert has_element?(view, "#agent_slug-errors", "lowercase")
    refute has_element?(view, "#agent_name[aria-invalid='true']")

    view |> form("#agent-form", agent: %{slug: "fixed-slug"}) |> render_change()
    refute has_element?(view, "#agent_slug[aria-invalid='true']")
    refute has_element?(view, "#agent_slug-errors")
  end

  test "role add and removal announce the change and retain a keyboard destination", %{conn: conn} do
    {:ok, view, _} = live(conn, "/agents/new")
    view |> element("#add-role") |> render_click()
    assert_push_event(view, "ss:focus", %{id: "agent_roles_3_name"})
    assert has_element?(view, "#agent-team-status[role='status']", "Role 4 added")
    assert has_element?(view, "#role-editor-3 legend", "Role 4")

    view |> element("#remove-role-3") |> render_click()
    assert_push_event(view, "ss:focus", %{id: "add-role"})
    assert has_element?(view, "#agent-team-status", "Role 4 removed")
    refute has_element?(view, "#role-editor-3")
  end

  test "settings help remains associated when an error is shown", %{conn: conn} do
    {:ok, view, _} = live(conn, "/settings")

    assert has_element?(
             view,
             "#settings_codex_models[aria-describedby='settings-codex-help']"
           )

    view |> form("#settings-form", settings: %{codex_models: "invalid!"}) |> render_submit()

    assert_push_event(view, "ss:focus", %{id: "settings-errors"})

    assert has_element?(
             view,
             "#settings_codex_models[aria-invalid='true'][aria-describedby='settings-codex-help settings_codex_models-errors']"
           )

    assert has_element?(view, "#settings_codex_models-errors")
    assert has_element?(view, "#settings-codex-help", "installed CLI")
  end

  test "a newly saved flash has a native keyboard-operable dismiss button", %{conn: conn} do
    {:ok, view, _} = live(conn, "/settings")
    view |> form("#settings-form", settings: %{refresh_seconds: "0"}) |> render_submit()
    assert has_element?(view, "#flash-info [data-flash-close][phx-click]")
    refute has_element?(view, "#flash-info[phx-click]")

    view |> element("#flash-info [data-flash-close]") |> render_click()
    refute has_element?(view, "#flash-info")
  end
end
