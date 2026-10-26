defmodule Shoestring.ModelCatalogTest do
  @moduledoc """
  Recording what harnesses report, the enable policy, and per-model efforts.
  Listers are injected; no harness CLI runs.
  """
  use Shoestring.DataCase, async: true

  alias Shoestring.{AgentProfiles, ConfigurationFixtures, ModelCatalog}
  alias Shoestring.Cobbler.ExecutionProfile

  @now ~U[2026-10-25 12:00:00.000000Z]

  defp model(id, extra \\ %{}) do
    Map.merge(
      %{
        "model" => id,
        "display_name" => id,
        "efforts" => [],
        "default_effort" => nil,
        "default" => false,
        "resolves_to" => nil
      },
      extra
    )
  end

  defp lister(models, skipped \\ 0),
    do: fn _provider, _opts -> {:ok, %{models: models, skipped: skipped}} end

  defp refresh!(provider, models, now \\ @now) do
    assert {:ok, report} = ModelCatalog.refresh(provider, lister: lister(models), now: now)
    report
  end

  test "new Claude and Codex models are enabled; opencode models are only recorded" do
    report = refresh!("codex", [model("gpt-6-luna"), model("gpt-6.1-sol", %{"default" => true})])

    assert %{
             "provider" => "codex",
             "listed" => 2,
             "new" => ["gpt-6-luna", "gpt-6.1-sol"],
             "enabled" => ["gpt-6-luna", "gpt-6.1-sol"],
             "unavailable" => []
           } = report

    assert ModelCatalog.enabled("codex") == ["default", "gpt-6-luna", "gpt-6.1-sol"]

    report = refresh!("opencode", [model("opencode/glm-5"), model("openai/gpt-5")])
    assert report["new"] == ["openai/gpt-5", "opencode/glm-5"]
    assert report["enabled"] == []
    assert ModelCatalog.enabled("opencode") == []

    assert %{source: "live", available: true, fetched_at: @now} =
             ModelCatalog.entry("opencode", "opencode/glm-5")

    assert {:ok, :enabled} = ModelCatalog.enable("opencode", "opencode/glm-5")
    assert AgentProfiles.catalog()["opencode"] == ["opencode/glm-5"]
  end

  test "a model no longer reported is unavailable but stays enabled; a disabled one stays disabled" do
    refresh!("claude", [model("opus"), model("sonnet"), model("haiku")])
    assert {:ok, :disabled} = ModelCatalog.disable("claude", "haiku")

    later = DateTime.add(@now, 3600)
    report = refresh!("claude", [model("opus"), model("haiku")], later)

    assert report["new"] == []
    assert report["unavailable"] == ["sonnet"]
    assert ModelCatalog.enabled("claude") == ["default", "opus", "sonnet"]
    assert %{available: false, fetched_at: @now} = ModelCatalog.entry("claude", "sonnet")
    assert %{available: true, fetched_at: ^later} = ModelCatalog.entry("claude", "opus")

    refresh!("claude", [model("opus"), model("sonnet"), model("haiku")], later)
    assert %{available: true} = ModelCatalog.entry("claude", "sonnet")
    refute "haiku" in ModelCatalog.enabled("claude")
  end

  test "a failed listing changes nothing" do
    refresh!("codex", [model("gpt-6-luna")])
    failing = fn _provider, _opts -> {:error, :timeout} end

    assert ModelCatalog.refresh("codex", lister: failing) == {:error, :timeout}
    assert [%{model: "gpt-6-luna", available: true}] = ModelCatalog.entries("codex")
    assert ModelCatalog.enabled("codex") == ["default", "gpt-6-luna"]
  end

  test "manual models are recorded and never marked unavailable by a listing" do
    assert {:ok, :ok} = ModelCatalog.add("codex", "gpt-private")
    assert %{source: "manual"} = ModelCatalog.entry("codex", "gpt-private")
    refresh!("codex", [model("gpt-6-luna")])

    assert %{source: "manual", available: true} = ModelCatalog.entry("codex", "gpt-private")
    assert ModelCatalog.add("opencode", "glm-5") == {:error, :invalid_model}
    assert ModelCatalog.enable("codex", "never-seen") == {:error, :unknown_model}
  end

  test "a model a saved agent uses cannot be disabled" do
    refresh!("claude", [model("opus")])

    roles = [
      %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
      %{"name" => "Worker", "provider" => "claude", "model" => "opus"}
    ]

    {:ok, _} = AgentProfiles.create(ConfigurationFixtures.agent_attrs(%{"roles" => roles}))
    assert ModelCatalog.disable("claude", "opus") == {:error, {:in_use, ["builder"]}}
    assert "opus" in ModelCatalog.enabled("claude")
  end

  describe "efforts" do
    test "a role may pin the efforts the model reported, else the provider's set" do
      refresh!("codex", [
        model("gpt-6-luna", %{"efforts" => ~w(low medium high xhigh max)}),
        model("gpt-6-sol", %{"efforts" => ~w(low ultra)})
      ])

      assert AgentProfiles.efforts("codex", "gpt-6-luna") == ~w(low medium high xhigh max)
      assert AgentProfiles.efforts("codex", "unlisted") == AgentProfiles.efforts()["codex"]
      assert AgentProfiles.efforts(nil, nil) == []

      worker = fn model, effort ->
        [
          %{"name" => "Coordinator", "provider" => "claude", "model" => "default"},
          %{"name" => "Worker", "provider" => "codex", "model" => model, "effort" => effort}
        ]
      end

      create = fn roles, slug ->
        AgentProfiles.create(
          ConfigurationFixtures.agent_attrs(%{"roles" => roles, "slug" => slug, "name" => slug})
        )
      end

      assert {:ok, _} = create.(worker.("gpt-6-luna", "max"), "luna-max")
      assert {:ok, _} = create.(worker.("gpt-6-sol", "ultra"), "sol-ultra")
      assert {:error, changeset} = create.(worker.("gpt-6-sol", "high"), "sol-high")
      assert inspect(errors_on(changeset)) =~ "choose an effort this model accepts"
    end

    test "a revision saved before a listing narrowed the model's efforts still resolves" do
      {:ok, _} =
        AgentProfiles.save_settings(AgentProfiles.settings(), %{
          "claude_models" => "default claude-haiku-4-5-20251001"
        })

      roles = [
        %{"name" => "Coordinator", "provider" => "claude", "model" => "default"},
        %{
          "name" => "Worker",
          "provider" => "claude",
          "model" => "claude-haiku-4-5-20251001",
          "effort" => "low"
        }
      ]

      {:ok, agent} = AgentProfiles.create(ConfigurationFixtures.agent_attrs(%{"roles" => roles}))
      refresh!("claude", [model("claude-haiku-4-5-20251001")])
      assert AgentProfiles.efforts("claude", "claude-haiku-4-5-20251001") == []

      {:ok, snapshot} = AgentProfiles.snapshot_by_id(agent.id)
      binding = Map.put(Map.take(snapshot, ~w(profile_id revision digest)), "role", "Worker")
      assert {:ok, %{"effort" => "low"}} = ExecutionProfile.resolve(binding, Shoestring.Repo)
    end
  end

  test "a provider list holds up to 64 models" do
    many = Enum.map_join(1..64, " ", &"model-#{&1}")

    assert {:ok, _} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{"codex_models" => many})

    too_many = many <> " model-65"

    assert {:error, changeset} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{"codex_models" => too_many})

    assert inspect(errors_on(changeset)) =~ "1–64"
  end
end
