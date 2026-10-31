defmodule Shoestring.AgentsTest do
  @moduledoc """
  Reusable agents (iteration 16 package T) and the teams that compose them.
  """
  use Shoestring.DataCase, async: false
  import Shoestring.ConfigurationFixtures

  alias Shoestring.{Agents, AgentProfiles, ModelCatalog, Repo}
  alias Shoestring.Agents.Agent
  alias Shoestring.Cobbler.ExecutionProfile

  setup do
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-sol")
    {:ok, _} = ModelCatalog.add("claude", "opus")
    :ok
  end

  defp roles(worker_model \\ "gpt-6-luna") do
    [
      %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
      %{"name" => "Worker", "provider" => "codex", "model" => worker_model},
      %{"name" => "Reviewer", "provider" => "claude", "model" => "opus"}
    ]
  end

  defp team!(slug, roles) do
    {:ok, team} = AgentProfiles.create(agent_attrs(%{"slug" => slug, "roles" => roles}))
    team
  end

  test "every role of a saved team is an agent; the same job and model share one" do
    one = team!("one", roles())
    two = team!("two", roles())

    by_name = fn team -> Map.new(team.roles, &{&1.name, Agents.get(&1.agent_id)}) end

    assert %Agent{kind: "coordinator", provider: "claude", model: "opus"} =
             by_name.(one)["Coordinator"]

    assert %Agent{kind: "implementer", model: "gpt-6-luna", max_minutes: nil} =
             by_name.(one)["Worker"]

    # Coordinator and Reviewer use the same model but are different jobs.
    refute by_name.(one)["Coordinator"].id == by_name.(one)["Reviewer"].id
    assert by_name.(one) == by_name.(two)
    assert Repo.aggregate(Agent, :count) == 3

    assert Enum.map(Agents.used_by(by_name.(one)["Worker"]), & &1.slug) == ["one", "two"]
  end

  test "editing an agent saves a new revision of every team that uses it; running work keeps its own" do
    one = team!("one", roles())
    two = team!("two", roles())
    worker = Agents.get(Enum.find(one.roles, &(&1.name == "Worker")).agent_id)
    {:ok, before} = AgentProfiles.snapshot("one")

    binding = %{
      "profile_id" => one.id,
      "revision" => before["revision"],
      "digest" => before["digest"],
      "role" => "Worker"
    }

    assert {:ok, %{"model" => "gpt-6-luna"}} = ExecutionProfile.resolve(binding, Repo)

    assert {:ok, %Agent{model: "gpt-6-sol", max_minutes: 45}} =
             Agents.update(worker, %{"model" => "gpt-6-sol", "max_minutes" => 45})

    for slug <- ["one", "two"] do
      {:ok, now} = AgentProfiles.snapshot(slug)
      assert now["revision"] == 2
      worker_role = Enum.find(now["configuration"]["roles"], &(&1["name"] == "Worker"))

      assert %{"model" => "gpt-6-sol", "max_minutes" => 45, "agent_id" => id} = worker_role
      assert id == worker.id
    end

    # The revision work started with still resolves, unchanged.
    assert {:ok, %{"model" => "gpt-6-luna"}} = ExecutionProfile.resolve(binding, Repo)
    assert AgentProfiles.get(two.id).revision == 2
  end

  test "a role takes an agent of its own job; the agent's model wins over the role's" do
    team = team!("one", roles())
    reviewer = Enum.find(team.roles, &(&1.name == "Reviewer")).agent_id
    worker = Enum.find(team.roles, &(&1.name == "Worker")).agent_id

    wrong =
      team.roles
      |> Enum.map(&%{"name" => &1.name, "agent_id" => &1.agent_id})
      |> Enum.map(fn
        %{"name" => "Worker"} = role -> %{role | "agent_id" => reviewer}
        role -> role
      end)

    assert {:error, changeset} = AgentProfiles.update(team, %{"roles" => wrong})
    assert inspect(changeset.changes.roles) =~ "choose an Implementer agent"

    named =
      Enum.map(team.roles, fn role ->
        %{"name" => role.name, "agent_id" => role.agent_id, "model" => "ignored"}
      end)

    assert {:ok, team} = AgentProfiles.update(team, %{"roles" => named})
    assert Enum.find(team.roles, &(&1.agent_id == worker)).model == "gpt-6-luna"
  end

  test "an agent's own rules: a coordinator's limit is the grant's turns, minutes within 1..240" do
    base = %{
      "name" => "Explorer",
      "slug" => "explorer",
      "kind" => "explorer",
      "provider" => "codex",
      "model" => "gpt-6-luna"
    }

    assert {:ok, %Agent{max_minutes: nil}} = Agents.create(base)

    for {attrs, field} <- [
          {%{"kind" => "coordinator", "slug" => "c", "max_minutes" => 30}, :max_minutes},
          {%{"slug" => "e2", "max_minutes" => 0}, :max_minutes},
          {%{"slug" => "e3", "max_minutes" => 241}, :max_minutes},
          {%{"slug" => "e4", "model" => "not-listed"}, :model},
          {%{"slug" => "explorer"}, :slug},
          {%{"slug" => "e5", "kind" => "pilot"}, :kind}
        ] do
      assert {:error, changeset} = Agents.create(Map.merge(base, attrs))
      assert Map.has_key?(errors_on(changeset), field), inspect({attrs, errors_on(changeset)})
    end
  end

  test "a stale edit of an agent is refused and changes no team" do
    team = team!("one", roles())
    worker = Agents.get(Enum.find(team.roles, &(&1.name == "Worker")).agent_id)
    {:ok, _} = Agents.update(worker, %{"max_minutes" => 30})

    assert {:error, changeset} = Agents.update(worker, %{"max_minutes" => 90})
    assert "agent changed; reload before saving" in errors_on(changeset).lock_version
    assert AgentProfiles.get(team.id).revision == 2
    assert Agents.get(worker.id).max_minutes == 30
  end
end
