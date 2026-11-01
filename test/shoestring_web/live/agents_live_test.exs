defmodule ShoestringWeb.AgentsLiveTest do
  @moduledoc "The Agents page (iteration 16 package T): visibility and editing of reusable agents."
  use ShoestringWeb.ConnCase, async: false
  import Shoestring.ConfigurationFixtures

  alias Shoestring.{Agents, AgentProfiles, ModelCatalog}

  setup do
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
    {:ok, _} = ModelCatalog.add("claude", "opus")

    {:ok, team} =
      AgentProfiles.create(
        agent_attrs(%{
          "roles" => [
            %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
            %{"name" => "Worker", "provider" => "codex", "model" => "gpt-6-luna"},
            %{"name" => "Reviewer", "provider" => "claude", "model" => "opus"}
          ]
        })
      )

    worker = Agents.get(Enum.find(team.roles, &(&1.name == "Worker")).agent_id)
    %{team: team, worker: worker}
  end

  test "each agent shows its job, model, limit, sandbox and the teams that use it", %{
    conn: conn,
    worker: worker
  } do
    {:ok, view, _} = live(conn, "/agents")
    assert has_element?(view, "#agents-coordinator")
    assert has_element?(view, "#agents-implementer #agent-#{worker.slug}")
    refute has_element?(view, "#agents-explorer")

    assert has_element?(view, "#agent-#{worker.slug}-limit", "No limit of its own")
    assert has_element?(view, "#agent-#{worker.slug}-can", "Write its own worktree")
    assert has_element?(view, "#agent-#{worker.slug}-cannot", "Use the network")
    assert has_element?(view, "#agent-#{worker.slug}-can", "Propose lessons")
    assert has_element?(view, "#agent-#{worker.slug}-teams a[href='/teams/builder/edit']")
    assert has_element?(view, "#agent-#{worker.slug}-total", "0")

    {:ok, show, _} = live(conn, "/agents/#{worker.slug}")
    assert has_element?(show, "#agent-#{worker.slug}-teams", "Builder")
  end

  test "editing an agent's limit saves it and a new revision of its team", %{
    conn: conn,
    team: team,
    worker: worker
  } do
    {:ok, view, _} = live(conn, "/agents/#{worker.slug}/edit")
    view |> form("#agent-form", agent: %{max_minutes: "45"}) |> render_submit()
    {path, flash} = assert_redirect(view)
    assert path == "/agents/#{worker.slug}"
    assert flash["info"] =~ "new revision of Builder"

    assert Agents.get(worker.id).max_minutes == 45
    assert AgentProfiles.get(team.id).revision == 2
    {:ok, snapshot} = AgentProfiles.snapshot("builder")

    assert Enum.find(snapshot["configuration"]["roles"], &(&1["name"] == "Worker"))["max_minutes"] ==
             45

    {:ok, show, _} = live(conn, path)
    assert has_element?(show, "#agent-#{worker.slug}-limit", "At most 45 minutes")

    # Emptied, it has no limit of its own again.
    {:ok, view, _} = live(conn, "/agents/#{worker.slug}/edit")
    view |> form("#agent-form", agent: %{max_minutes: ""}) |> render_submit()
    assert Agents.get(worker.id).max_minutes == nil
  end

  test "an implementer's sandbox is widened from its page; Codex is told it cannot limit hosts",
       %{
         conn: conn,
         team: team,
         worker: worker
       } do
    {:ok, view, _} = live(conn, "/agents/#{worker.slug}/edit")
    assert has_element?(view, "#agent-permissions")

    view
    |> form("#agent-form", agent: %{network_hosts: "github.com"})
    |> render_submit()

    assert has_element?(view, "#agent-errors", "Codex cannot limit its network")
    assert Agents.get(worker.id).network_hosts == []

    view
    |> form("#agent-form", agent: %{network_hosts: "*", write_paths: "/data/out\n/data/cache"})
    |> render_submit()

    assert {"/agents/" <> _, _} = assert_redirect(view)
    saved = Agents.get(worker.id)
    assert saved.write_paths == ["/data/out", "/data/cache"]
    assert saved.network_hosts == ["*"]
    assert AgentProfiles.get(team.id).revision == 2

    {:ok, show, _} = live(conn, "/agents/#{worker.slug}")
    assert has_element?(show, "#agent-#{worker.slug}-can", "Also read and write /data/out")
    assert has_element?(show, "#agent-#{worker.slug}-can", "any host")
    refute has_element?(show, "#agent-#{worker.slug}-cannot", "Use the network")

    # The form shows what was saved, one per line.
    {:ok, edit, _} = live(conn, "/agents/#{worker.slug}/edit")
    assert edit |> element("#agent_write_paths") |> render() =~ "/data/out\n/data/cache"

    # Commands it may run without asking: listed, refused when compound,
    # removed by deleting their line; teams keep no copy.
    {:ok, _} = Agents.allow_command(worker.slug, "/bin/zsh -lc 'npm test'")
    {:ok, edit, _} = live(conn, "/agents/#{worker.slug}/edit")
    assert edit |> element("#agent_allowed_commands") |> render() =~ "npm test"
    {:ok, show, _} = live(conn, "/agents/#{worker.slug}")

    assert has_element?(
             show,
             "#agent-#{worker.slug}-can",
             "Run without asking you, outside its sandbox: /bin/zsh -lc 'npm test'"
           )

    edit
    |> form("#agent-form", agent: %{allowed_commands: "make && make install"})
    |> render_submit()

    assert has_element?(edit, "#agent-errors", "one plain command")

    edit |> form("#agent-form", agent: %{allowed_commands: ""}) |> render_submit()
    assert {"/agents/" <> _, _} = assert_redirect(edit)
    assert Agents.get(worker.id).allowed_commands == []

    # Jobs other than implementer have no such section.
    coordinator = Enum.find(Agents.list(), &(&1.kind == "coordinator"))
    {:ok, other, _} = live(conn, "/agents/#{coordinator.slug}/edit")
    refute has_element?(other, "#agent-permissions")
  end

  test "an explorer is created from the page; a coordinator takes no time limit", %{conn: conn} do
    {:ok, view, _} = live(conn, "/agents/new?kind=explorer")

    view
    |> form("#agent-form",
      agent: %{
        name: "Quick explorer",
        slug: "quick-explorer",
        kind: "explorer",
        provider: "codex",
        model: "gpt-6-luna",
        max_minutes: "10",
        notes: "For narrow lookups."
      }
    )
    |> render_submit()

    assert %{kind: "explorer", max_minutes: 10, notes: "For narrow lookups."} =
             Agents.get_by_slug("quick-explorer")

    {:ok, view, _} = live(conn, "/agents/new?kind=coordinator")
    # The limit field is not offered for a coordinator.
    assert has_element?(view, "#agent_max_minutes[disabled]")

    view
    |> form("#agent-form",
      agent: %{name: "C", slug: "c2", provider: "claude", model: "opus", notes: ""}
    )
    |> render_submit()

    assert Agents.get_by_slug("c2").max_minutes == nil

    # An explorer may not propose lessons unless switched on.
    explorer = Agents.get_by_slug("quick-explorer")
    assert explorer.may_propose_lessons == false
    {:ok, show, _} = live(conn, "/agents/quick-explorer")
    assert has_element?(show, "#agent-quick-explorer-cannot", "Propose lessons")
    {:ok, view, _} = live(conn, "/agents/quick-explorer/edit")
    view |> form("#agent-form", agent: %{may_propose_lessons: "true"}) |> render_submit()
    assert Agents.get_by_slug("quick-explorer").may_propose_lessons == true
  end
end
