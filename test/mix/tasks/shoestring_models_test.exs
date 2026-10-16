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

    assert AgentProfiles.catalog() == %{
             "claude" => ["default", "opus"],
             "codex" => ["default", "gpt-5.5"]
           }
  end

  test "unknown providers, unsafe names and bad arguments change nothing" do
    for args <- [
          ["add", "gemini", "pro"],
          ["add", "claude", "two words"],
          ["add", "claude", "-rf"],
          ["add", "claude"],
          ["remove", "claude", "opus"],
          ["list", "--all"]
        ] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Shoestring.Models.run(args) end
    end

    assert AgentProfiles.catalog() == %{"claude" => ["default"], "codex" => ["default"]}
  end
end
