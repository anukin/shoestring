defmodule Mix.Tasks.Shoestring.AgentsTest do
  use Shoestring.DataCase, async: false
  import Shoestring.ConfigurationFixtures
  alias Shoestring.AgentProfiles

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  test "named, default and historical CLI output match saved snapshots" do
    {:ok, agent} = AgentProfiles.create(agent_attrs())
    {:ok, _} = AgentProfiles.update(agent, %{"purpose" => "Latest purpose"})

    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{"default_agent_id" => agent.id})

    for {args, revision} <- [
          {["show", "builder"], 2},
          {["show"], 2},
          {["show", "builder", "--revision", "1"], 1}
        ] do
      Mix.Tasks.Shoestring.Agents.run(args)
      assert_receive {:mix_shell, :info, [json]}
      {:ok, snapshot} = AgentProfiles.snapshot_by_id(agent.id, revision)
      assert Jason.decode!(json) == snapshot
    end

    Mix.Tasks.Shoestring.Agents.run(["list"])
    assert_receive {:mix_shell, :info, ["builder\tBuilder\trevision 2"]}
  end

  test "missing and invalid selections fail without starting work" do
    assert_raise Mix.Error, ~r/default agent/, fn -> Mix.Tasks.Shoestring.Agents.run(["show"]) end

    assert_raise Mix.Error, ~r/not found/, fn ->
      Mix.Tasks.Shoestring.Agents.run(["show", "missing"])
    end

    for args <- [["execute"], ["show", "builder", "--revision", "0"], ["list", "--revision", "1"]] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Shoestring.Agents.run(args) end
    end
  end
end
