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

  defp run_json!(args) do
    Mix.Tasks.Shoestring.Agents.run(args)
    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  defp roles(snapshot),
    do: Enum.map(snapshot["configuration"]["roles"], &{&1["name"], &1["provider"], &1["model"]})

  test "create, set-role and default save revisions the execution binding accepts" do
    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{"claude_models" => "default\nopus"})

    created = run_json!(["create", "builder", "--worker", "claude:opus", "--default"])

    assert %{"revision" => 1, "configuration" => %{"slug" => "builder", "name" => "builder"}} =
             created

    assert roles(created) == [{"Coordinator", "claude", "opus"}, {"Worker", "claude", "opus"}]
    assert {:ok, ^created} = AgentProfiles.default_snapshot()

    changed = run_json!(["set-role", "builder", "Coordinator", "claude:default"])
    assert changed["revision"] == 2
    assert roles(changed) == [{"Coordinator", "claude", "default"}, {"Worker", "claude", "opus"}]

    added = run_json!(["set-role", "builder", "Reviewer", "claude:opus"])
    assert added["revision"] == 3
    assert {"Reviewer", "claude", "opus"} in roles(added)

    # The Worker role binds for execution: an explicit model, not "default".
    assert {:ok, %{"model" => "opus", "role" => "Worker", "revision" => 3}} =
             Shoestring.Cobbler.ExecutionProfile.resolve(
               %{
                 "profile_id" => added["profile_id"],
                 "revision" => 3,
                 "digest" => added["digest"],
                 "role" => "Worker"
               },
               Repo
             )

    {:ok, _} = AgentProfiles.create(agent_attrs(%{"slug" => "other", "name" => "Other"}))
    assert %{"configuration" => %{"slug" => "other"}} = run_json!(["default", "other"])
    assert {:ok, %{"configuration" => %{"slug" => "other"}}} = AgentProfiles.default_snapshot()
  end

  test "create and set-role refuse unlisted models and malformed roles without saving" do
    assert_raise Mix.Error, ~r/models from the current provider configuration|model/, fn ->
      Mix.Tasks.Shoestring.Agents.run(["create", "builder", "--worker", "claude:opus"])
    end

    for args <- [
          ["create", "builder"],
          ["create", "builder", "--worker", "opus"],
          ["create", "Bad Name", "--worker", "claude:default"],
          ["set-role", "missing", "Worker", "claude:default"],
          ["default", "missing"]
        ] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Shoestring.Agents.run(args) end
    end

    assert AgentProfiles.list() == []
  end

  # Base (9a0f1af): `create --worker opencode:...` without --coordinator was
  # refused ("opencode runs plan tasks only"). Any harness may coordinate now;
  # a role still refuses a harness that cannot do its job.
  test "an opencode worker may coordinate itself, but cannot review" do
    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{
        "claude_models" => "default fixture-claude",
        "opencode_models" => "opencode/fixture-free"
      })

    snapshot = run_json!(["create", "oc", "--worker", "opencode:opencode/fixture-free"])

    assert [
             %{"name" => "Coordinator", "provider" => "opencode"},
             %{"name" => "Worker", "provider" => "opencode", "model" => "opencode/fixture-free"}
           ] = snapshot["configuration"]["roles"]

    assert_raise Mix.Error, ~r/opencode cannot review yet; use Claude Code or Codex/, fn ->
      Mix.Tasks.Shoestring.Agents.run([
        "set-role",
        "oc",
        "Reviewer",
        "opencode:opencode/fixture-free"
      ])
    end

    snapshot =
      run_json!([
        "create",
        "oc-claude",
        "--worker",
        "opencode:opencode/fixture-free",
        "--coordinator",
        "claude:fixture-claude"
      ])

    assert [
             %{"name" => "Coordinator", "provider" => "claude"},
             %{"name" => "Worker", "provider" => "opencode", "model" => "opencode/fixture-free"}
           ] = snapshot["configuration"]["roles"]
  end
end
