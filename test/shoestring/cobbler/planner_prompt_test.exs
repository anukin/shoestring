defmodule Shoestring.Cobbler.PlannerPromptTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.PlannerPrompt
  alias Shoestring.Test.PlannerHelpers

  defp inputs(overrides \\ %{}) do
    base = %{
      goal_statement: "Record plan revisions durably.",
      base_revision: "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567",
      remote_ref: nil,
      constraints: ["No new dependencies."],
      non_goals: ["Executing tasks."],
      acceptance: %{
        "gates" => [%{"gate" => "mix_precommit"}],
        "evidence" => ["The gate passes."]
      },
      context_refs: [%{ref: "docs/plan-contract.md", summary: "The plan contract."}],
      planner_identity: "fixture-planner",
      planner_version: "1",
      planner_model: "fixture-1"
    }

    Map.merge(base, overrides)
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        goal_statement: "Record plan revisions durably.",
        repository: %{"base_revision" => "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"},
        constraints: ["No new dependencies."],
        non_goals: ["Executing tasks."],
        acceptance: %{
          "gates" => [%{"gate" => "mix_precommit"}],
          "evidence" => ["The gate passes."]
        },
        context_refs: [%{"ref" => "docs/plan-contract.md", "summary" => "The plan contract."}],
        planner: %{"identity" => "fixture-planner", "version" => "1", "model" => "fixture-1"}
      },
      overrides
    )
  end

  describe "normalize/1" do
    test "accepts bounded secret-free inputs" do
      assert {:ok, normalized} = PlannerPrompt.normalize(attrs())
      assert normalized.goal_statement == "Record plan revisions durably."
      assert normalized.base_revision == "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"

      assert [%{ref: "docs/plan-contract.md", summary: "The plan contract."}] =
               normalized.context_refs
    end

    test "refuses a moving ref where a resolved revision belongs" do
      assert {:error, {:invalid_planner_request, :base_revision, _message}} =
               PlannerPrompt.normalize(attrs(%{repository: %{"base_revision" => "main"}}))
    end

    test "refuses an untrusted acceptance gate" do
      attrs =
        attrs(%{
          acceptance: %{"gates" => [%{"gate" => "mix deploy"}], "evidence" => ["It deploys."]}
        })

      assert {:error, {:invalid_planner_request, :acceptance_gates, _message}} =
               PlannerPrompt.normalize(attrs)
    end

    test "refuses credentials in context summaries and keeps the bound" do
      attrs =
        attrs(%{context_refs: [%{"ref" => "notes.md", "summary" => "token: hunter2-configured"}]})

      assert {:error, {:invalid_planner_request, :context_summary, _message}} =
               PlannerPrompt.normalize(attrs)
    end

    test "refuses absolute machine paths in the statement and in context" do
      statement_attrs = attrs(%{goal_statement: "Fix /Users/someone/projects/app urgently."})

      assert {:error, {:invalid_planner_request, :goal_statement, _message}} =
               PlannerPrompt.normalize(statement_attrs)

      context_attrs =
        attrs(%{context_refs: [%{"ref" => "notes.md", "summary" => "See /home/someone/notes."}]})

      assert {:error, {:invalid_planner_request, :context_summary, _message}} =
               PlannerPrompt.normalize(context_attrs)
    end

    test "refuses more than sixteen context references" do
      refs =
        for index <- 1..17, do: %{"ref" => "ref-#{index}.md", "summary" => "Summary #{index}."}

      assert {:error, {:invalid_planner_request, :context_refs, _message}} =
               PlannerPrompt.normalize(attrs(%{context_refs: refs}))
    end

    test "accepts an empty context and empty constraint lists" do
      assert {:ok, normalized} =
               PlannerPrompt.normalize(attrs(%{context_refs: [], constraints: [], non_goals: []}))

      assert normalized.context_refs == []
      assert normalized.constraints == []
    end
  end

  describe "build/2" do
    test "builds a bounded prompt carrying references and summaries, not transcripts" do
      assert {:ok, %{prompt: prompt, input_digest: digest}} =
               PlannerPrompt.build(inputs())

      assert prompt["goal"]["statement"] == "Record plan revisions durably."

      assert prompt["goal"]["repository"] == %{
               "base_revision" => "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"
             }

      assert prompt["context"] == [
               %{"ref" => "docs/plan-contract.md", "summary" => "The plan contract."}
             ]

      assert prompt["planner"] == %{
               "identity" => "fixture-planner",
               "version" => "1",
               "model" => "fixture-1"
             }

      assert prompt["instructions"]["response_format"] =~ "JSON"
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

      # The Digest identifies the request, not the attempt: repair errors
      # change the prompt but never the digest.
      assert {:ok, %{prompt: repair_prompt, input_digest: ^digest}} =
               PlannerPrompt.build(inputs(),
                 repair_errors: ["tasks: must declare at least one task"]
               )

      assert get_in(repair_prompt, ["instructions", "repair", "errors"]) == [
               "tasks: must declare at least one task"
             ]
    end

    test "the digest is deterministic and sensitive to inputs" do
      assert PlannerPrompt.digest_inputs(inputs()) == PlannerPrompt.digest_inputs(inputs())

      assert PlannerPrompt.digest_inputs(inputs()) !=
               PlannerPrompt.digest_inputs(inputs(%{goal_statement: "A different goal."}))
    end

    test "fails oversized prompts instead of truncating them" do
      constraints = for index <- 1..16, do: String.duplicate("constraint-#{index}-", 40)

      refs =
        for index <- 1..16, do: %{ref: "ref-#{index}.md", summary: String.duplicate("s", 500)}

      assert {:error, {:planner_prompt_too_large, %{bytes: bytes, limit: limit}}} =
               PlannerPrompt.build(inputs(%{constraints: constraints, context_refs: refs}))

      assert bytes > limit
      assert limit == PlannerPrompt.max_prompt_bytes()
    end

    test "helper goal attributes from the request builder normalize" do
      assert {:ok, _normalized} =
               PlannerHelpers.request_attrs()
               |> Map.put(:planner, %{"identity" => "x", "version" => "1", "model" => "m"})
               |> PlannerPrompt.normalize()
    end
  end
end
