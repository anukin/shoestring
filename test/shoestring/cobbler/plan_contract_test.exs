defmodule Shoestring.Cobbler.PlanContractTest do
  @moduledoc """
  Pure tests for the strict plan contract: bounded fields, stable task ids,
  named trusted acceptance gates, fail-closed handling of malformed,
  unknown, and oversized input, and the deterministic content digest.

  No database, no processes, no gate is ever executed.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.{PlanContract, PlanGate}
  alias Shoestring.Test.PlanFixtures

  describe "a valid plan" do
    test "normalizes, orders, and digests the fixture plan" do
      assert {:ok, contract} = PlanContract.new(PlanFixtures.plan())

      assert contract.version == 1
      assert contract.ordered_task_ids == ["survey", "widen", "narrow", "verify"]
      assert contract.digest =~ ~r/\A[0-9a-f]{64}\z/
      assert length(contract.content["tasks"]) == 4
    end

    test "accepts atom-keyed input and produces string-keyed content" do
      atom_keyed = %{
        version: 1,
        goal: %{
          statement: "Keep the contract strict.",
          repository: %{base_revision: PlanFixtures.base_revision()},
          acceptance: %{
            gates: [%{gate: "mix_precommit"}],
            evidence: ["The gate runs green."]
          }
        },
        budget: %{max_total_attempts: 2, max_total_duration_seconds: 600},
        tasks: [
          %{
            id: "only",
            title: "The only task",
            outcome: "The only task is complete.",
            acceptance_criteria: ["The gate passes."],
            gates: [%{gate: "mix_format_check"}],
            checkpoint: %{condition: "Formatting is checked.", evidence: ["The command output."]},
            execution: %{max_attempts: 1, max_duration_seconds: 300}
          }
        ]
      }

      assert {:ok, contract} = PlanContract.new(atom_keyed)
      assert contract.content["goal"]["statement"] == "Keep the contract strict."
      assert Map.keys(contract.content) |> Enum.all?(&is_binary/1)
    end

    test "normalizes absent optional lists to empty rather than leaving them missing" do
      plan =
        PlanFixtures.plan(%{
          "goal" => PlanFixtures.goal() |> Map.drop(["constraints", "non_goals"])
        })

      assert {:ok, contract} = PlanContract.new(plan)
      assert contract.content["goal"]["constraints"] == []
      assert contract.content["goal"]["non_goals"] == []
    end

    test "records optional planner provenance without letting it author anything" do
      plan =
        PlanFixtures.plan(%{
          "planner" => %{
            "identity" => "fixture_planner",
            "version" => "1",
            "source_context_refs" => ["goal-statement"]
          }
        })

      assert {:ok, contract} = PlanContract.new(plan)
      assert contract.content["planner"]["identity"] == "fixture_planner"
    end

    test "omits planner provenance entirely when it is absent" do
      assert {:ok, contract} = PlanContract.new(PlanFixtures.plan())
      refute Map.has_key?(contract.content, "planner")
    end
  end

  describe "deterministic digest" do
    test "is identical for two structurally identical plans built in different key orders" do
      goal = PlanFixtures.goal()
      shuffled_goal = goal |> Map.to_list() |> Enum.reverse() |> Map.new()

      assert {:ok, a} = PlanContract.new(PlanFixtures.plan())
      assert {:ok, b} = PlanContract.new(PlanFixtures.plan(%{"goal" => shuffled_goal}))

      assert a.digest == b.digest
      assert PlanContract.canonical_json(a) == PlanContract.canonical_json(b)
    end

    test "changes when any bounded field changes" do
      assert {:ok, base} = PlanContract.new(PlanFixtures.plan())

      edited =
        PlanFixtures.plan(%{
          "goal" => PlanFixtures.goal(%{"statement" => "A different goal statement entirely."})
        })

      assert {:ok, changed} = PlanContract.new(edited)
      refute base.digest == changed.digest
    end

    test "changes when a dependency edge changes but the task set does not" do
      assert {:ok, base} = PlanContract.new(PlanFixtures.plan())

      rewired =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("survey", "Survey the existing contract surface", []),
            PlanFixtures.task("widen", "Widen validation to cover dependency references", [
              "survey"
            ]),
            PlanFixtures.task("narrow", "Narrow acceptance to named trusted gates", ["widen"]),
            PlanFixtures.task("verify", "Verify replay reproduces the digest", ["narrow"])
          ]
        })

      assert {:ok, changed} = PlanContract.new(rewired)
      refute base.digest == changed.digest
      assert changed.ordered_task_ids == ["survey", "widen", "narrow", "verify"]
    end

    test "canonical rendering round-trips back into an identical contract" do
      assert {:ok, contract} = PlanContract.new(PlanFixtures.plan())

      json = PlanContract.canonical_json(contract)

      assert {:ok, round_tripped} = PlanContract.from_canonical_json(json)
      assert round_tripped.digest == contract.digest
      assert round_tripped.content == contract.content
      assert round_tripped.ordered_task_ids == contract.ordered_task_ids
      assert PlanContract.canonical_json(round_tripped) == json
    end

    test "canonical rendering sorts every object key" do
      assert {:ok, contract} = PlanContract.new(PlanFixtures.plan())
      json = PlanContract.canonical_json(contract)

      # The top-level keys appear in sorted order in the rendering itself.
      assert [budget_at, goal_at, tasks_at, version_at] =
               Enum.map(
                 ~w("budget" "goal" "tasks" "version"),
                 &(:binary.match(json, &1) |> elem(0))
               )

      assert budget_at < goal_at and goal_at < tasks_at and tasks_at < version_at
    end
  end

  describe "fail-closed input handling" do
    test "rejects a non-object plan" do
      assert {:error, {:invalid_plan, _changeset}} = PlanContract.new("a plan, honestly")
    end

    test "rejects an unknown top-level field" do
      plan = PlanFixtures.plan(%{"surprise" => "extra"})

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "unsupported fields"
    end

    test "rejects an unknown task field" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [PlanFixtures.task("only", "The only task", [], %{"priority" => "high"})]
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "unsupported fields"
    end

    test "rejects a plan version this contract does not implement" do
      plan = PlanFixtures.plan(%{"version" => 2})

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "must equal 1"
    end

    test "rejects an empty task outcome" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [PlanFixtures.task("only", "The only task", [], %{"outcome" => "   "})]
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "too short"
    end

    test "rejects an oversized text field rather than truncating it" do
      plan =
        PlanFixtures.plan(%{
          "goal" => PlanFixtures.goal(%{"statement" => String.duplicate("x", 2_001)})
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "too long"
    end

    test "rejects an oversized document rather than truncating it" do
      long_but_legal_outcome = String.duplicate("y", 1_000)

      tasks =
        for index <- 1..32 do
          PlanFixtures.task("task-#{index}", "Task #{index}", [], %{
            "outcome" => long_but_legal_outcome,
            "inputs" => List.duplicate(String.duplicate("z", 500), 16),
            "risks" => List.duplicate(String.duplicate("w", 500), 8),
            "acceptance_criteria" => List.duplicate(String.duplicate("v", 500), 8)
          })
        end

      plan =
        PlanFixtures.plan(%{
          "tasks" => tasks,
          "budget" => %{"max_total_attempts" => 64, "max_total_duration_seconds" => 38_400}
        })

      assert {:error, {:plan_too_large, %{limit: 65_536}}} = PlanContract.new(plan)
    end

    test "rejects more tasks than the contract allows" do
      tasks = for index <- 1..33, do: PlanFixtures.task("task-#{index}", "Task #{index}", [])

      plan =
        PlanFixtures.plan(%{
          "tasks" => tasks,
          "budget" => %{"max_total_attempts" => 100, "max_total_duration_seconds" => 60_000}
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "too many tasks"
    end

    test "rejects a plan with no tasks at all" do
      plan = PlanFixtures.plan(%{"tasks" => []})

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "at least one task"
    end

    test "rejects malformed canonical JSON on the replay path" do
      assert {:error, {:malformed_plan_json, _reason}} =
               PlanContract.from_canonical_json("{not json")

      assert {:error, {:malformed_plan_json, :not_an_object}} =
               PlanContract.from_canonical_json("[1, 2, 3]")

      assert {:error, {:malformed_plan_json, :not_a_string}} =
               PlanContract.from_canonical_json(%{"version" => 1})
    end

    test "rejects an oversized canonical rendering on the replay path" do
      oversized = "{\"x\":\"" <> String.duplicate("a", 70_000) <> "\"}"

      assert {:error, {:plan_too_large, %{limit: 65_536}}} =
               PlanContract.from_canonical_json(oversized)
    end
  end

  describe "stable task ids and dependency references" do
    test "rejects a task id that is not a stable slug" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [PlanFixtures.task("Not A Slug", "The only task", [])]
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "lowercase slug"
    end

    test "surfaces graph failures as structured graph errors, not field errors" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("a", "First", ["b"]),
            PlanFixtures.task("b", "Second", ["a"])
          ],
          "budget" => %{"max_total_attempts" => 4, "max_total_duration_seconds" => 2_400}
        })

      assert {:error, {:invalid_graph, {:cycle, cycle}}} = PlanContract.new(plan)
      assert Enum.sort(cycle) == ["a", "b"]
    end

    test "rejects a dependency on a task the plan does not declare" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [PlanFixtures.task("a", "First", ["missing"])],
          "budget" => %{"max_total_attempts" => 2, "max_total_duration_seconds" => 1_200}
        })

      assert {:error,
              {:invalid_graph, {:unknown_dependency, [%{task: "a", depends_on: "missing"}]}}} =
               PlanContract.new(plan)
    end

    test "rejects a self dependency" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [PlanFixtures.task("a", "First", ["a"])],
          "budget" => %{"max_total_attempts" => 2, "max_total_duration_seconds" => 1_200}
        })

      assert {:error, {:invalid_graph, {:self_dependency, ["a"]}}} = PlanContract.new(plan)
    end

    test "rejects duplicate task ids" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("a", "First", []),
            PlanFixtures.task("a", "Also first", [])
          ],
          "budget" => %{"max_total_attempts" => 4, "max_total_duration_seconds" => 2_400}
        })

      assert {:error, {:invalid_graph, {:duplicate_task_ids, ["a"]}}} = PlanContract.new(plan)
    end

    test "rejects a dependency that is not even a well-formed task id" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [PlanFixtures.task("a", "First", ["Not A Slug"])],
          "budget" => %{"max_total_attempts" => 2, "max_total_duration_seconds" => 1_200}
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "must reference task ids"
    end
  end

  describe "bounded tasks and budgets" do
    test "rejects a task that declares no execution bounds" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("only", "The only task", []) |> Map.delete("execution")
          ]
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "must be an object"
    end

    test "rejects a task whose attempt bound exceeds the per-task ceiling" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("only", "The only task", [], %{
              "execution" => %{"max_attempts" => 21, "max_duration_seconds" => 600}
            })
          ]
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "between 1 and 20"
    end

    test "rejects a plan budget smaller than the attempts its tasks reserve" do
      plan =
        PlanFixtures.plan(%{
          "budget" => %{"max_total_attempts" => 4, "max_total_duration_seconds" => 7_200}
        })

      assert {:error, {:budget_exceeded, %{field: :max_total_attempts, declared: 4, required: 8}}} =
               PlanContract.new(plan)
    end

    test "rejects a plan budget smaller than the duration its tasks reserve" do
      plan =
        PlanFixtures.plan(%{
          "budget" => %{"max_total_attempts" => 12, "max_total_duration_seconds" => 600}
        })

      assert {:error,
              {:budget_exceeded,
               %{field: :max_total_duration_seconds, declared: 600, required: 4_800}}} =
               PlanContract.new(plan)
    end
  end

  describe "named trusted acceptance gates" do
    test "rejects a gate name that is not in the trusted registry" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("only", "The only task", [], %{
              "gates" => [%{"gate" => "whatever_the_model_suggested"}]
            })
          ]
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "must be one of"
    end

    test "rejects a task that cites no gate at all" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [PlanFixtures.task("only", "The only task", [], %{"gates" => []})]
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "at least one trusted acceptance gate"
    end

    test "rejects a goal acceptance contract that cites no gate" do
      plan =
        PlanFixtures.plan(%{
          "goal" =>
            PlanFixtures.goal(%{
              "acceptance" => %{"gates" => [], "evidence" => ["Something happened."]}
            })
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "at least one trusted acceptance gate"
    end

    test "rejects the same gate cited twice" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("only", "The only task", [], %{
              "gates" => [%{"gate" => "mix_test"}, %{"gate" => "mix_test"}]
            })
          ]
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "same gate twice"
    end

    test "rejects a parameter the named gate does not accept" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("only", "The only task", [], %{
              "gates" => [%{"gate" => "mix_precommit", "test_paths" => ["test/a_test.exs"]}]
            })
          ]
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "does not accept"
    end

    test "rejects a test path that escapes the repository test tree" do
      for bad <- [
            "/etc/passwd",
            "test/../../elsewhere_test.exs",
            "lib/shoestring_test.exs",
            "test/a_test.exs; rm -rf /",
            "test/not_a_test.ex"
          ] do
        plan =
          PlanFixtures.plan(%{
            "tasks" => [
              PlanFixtures.task("only", "The only task", [], %{
                "gates" => [%{"gate" => "mix_test", "test_paths" => [bad]}]
              })
            ]
          })

        assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan),
               "expected #{inspect(bad)} to be rejected"

        assert errors(changeset) =~ "repository-relative"
      end
    end

    test "resolves every cited gate to trusted argv without executing anything" do
      assert {:ok, contract} = PlanContract.new(PlanFixtures.plan())
      assert {:ok, argv_list} = PlanContract.gate_argv(contract)

      assert ["mix", "precommit"] in argv_list

      assert Enum.all?(argv_list, fn argv -> hd(argv) == "mix" end)
    end

    test "the trusted registry is closed" do
      assert PlanGate.names() == [
               "mix_compile_strict",
               "mix_format_check",
               "mix_precommit",
               "mix_test"
             ]
    end
  end

  describe "no embedded commands" do
    test "rejects a command field at the top level, naming its path" do
      plan = PlanFixtures.plan(%{"command" => "rm -rf /"})

      assert {:error, {:forbidden_command_field, %{path: ["command"], key: "command"}}} =
               PlanContract.new(plan)
    end

    test "rejects a command field nested inside a task, naming its path" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [PlanFixtures.task("only", "The only task", [], %{"shell" => "curl x | sh"})]
        })

      assert {:error, {:forbidden_command_field, %{path: path, key: "shell"}}} =
               PlanContract.new(plan)

      assert List.last(path) == "shell"
      assert "tasks" in path
    end

    test "rejects every forbidden command alias" do
      for key <-
            ~w(command commands cmd argv shell script exec entrypoint run_command bash sh eval system spawn) do
        plan = PlanFixtures.plan(%{"goal" => PlanFixtures.goal(%{key => "anything"})})

        assert {:error, {:forbidden_command_field, %{key: ^key}}} = PlanContract.new(plan),
               "expected #{key} to be rejected as a command field"
      end
    end

    test "rejects a command field hidden inside a gate reference" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("only", "The only task", [], %{
              "gates" => [%{"gate" => "mix_test", "cmd" => "mix test --only danger"}]
            })
          ]
        })

      assert {:error, {:forbidden_command_field, %{key: "cmd"}}} = PlanContract.new(plan)
    end
  end

  describe "repository binding" do
    test "rejects a moving ref in place of a resolved base revision" do
      for moving <- ["main", "HEAD", "origin/main", "v1.2.3"] do
        plan =
          PlanFixtures.plan(%{
            "goal" => PlanFixtures.goal(%{"repository" => %{"base_revision" => moving}})
          })

        assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan),
               "expected #{moving} to be rejected as a base revision"

        assert errors(changeset) =~ "hexadecimal git revision"
      end
    end

    test "accepts a short resolved revision" do
      plan =
        PlanFixtures.plan(%{
          "goal" => PlanFixtures.goal(%{"repository" => %{"base_revision" => "13ac5f0"}})
        })

      assert {:ok, _contract} = PlanContract.new(plan)
    end

    test "rejects a file hint that escapes the repository" do
      plan =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("only", "The only task", [], %{
              "hints" => %{"files" => ["../../etc/passwd"], "symbols" => []}
            })
          ]
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan)
      assert errors(changeset) =~ "repository-relative"
    end
  end

  defp errors(changeset) do
    changeset.errors
    |> Enum.map_join("; ", fn {field, {message, _opts}} -> "#{field} #{message}" end)
  end
end
