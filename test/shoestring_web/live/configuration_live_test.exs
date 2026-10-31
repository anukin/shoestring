defmodule ShoestringWeb.ConfigurationLiveTest do
  use ShoestringWeb.ConnCase, async: false
  import Shoestring.ConfigurationFixtures
  alias Shoestring.{Agents, AgentProfiles}

  test "product navigation has usage, teams, agents and settings", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#nav-usage[aria-current=page]")
    assert has_element?(view, "#nav-teams[href='/teams']")
    assert has_element?(view, "#nav-agents[href='/agents']")
    assert has_element?(view, "#nav-settings[href='/settings']")
    refute has_element?(view, "#product-nav a:nth-child(5)")
  end

  # The agents a team is made of.
  defp agents! do
    for {kind, provider} <- [
          {"coordinator", "claude"},
          {"implementer", "codex"},
          {"reviewer", "claude"}
        ],
        into: %{} do
      {:ok, agent} = Agents.ensure(kind, provider, "default", nil)
      {kind, agent.id}
    end
  end

  defp team_attrs(agents, overrides \\ %{}) do
    agent_attrs(overrides)
    |> Map.put("roles", [
      %{"name" => "Coordinator", "agent_id" => agents["coordinator"]},
      %{"name" => "Worker", "agent_id" => agents["implementer"]},
      %{"name" => "Reviewer", "agent_id" => agents["reviewer"]}
    ])
    |> form_attrs()
  end

  test "a team made in the page names an agent for each role and resolves for the CLI", %{
    conn: conn
  } do
    agents = agents!()
    {:ok, view, _} = live(conn, "/teams/new")
    refute has_element?(view, "#team-errors")
    # A new team starts with each job's first agent.
    assert has_element?(
             view,
             "#team_roles_0_agent_id option[selected][value='#{agents["coordinator"]}']"
           )

    view |> form("#team-form", team: team_attrs(agents)) |> render_submit()
    assert_redirect(view, "/teams")
    assert {:ok, snapshot} = AgentProfiles.snapshot("builder")
    assert snapshot["configuration"]["name"] == "Builder"

    assert Enum.map(snapshot["configuration"]["roles"], & &1["agent_id"]) ==
             [agents["coordinator"], agents["implementer"], agents["reviewer"]]

    {:ok, index, _} = live(conn, "/teams")
    assert has_element?(index, "#team-builder-role-Worker", "Implementer")
    assert has_element?(index, "#team-builder-role-Worker", "no limit of its own")
  end

  test "edit and duplicate have independent history", %{conn: conn} do
    {:ok, team} = AgentProfiles.create(agent_attrs())
    {:ok, view, _} = live(conn, "/teams/builder/edit")
    view |> form("#team-form", team: %{purpose: "Edited purpose"}) |> render_submit()
    assert_redirect(view, "/teams")
    assert AgentProfiles.get(team.id).revision == 2
    {:ok, duplicate, _} = live(conn, "/teams/builder/duplicate")
    duplicate |> form("#team-form") |> render_submit()
    assert_redirect(duplicate, "/teams")
    copy = AgentProfiles.get_by_slug("builder-copy")
    assert copy.id != team.id
    assert copy.revision == 1
    assert copy.purpose == "Edited purpose"
    assert {:ok, original} = AgentProfiles.snapshot_by_id(team.id, 1)
    assert original["configuration"]["purpose"] == agent_attrs()["purpose"]
  end

  test "adding a role offers an explorer; removing one keeps the draft", %{conn: conn} do
    agents = agents!()
    {:ok, explorer} = Agents.ensure("explorer", "codex", "default", nil)
    {:ok, view, _} = live(conn, "/teams/new")
    view |> form("#team-form", team: %{name: "Draft name"}) |> render_change()
    # The explorer agent exists, so a new team already has the role.
    assert has_element?(view, "#team_roles_1_name[value='Explorer']")
    assert has_element?(view, "#team_roles_1_agent_id option[value='#{explorer.id}']")
    refute has_element?(view, "#team_roles_1_agent_id option[value='#{agents["reviewer"]}']")
    view |> element("#remove-role-1") |> render_click()
    refute has_element?(view, "#team_roles_3_name")
    view |> element("#add-role") |> render_click()
    assert has_element?(view, "#team_roles_3_name[value='Explorer']")
    assert has_element?(view, "#team_name[value='Draft name']")
    refute has_element?(view, "#remove-role-0")
  end

  test "stale edit preserves draft and reload recovers", %{conn: conn} do
    {:ok, team} = AgentProfiles.create(agent_attrs())
    {:ok, view, _} = live(conn, "/teams/builder/edit")
    {:ok, _} = AgentProfiles.update(team, %{"purpose" => "Concurrent change"})
    view |> form("#team-form", team: %{name: "Unsaved name"}) |> render_submit()
    assert has_element?(view, "#team-errors", "agent changed")
    assert has_element?(view, "#team_name[value='Unsaved name']")
    assert AgentProfiles.get(team.id).purpose == "Concurrent change"
    view |> element("#reload-team") |> render_click()
    assert has_element?(view, "#team_purpose[value='Concurrent change']")
    refute has_element?(view, "#team-errors")
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
        opencode_models: "opencode/configured-free",
        refresh_seconds: "0"
      }
    )
    |> render_submit()

    assert AgentProfiles.settings().default_agent_id == agent.id
    assert AgentProfiles.catalog()["codex"] == ["default", "configured-model"]
    assert AgentProfiles.catalog()["opencode"] == ["opencode/configured-free"]
    {:ok, _} = AgentProfiles.save_settings(AgentProfiles.settings(), %{"refresh_seconds" => 300})
    view |> form("#settings-form", settings: %{refresh_seconds: "60"}) |> render_submit()
    assert has_element?(view, "#settings-errors", "settings changed")
    assert AgentProfiles.settings().refresh_seconds == 300
    view |> element("#reload-settings") |> render_click()
    assert has_element?(view, "#settings_refresh_seconds option[selected][value='300']")
  end

  test "invalid fields remain editable and a missing team returns to the library", %{conn: conn} do
    agents = agents!()
    {:ok, view, _} = live(conn, "/teams/new")

    view
    |> form("#team-form", team: team_attrs(agents, %{"slug" => "Bad Slug"}))
    |> render_submit()

    assert has_element?(view, "#team_slug[value='Bad Slug']")
    assert has_element?(view, "#team-errors")
    assert AgentProfiles.list() == []
    assert {:error, {:live_redirect, %{to: "/teams"}}} = live(conn, "/teams/missing/edit")
    {:ok, settings, _} = live(conn, "/settings")
    settings |> form("#settings-form", settings: %{codex_models: "invalid!"}) |> render_submit()
    assert has_element?(settings, "#settings-errors")
    assert AgentProfiles.settings().codex_models == "default"
  end
end
