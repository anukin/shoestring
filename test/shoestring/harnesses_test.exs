defmodule Shoestring.HarnessesTest do
  @moduledoc """
  What each harness can do and which vendor a model belongs to. Every
  capability the table claims must be the module the real path uses.
  Hermetic; no provider.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.Review.Configuration
  alias Shoestring.Harnesses

  test "each harness declares only the jobs it has a path for" do
    assert Harnesses.capabilities("claude") == [:coordinate, :plan, :implement, :review, :explore]
    assert Harnesses.capabilities("codex") == [:coordinate, :implement, :review, :explore]
    assert Harnesses.capabilities("opencode") == [:coordinate, :implement]
    assert Harnesses.capabilities("unknown") == []
    refute Harnesses.supports?("opencode", :review)
    assert Harnesses.module("opencode", :review) == :error
  end

  test "an implement capability is the adapter Elves run for that harness" do
    for id <- Harnesses.ids(), Harnesses.supports?(id, :implement) do
      assert {:ok, adapter} = Harnesses.module(id, :implement)
      assert adapter.identity().provider == id
    end
  end

  test "a review capability is the adapter cross-review loads for that harness" do
    for id <- Harnesses.ids(), Harnesses.supports?(id, :review) do
      assert {:ok, module} = Harnesses.module(id, :review)

      assert {:ok, {:required, %{adapter: ^module}}} =
               Configuration.load(%{agent_profile: %{"provider" => "fake"}},
                 review_config: [enabled: true, adapter: String.to_atom(id), model: "m"]
               )
    end
  end

  test "roles need the capability of the job Shoestring gives them" do
    assert Harnesses.role_capability("Coordinator") == :coordinate
    assert Harnesses.role_capability("Worker") == :implement
    assert Harnesses.role_capability("Reviewer") == :review
    assert Harnesses.role_capability("Scribe") == nil
    assert Harnesses.offering(:review) == "Claude Code or Codex"
    assert Harnesses.offering(:coordinate) == "Claude Code, Codex or opencode"
    assert Harnesses.offering(:plan) == "Claude Code"
  end

  describe "vendor" do
    test "Claude Code and Codex run their own vendor's models" do
      assert Harnesses.vendor("claude", "opus") == "anthropic"
      assert Harnesses.vendor("codex", "gpt-6-luna") == "openai"
    end

    test "an opencode model is its first-party provider's, or its family's" do
      for {model, vendor} <- [
            {"openai/gpt-mini", "openai"},
            {"openai/gpt-mini#high", "openai"},
            {"anthropic/claude-sonnet", "anthropic"},
            {"openrouter/anthropic/claude-sonnet", "anthropic"},
            {"amazon-bedrock/anthropic.claude-sonnet", "anthropic"},
            {"opencode/glm-5.3-flash-free", "zhipu"},
            {"opencode-go/deepseek-v4.1-flash", "deepseek"},
            {"openrouter/qwen/qwen3-coder", "alibaba"},
            {"azure/o4-mini", "openai"},
            {"opencode/nemotron-3-ultra-free", "nvidia"},
            {"opencode/minimax-m3", "minimax"},
            {"opencode/mimo-v2.6-flash-free", "xiaomi"}
          ] do
        assert Harnesses.vendor("opencode", model) == vendor, model
      end
    end

    test "a model whose vendor cannot be told has none" do
      assert Harnesses.vendor("opencode", "opencode/big-pickle") == nil
      assert Harnesses.vendor("opencode", "no-provider") == nil
      assert Harnesses.vendor("opencode", nil) == nil
      assert Harnesses.vendor("fake", "anything") == nil
    end
  end
end
