defmodule Mix.Tasks.Shoestring.ModelsTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.AgentProfiles

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  defp run_json!(args) do
    Mix.Tasks.Shoestring.Models.run(args)
    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  test "add appends a model once and list reads the same catalogue" do
    assert %{"claude" => ["default"], "codex" => ["default"]} = run_json!(["list"])

    assert %{"claude" => ["default", "opus"]} = run_json!(["add", "claude", "opus"])
    assert %{"claude" => ["default", "opus"]} = run_json!(["add", "claude", "opus"])
    assert %{"codex" => ["default", "gpt-5.5"]} = run_json!(["add", "codex", "gpt-5.5"])

    # opencode starts with no model: there is no default to fall back to.
    assert %{"opencode" => ["opencode/glm-5"]} =
             run_json!(["add", "opencode", "opencode/glm-5"])

    assert AgentProfiles.catalog() == %{
             "claude" => ["default", "opus"],
             "codex" => ["default", "gpt-5.5"],
             "opencode" => ["opencode/glm-5"]
           }
  end

  test "unknown providers, unsafe names and bad arguments change nothing" do
    for args <- [
          ["add", "gemini", "pro"],
          ["add", "claude", "two words"],
          ["add", "claude", "-rf"],
          ["add", "opencode", "glm-5"],
          ["add", "claude"],
          ["remove", "claude", "opus"],
          ["list", "--all"],
          ["refresh", "gemini"],
          ["refresh", "claude", "codex"],
          ["show", "gemini"],
          ["enable", "claude", "never-recorded"]
        ] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Shoestring.Models.run(args) end
    end

    assert AgentProfiles.catalog() == %{
             "claude" => ["default"],
             "codex" => ["default"],
             "opencode" => []
           }
  end

  describe "refresh" do
    setup do
      Application.put_env(:shoestring, :model_lister, fn
        "codex", _opts ->
          {:ok, %{models: [%{"model" => "gpt-6-luna", "efforts" => ["low", "max"]}], skipped: 1}}

        "opencode", _opts ->
          {:ok, %{models: [%{"model" => "opencode/glm-5"}], skipped: 0}}

        "claude", _opts ->
          {:error, :binary_missing}
      end)

      on_exit(fn -> Application.delete_env(:shoestring, :model_lister) end)
    end

    test "records what each harness reports, says what failed, and enables only Claude/Codex" do
      assert [claude, codex, opencode] = run_json!(["refresh"])
      assert claude == %{"provider" => "claude", "error" => "binary_missing"}

      assert %{
               "provider" => "codex",
               "new" => ["gpt-6-luna"],
               "enabled" => ["gpt-6-luna"],
               "skipped" => 1
             } = codex

      assert %{"provider" => "opencode", "new" => ["opencode/glm-5"], "enabled" => []} = opencode

      assert_receive {:mix_shell, :error, ["Asking Claude Code for its models..."]}
      assert_receive {:mix_shell, :error, ["Claude Code: its CLI is not on PATH"]}

      assert_receive {:mix_shell, :error,
                      ["Codex: 1 models, 1 new, 1 enabled, 0 no longer offered, 1 skipped" <> _]}

      assert %{"codex" => ["default", "gpt-6-luna"], "opencode" => []} = run_json!(["list"])

      assert [
               %{
                 "model" => "opencode/glm-5",
                 "enabled" => false,
                 "available" => true,
                 "source" => "live"
               }
             ] =
               run_json!(["show", "opencode"])

      assert %{"opencode" => ["opencode/glm-5"]} =
               run_json!(["enable", "opencode", "opencode/glm-5"])

      assert %{"opencode" => []} = run_json!(["disable", "opencode", "opencode/glm-5"])
    end

    test "exits 1 when no harness answered" do
      assert Mix.Tasks.Shoestring.Models.run(["refresh", "claude"]) == 1
      assert_receive {:mix_shell, :info, [json]}
      assert [%{"error" => "binary_missing"}] = Jason.decode!(json)
    end
  end
end
