defmodule Shoestring.Test.PlanHelpers do
  @moduledoc false
  @task_a "01950000-0000-7000-8000-000000000001"
  @task_b "01950000-0000-7000-8000-000000000002"
  def task_a, do: @task_a
  def task_b, do: @task_b

  def goal_contract do
    %{
      "version" => 1,
      "statement" => "Add a bounded plan foundation",
      "repository" => %{
        "reference" => "repository:fixture",
        "base_revision" => String.duplicate("a", 40)
      },
      "constraints" => ["Hermetic checks"],
      "non_goals" => ["Execution"],
      "acceptance" => acceptance(),
      "execution" => execution(),
      "budget" => %{
        "max_planning_attempts" => 0,
        "max_revisions" => 10,
        "max_total_response_tokens" => 10_000,
        "max_total_tool_calls" => 200
      }
    }
  end

  def acceptance,
    do: %{
      "criteria" => ["Required behavior is tested"],
      "gates" => ["mix_precommit"],
      "evidence" => ["artifact:test-results"]
    }

  def execution,
    do: %{
      "max_attempts" => 2,
      "max_runtime_seconds" => 300,
      "max_response_tokens" => 1000,
      "max_tool_calls" => 10
    }

  def task(id, deps \\ []) do
    %{
      "id" => id,
      "title" => "Implement bounded behavior",
      "outcome" => "A validated durable revision",
      "dependencies" => deps,
      "inputs" => ["repository:fixture"],
      "expected_artifacts" => ["artifact:source-diff"],
      "hints" => [],
      "acceptance" => acceptance(),
      "checkpoint" => %{
        "condition" => "Before yielding at a safe boundary",
        "evidence" => ["artifact:checkpoint"]
      },
      "risk_notes" => [],
      "execution" => execution()
    }
  end

  def plan do
    %{
      "version" => 1,
      "goal" => goal_contract(),
      "provenance" => %{
        "kind" => "human",
        "version" => "manual-v1",
        "source_context_refs" => ["document:fixture"]
      },
      "tasks" => [task(@task_b, [@task_a]), task(@task_a)]
    }
  end
end
