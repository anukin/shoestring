defmodule ShoestringWeb.ModelCatalogLiveTest do
  use ShoestringWeb.ConnCase, async: false
  alias Shoestring.{AgentProfiles, Agents, ModelCatalog, Repo}
  alias Shoestring.CLI.Commands.Models

  setup do
    test = self()

    lister = fn provider, _ ->
      send(test, {:listed, provider})

      {:ok,
       %{
         models: [
           %{"model" => "openai/test-sol", "display_name" => "Test Sol"},
           %{"model" => "anthropic/test-opus", "display_name" => "Test Opus"}
         ],
         skipped: 0
       }}
    end

    Application.put_env(:shoestring, :model_lister, lister)
    on_exit(fn -> Application.delete_env(:shoestring, :model_lister) end)
    {:ok, _} = ModelCatalog.refresh("opencode")
    %{lister: lister}
  end

  test "search, enable, disable and manual entry share the CLI catalog and keep settings drafts",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/settings")
    row = "#model-rows [data-model='openai/test-sol']"
    assert has_element?(view, row <> " button", "Enable")
    assert ModelCatalog.enabled("opencode") == []
    view |> form("#settings-form", settings: %{lessons_space_mb: "42"}) |> render_change()
    view |> form("#model-search-form", model_search: %{query: "openai sol"}) |> render_change()
    assert has_element?(view, row)
    refute has_element?(view, "#model-rows [data-model='anthropic/test-opus']")
    view |> element(row <> " button") |> render_click()
    assert has_element?(view, row <> " button", "Disable")
    assert has_element?(view, "#settings_lessons_space_mb[value='42']")
    assert AgentProfiles.settings().lessons_space_mb == 200
    Models.run(["list"], %{shell: Mix.Shell.Process, with_repo: fn fun -> fun.(Repo) end})
    assert_receive {:mix_shell, :info, [json]}
    assert Jason.decode!(json)["opencode"] == ["openai/test-sol"]
    view |> element(row <> " button") |> render_click()
    assert ModelCatalog.enabled("opencode") == []

    view
    |> form("#manual-model-form", manual: %{provider: "opencode", model: "invalid"})
    |> render_submit()

    assert has_element?(view, "#model-error")
    assert has_element?(view, "#manual_model[value='invalid']")

    view
    |> form("#manual-model-form", manual: %{provider: "opencode", model: "openai/custom"})
    |> render_submit()

    assert ModelCatalog.enabled("opencode") == ["openai/custom"]
    view |> form("#settings-form") |> render_submit()
    assert AgentProfiles.settings().lessons_space_mb == 42
    assert AgentProfiles.catalog()["opencode"] == ["openai/custom"]
  end

  test "a CLI change reaches an open page without replacing its draft", %{conn: conn} do
    {:ok, view, _} = live(conn, "/settings")
    view |> form("#settings-form", settings: %{lessons_space_mb: "43"}) |> render_change()

    Models.run(["enable", "opencode", "openai/test-sol"], %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end
    })

    send(view.pid, :model_catalog_check)
    assert has_element?(view, "#model-rows [data-model='openai/test-sol'] button", "Disable")
    assert has_element?(view, "#settings_lessons_space_mb[value='43']")
    assert has_element?(view, "#model-notice")
    # A stale general-settings form must not undo the CLI's enable action.
    view |> form("#settings-form") |> render_submit()
    assert has_element?(view, "#settings-errors", "settings changed")
    assert ModelCatalog.enabled("opencode") == ["openai/test-sol"]
  end

  test "a model action keeps dirty advanced fields without overwriting unrelated external settings",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/settings")

    view
    |> form("#settings-form",
      settings: %{codex_models: "default\nmanual-draft", lessons_space_mb: "44"}
    )
    |> render_change()

    {:ok, _} = AgentProfiles.save_settings(AgentProfiles.settings(), %{refresh_seconds: 300})
    view |> element("#model-rows [data-model='openai/test-sol'] button") |> render_click()
    assert has_element?(view, "#settings_codex_models", "manual-draft")
    assert has_element?(view, "#settings_lessons_space_mb[value='44']")
    view |> form("#settings-form") |> render_submit()
    assert AgentProfiles.settings().refresh_seconds == 300
    assert AgentProfiles.settings().lessons_space_mb == 44
    assert "manual-draft" in AgentProfiles.catalog()["codex"]
    assert ModelCatalog.enabled("opencode") == ["openai/test-sol"]
  end

  test "refresh is asynchronous and does not enable opencode models", %{conn: conn} do
    {:ok, view, _} = live(conn, "/settings")
    view |> element("#refresh-models-opencode") |> render_click()
    render_async(view)
    assert_received {:listed, "opencode"}
    assert ModelCatalog.enabled("opencode") == []
    assert has_element?(view, "#model-rows [data-model='openai/test-sol'] button", "Enable")
    Application.put_env(:shoestring, :model_lister, fn _, _ -> {:error, :timeout} end)
    view |> element("#refresh-models-opencode") |> render_click()
    render_async(view)
    assert has_element?(view, "#model-error")
    assert has_element?(view, "#model-rows [data-model='openai/test-sol']")
  end

  test "an in-use standalone agent protects its model in both editors", %{conn: conn} do
    {:ok, _} = ModelCatalog.enable("opencode", "openai/test-sol")

    {:ok, agent} =
      Agents.create(%{
        name: "Worker",
        slug: "picker-worker",
        kind: "implementer",
        provider: "opencode",
        model: "openai/test-sol"
      })

    {:ok, view, _} = live(conn, "/settings")
    view |> element("#model-rows [data-model='openai/test-sol'] button") |> render_click()
    assert has_element?(view, "#model-error", agent.slug)
    assert ModelCatalog.enabled("opencode") == ["openai/test-sol"]
    view |> form("#settings-form", settings: %{opencode_models: ""}) |> render_submit()
    assert has_element?(view, "#settings-errors", "models still used")
    assert ModelCatalog.enabled("opencode") == ["openai/test-sol"]
  end
end
