defmodule ShoestringWeb.ModelPickerLiveTest do
  use ShoestringWeb.ConnCase, async: false
  alias Shoestring.{Agents, ModelCatalog}

  setup do
    {:ok, _} =
      ModelCatalog.refresh("codex",
        lister: fn _, _ ->
          {:ok,
           %{
             models: [
               %{
                 "model" => "test-sol",
                 "display_name" => "Test Sol",
                 "efforts" => ["low", "high"]
               },
               %{"model" => "test-luna", "display_name" => "Test Luna", "efforts" => ["medium"]}
             ],
             skipped: 0
           }}
        end
      )

    {:ok, _} =
      ModelCatalog.refresh("opencode",
        lister: fn _, _ ->
          {:ok,
           %{
             models: [
               %{"model" => "openai/test-sol", "display_name" => "Test Sol"},
               %{"model" => "anthropic/test-opus", "display_name" => "Test Opus"}
             ],
             skipped: 0
           }}
        end
      )

    {:ok, _} = ModelCatalog.enable("opencode", "openai/test-sol")
    :ok
  end

  test "model search uses display names, keeps the draft, and saves exact IDs and efforts", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/agents/new?kind=implementer")

    view
    |> form("#agent-form", %{
      agent: %{name: "Draft worker", slug: "draft-worker", model: "test-sol", effort: "high"},
      model_query: "Sol"
    })
    |> render_change()

    assert has_element?(view, "#agent_model option[value='test-sol']", "Test Sol — Codex")
    refute has_element?(view, "#agent_model option[value='test-luna']")
    assert has_element?(view, "#agent_name[value='Draft worker']")
    view |> form("#agent-form") |> render_submit()
    assert_redirect(view, "/agents/draft-worker")

    assert %{provider: "codex", model: "test-sol", effort: "high"} =
             Agents.get_by_slug("draft-worker")
  end

  test "searching a new form does not surface unrelated validation errors", %{conn: conn} do
    {:ok, view, _} = live(conn, "/agents/new?kind=implementer")

    view
    |> form("#agent-form", %{model_query: "Sol"})
    |> render_change(%{"_target" => ["model_query"]})

    refute has_element?(view, "#agent-errors")
    assert has_element?(view, "#agent-model-matches", "1 matching model")
    assert has_element?(view, "#agent_model option[value='test-sol']")
    refute has_element?(view, "#agent_model option[value='test-luna']")
  end

  test "changing model resets effort and an external catalog update preserves the draft", %{
    conn: conn
  } do
    {:ok, agent} =
      Agents.create(%{
        name: "Worker",
        slug: "effort-worker",
        kind: "implementer",
        provider: "codex",
        model: "test-sol",
        effort: "high"
      })

    {:ok, view, _} = live(conn, "/agents/#{agent.slug}/edit")

    view
    |> form("#agent-form", agent: %{name: "Unsaved", model: "test-luna"})
    |> render_change(%{"_target" => ["agent", "model"]})

    assert has_element?(view, "#agent_effort option:first-child[value='']", "Provider default")
    refute has_element?(view, "#agent_effort option[selected][value='high']")
    assert has_element?(view, "#agent_effort option[value='medium']")
    refute has_element?(view, "#agent_effort option[value='high']")
    {:ok, _} = ModelCatalog.add("codex", "added-from-cli")
    send(view.pid, :model_catalog_check)
    assert has_element?(view, "#agent_model option[value='added-from-cli']")
    assert has_element?(view, "#agent_name[value='Unsaved']")
    assert has_element?(view, "#agent_model option[selected][value='test-luna']")
    assert has_element?(view, "#agent-catalog-notice")
    view |> form("#agent-form") |> render_submit()
    assert %{model: "test-luna", effort: nil} = Agents.get(agent.id)
  end

  test "opencode routes stay distinct and disabled models are not offered", %{conn: conn} do
    {:ok, view, _} = live(conn, "/agents/new?kind=implementer")

    view
    |> form("#agent-form",
      agent: %{provider: "opencode", name: "Routed worker", slug: "routed-worker"}
    )
    |> render_change(%{"_target" => ["agent", "provider"]})

    assert has_element?(view, "#agent_model option[value='openai/test-sol']", "opencode · openai")
    refute has_element?(view, "#agent_model option[value='anthropic/test-opus']")
    assert has_element?(view, "#agent-opencode-note")
    view |> form("#agent-form") |> render_submit()

    assert %{provider: "opencode", model: "openai/test-sol", effort: nil} =
             Agents.get_by_slug("routed-worker")
  end

  test "no matches keeps the selected model and unavailable models cannot be newly selected", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/agents/new?kind=implementer")

    view
    |> form("#agent-form", %{model_query: "no-such-model", agent: %{model: "test-sol"}})
    |> render_change()

    assert has_element?(view, "#agent-model-empty")
    assert has_element?(view, "#agent_model option[selected][value='test-sol']")

    {:ok, _} =
      ModelCatalog.refresh("codex", lister: fn _, _ -> {:ok, %{models: [], skipped: 0}} end)

    send(view.pid, :model_catalog_check)

    assert has_element?(
             view,
             "#agent_model option[selected][value='test-sol']",
             "no longer reported"
           )

    view
    |> form("#agent-form", agent: %{name: "Unavailable", slug: "unavailable"})
    |> render_submit()

    assert has_element?(view, "#agent-errors", "no longer reported")
    assert Agents.get_by_slug("unavailable") == nil
  end
end
