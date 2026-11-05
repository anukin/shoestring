defmodule Shoestring.ModelChoicesTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{AgentProfiles, Agents, ModelCatalog}

  defp refresh(provider, models),
    do:
      ModelCatalog.refresh(provider, lister: fn _, _ -> {:ok, %{models: models, skipped: 0}} end)

  test "configured identifiers remain visible before any discovery" do
    assert %{provider: "codex", model: "default", source: "configured"} =
             Enum.find(ModelCatalog.choices(), &(&1.provider == "codex"))

    assert ModelCatalog.choices(executable: true) == []
  end

  test "search distinguishes routes, excludes disabled and unavailable rows and filters capabilities" do
    {:ok, _} = refresh("codex", [%{"model" => "test-sol", "display_name" => "Friendly Sol"}])

    {:ok, _} =
      refresh("opencode", [%{"model" => "openai/test-sol", "display_name" => "Friendly Sol"}])

    assert [%{provider: "codex"}] = ModelCatalog.choices(query: "friendly SOL")

    assert [%{provider: "opencode", route: "openai", enabled: false}] =
             ModelCatalog.choices(query: "openai sol", include_disabled: true)

    {:ok, _} = ModelCatalog.enable("opencode", "openai/test-sol")
    assert [%{provider: "opencode"}] = ModelCatalog.choices(query: "openai sol")
    refute Enum.any?(ModelCatalog.choices(capability: :review), &(&1.provider == "opencode"))
    {:ok, _} = refresh("codex", [])
    assert ModelCatalog.choices(provider: "codex", executable: true) == []

    assert [%{available: false, enabled: true}] =
             ModelCatalog.choices(provider: "codex", executable: true, include_unavailable: true)

    assert "test-sol" in AgentProfiles.catalog()["codex"]
  end

  test "unavailable choices cannot be newly assigned but existing agents remain editable" do
    {:ok, _} = refresh("codex", [%{"model" => "test-sol"}])

    attrs = %{
      name: "Existing",
      slug: "existing-model",
      kind: "implementer",
      provider: "codex",
      model: "test-sol"
    }

    {:ok, agent} = Agents.create(attrs)
    {:ok, _} = refresh("codex", [])
    assert {:ok, edited} = Agents.update(agent, %{notes: "Kept for later"})
    assert edited.model == "test-sol"
    assert {:error, changeset} = Agents.create(%{attrs | slug: "new-model"})
    assert {message, _} = changeset.errors[:model]
    assert message =~ "no longer reported"
    refute ModelCatalog.selectable?("codex", "test-sol")
  end
end
