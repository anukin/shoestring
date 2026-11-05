defmodule Shoestring.CLI.ModelPickerTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{AgentProfiles, ModelCatalog, Repo}
  alias Shoestring.CLI.Commands.Setup
  alias Shoestring.CLI.Commands.Models

  setup do
    for {provider, models} <- [
          {"claude", [%{"model" => "opus", "display_name" => "Opus"}]},
          {"codex",
           [%{"model" => "test-sol", "display_name" => "Test Sol", "efforts" => ["low", "high"]}]},
          {"opencode", [%{"model" => "openai/test-sol", "display_name" => "Test Sol"}]}
        ] do
      {:ok, _} =
        ModelCatalog.refresh(provider,
          lister: fn _, _ -> {:ok, %{models: models, skipped: 0}} end
        )
    end

    context = %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end,
      interactive?: fn -> true end,
      readiness: fn -> Map.new(~w(claude codex opencode), &{&1, %{"readiness" => "ready"}}) end
    }

    %{context: context}
  end

  defp run(context, answers) do
    for answer <- answers, do: send(self(), {:mix_shell_input, :prompt, answer})

    Setup.run(
      ["--skip-refresh", "--coordinator", "claude:opus", "--reviewer", "none", "--yes"],
      context
    )

    assert_receive {:mix_shell, :info, [json]}
    snapshot = Jason.decode!(json)["agent"]
    Enum.find(snapshot["configuration"]["roles"], &(&1["name"] == "Worker"))
  end

  test "search narrows numbered choices, recovers from a bad number and saves effort", %{
    context: context
  } do
    worker = run(context, ["sol", "99", "1", "high"])
    assert worker["provider"] == "codex"
    assert worker["model"] == "test-sol"
    assert worker["effort"] == "high"

    assert_received {:mix_shell, :error,
                     ["That choice is not available. Choose a listed number or search again."]}

    assert_received {:mix_shell, :error,
                     [
                       "  2  Test Sol — opencode · openai [disabled; enable to select]\n     openai/test-sol"
                     ]}

    assert ModelCatalog.enabled("opencode") == []
  end

  test "an ambiguous name requires selection and explicit enable of the opencode route", %{
    context: context
  } do
    worker = run(context, ["sol", "2", "y"])
    assert worker["provider"] == "opencode"
    assert worker["model"] == "openai/test-sol"
    refute Map.has_key?(worker, "effort")
    assert ModelCatalog.enabled("opencode") == ["openai/test-sol"]
    assert AgentProfiles.catalog()["opencode"] == ["openai/test-sol"]
    assert_received {:mix_shell, :prompt, ["Enable Test Sol — opencode · openai? [y/N] "]}
  end

  test "declining enable keeps the opencode route disabled and allows another choice", %{
    context: context
  } do
    worker = run(context, ["openai", "1", "n", "sol", "1", "default"])
    assert worker["provider"] == "codex"
    assert worker["model"] == "test-sol"
    assert ModelCatalog.enabled("opencode") == []
  end

  test "no matches can be cleared without losing earlier choices", %{context: context} do
    worker = run(context, ["missing-name", "/all", "codex:test-sol", "low"])
    assert worker["provider"] == "codex"
    assert worker["effort"] == "low"
    assert_received {:mix_shell, :error, ["No matches. Type another search or /all."]}
  end

  test "model management accepts short searches for enable and disable", %{context: context} do
    for answer <- ["openai", "1"], do: send(self(), {:mix_shell_input, :prompt, answer})
    Models.run(["enable", "opencode"], context)
    assert ModelCatalog.enabled("opencode") == ["openai/test-sol"]
    for answer <- ["openai", "1"], do: send(self(), {:mix_shell_input, :prompt, answer})
    Models.run(["disable"], context)
    assert ModelCatalog.enabled("opencode") == []
  end

  test "model management never prompts without a terminal", %{context: context} do
    context = %{context | interactive?: fn -> false end}

    assert_raise Shoestring.CLI.Refusal, ~r/Without a terminal pass PROVIDER MODEL/, fn ->
      Models.run(["enable"], context)
    end

    refute_received {:mix_shell, :prompt, _}
    assert ModelCatalog.enabled("opencode") == []
  end
end
