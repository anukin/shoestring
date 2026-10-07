defmodule Shoestring.AgentProfilesTest do
  use Shoestring.DataCase, async: false
  import Shoestring.ConfigurationFixtures
  alias Shoestring.AgentProfiles
  alias Shoestring.AgentProfiles.Revision

  test "create and edit preserve exact old configuration after rename" do
    {:ok, agent} = AgentProfiles.create(agent_attrs())
    {:ok, original} = AgentProfiles.snapshot("builder")

    {:ok, edited} =
      AgentProfiles.update(agent, %{
        "name" => "Builder revised",
        "slug" => "revised",
        "instructions" => "New instructions"
      })

    assert edited.revision == 2
    assert {:ok, original} == AgentProfiles.snapshot_by_id(agent.id, 1)
    assert {:error, :not_found} == AgentProfiles.snapshot("builder")
    {:ok, current} = AgentProfiles.snapshot("revised")
    assert current["configuration"]["instructions"] == "New instructions"
    refute current["digest"] == original["digest"]
  end

  test "stale edit cannot overwrite or append a revision" do
    {:ok, agent} = AgentProfiles.create(agent_attrs())
    {:ok, _} = AgentProfiles.update(agent, %{"purpose" => "First update"})
    assert {:error, changeset} = AgentProfiles.update(agent, %{"purpose" => "Stale update"})
    assert "agent changed; reload before saving" in errors_on(changeset).revision
    assert Repo.aggregate(Revision, :count) == 2
    assert AgentProfiles.get(agent.id).purpose == "First update"
  end

  test "revision rows reject updates at the database boundary" do
    {:ok, agent} = AgentProfiles.create(agent_attrs())

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE agent_revisions SET number = 100 WHERE definition_id = ?",
               [agent.id]
             )

    assert Exception.message(error) =~ "immutable"
    assert {:ok, snapshot} = AgentProfiles.snapshot_by_id(agent.id, 1)
    assert snapshot["revision"] == 1
  end

  test "duplicate names, coordinator order and unsupported models are rejected" do
    for roles <- [
          [],
          [%{"name" => "Worker", "provider" => "codex", "model" => "default"}],
          [%{"name" => "Coordinator", "provider" => "claude", "model" => "invalid"}],
          [
            %{"name" => "Coordinator", "provider" => "claude", "model" => "default"},
            %{"name" => "Coordinator", "provider" => "codex", "model" => "default"}
          ]
        ] do
      assert {:error, _} = AgentProfiles.create(agent_attrs(%{"roles" => roles}))
    end

    assert Repo.aggregate(Revision, :count) == 0
  end

  test "configured models validate on create and provider-only update" do
    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{
        "claude_models" => "claude-choice",
        "codex_models" => "codex-choice"
      })

    assert {:error, _} = AgentProfiles.create(agent_attrs())

    attrs =
      agent_attrs(%{
        "roles" => [
          %{"name" => "Coordinator", "provider" => "claude", "model" => "claude-choice"}
        ]
      })

    {:ok, agent} = AgentProfiles.create(attrs)
    assert {:error, _} = AgentProfiles.update(agent, %{"roles" => [%{"provider" => "codex"}]})

    {:ok, edited} =
      AgentProfiles.update(agent, %{
        "roles" => [%{"name" => "Coordinator", "provider" => "codex", "model" => "codex-choice"}]
      })

    assert hd(edited.roles).provider == "codex"
  end

  test "settings preserve snapshots and reject stale saves and invalid input" do
    {:ok, agent} = AgentProfiles.create(agent_attrs())
    {:ok, original} = AgentProfiles.snapshot("builder")
    settings = AgentProfiles.settings()

    {:ok, saved} =
      AgentProfiles.save_settings(settings, %{
        "default_agent_id" => agent.id,
        "codex_models" => "new-model",
        "refresh_seconds" => "0"
      })

    assert {:ok, original} == AgentProfiles.default_snapshot()
    assert {:error, _} = AgentProfiles.save_settings(settings, %{"refresh_seconds" => 300})
    assert {:error, _} = AgentProfiles.update(agent, %{"purpose" => "Edit with removed model"})

    for attrs <- [
          %{"refresh_seconds" => "5"},
          %{"codex_models" => ""},
          %{"claude_models" => "bad model!"},
          %{"default_agent_id" => Ecto.UUID.generate()}
        ] do
      assert {:error, _} = AgentProfiles.save_settings(saved, attrs)
    end

    assert AgentProfiles.settings().refresh_seconds == 0
  end
end
