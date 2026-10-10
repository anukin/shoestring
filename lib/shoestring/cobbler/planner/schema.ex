defmodule Shoestring.Cobbler.Planner.Schema do
  @moduledoc "Structured-output schema for the tool-free planner. PlanContract remains the authority."

  def for_goal(goal) do
    object(%{
      "version" => %{"type" => "integer", "const" => 1},
      "goal" => %{"type" => "object", "const" => goal},
      "budget" =>
        object(%{
          "max_total_attempts" => integer(1, 200),
          "max_total_duration_seconds" => integer(1, 86_400)
        }),
      "tasks" => array(task(), 1, 32)
    })
  end

  def for_projection(projection) do
    schema = for_goal(projection["goal_contract"])

    case projection["amendment"] do
      nil ->
        schema

      a ->
        {:ok, parent} =
          Shoestring.Cobbler.PlanContract.from_canonical_json(a["current_plan_json"])

        if Map.has_key?(parent.content, "retirements") do
          schema
          |> put_in(["properties", "retirements"], %{"const" => parent.content["retirements"]})
          |> Map.update!("required", &Enum.sort(["retirements" | &1]))
        else
          schema
        end
    end
  end

  defp task do
    object(%{
      "id" => Map.put(text(63), "pattern", "^[a-z0-9][a-z0-9_-]{0,62}$"),
      "title" => text(200),
      "outcome" => text(1000),
      "depends_on" => array(text(63), 0, 16),
      "inputs" => array(text(500), 0, 16),
      "expected_artifacts" => array(text(300), 0, 16),
      "hints" =>
        object(%{"files" => array(text(200), 0, 32), "symbols" => array(text(200), 0, 32)}),
      "acceptance_criteria" => array(text(500), 1, 8),
      "gates" => array(gate(), 1, 4),
      "checkpoint" => object(%{"condition" => text(500), "evidence" => array(text(500), 1, 8)}),
      "risks" => array(text(500), 0, 8),
      "execution" =>
        object(%{
          "max_attempts" => integer(1, 20),
          "max_duration_seconds" => integer(1, 14_400)
        })
    })
  end

  defp gate do
    %{
      "anyOf" => [
        object(%{
          "gate" => %{
            "type" => "string",
            "enum" => ["mix_precommit", "mix_format_check", "mix_compile_strict"]
          }
        }),
        object(%{
          "gate" => %{"type" => "string", "const" => "mix_test"},
          "test_paths" => array(text(200), 0, 16)
        })
      ]
    }
  end

  defp object(properties),
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => properties,
      "required" => properties |> Map.keys() |> Enum.sort()
    }

  defp text(max), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}
  defp integer(min, max), do: %{"type" => "integer", "minimum" => min, "maximum" => max}

  defp array(items, min, max),
    do: %{"type" => "array", "items" => items, "minItems" => min, "maxItems" => max}
end
