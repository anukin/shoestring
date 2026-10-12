defmodule Shoestring.Cobbler.Planner.Evaluation do
  @moduledoc """
  Offline comparison of untrusted planner output with versioned reference fixtures.
  Never starts the application, calls a model, executes gates or grants approval.
  Counts and absent paths are observations, not semantic quality scores.
  """

  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Cobbler.Planner.{Output, Schema}

  @cases ~w(catalog greeting receipt)
  @files ~w(pantry.py test/__init__.py test/test_catalog.py test/test_greeting.py test/test_receipt.py test/test_total.py)
  @criteria ~w(acceptance_coverage task_boundedness_and_independence dependency_ordering checkpoint_usefulness repository_grounding task_count_and_handoff_overhead sequential_execution_success)

  def cases, do: @cases

  def context(case_id) when case_id in @cases do
    with {:ok, json} <- read_file(path("cases/#{case_id}/goal.json")),
         {:ok, attrs} <- Jason.decode(json),
         {:ok, goal} <- PlanContract.validate_goal(attrs),
         {:ok, files} <- repository_files() do
      context = %{
        "version" => 1,
        "case_id" => case_id,
        "goal_contract" => goal,
        "repository_files" => files,
        "output_schema" => Schema.for_goal(goal),
        "instruction" =>
          "Return only the structured plan. Use this repository snapshot, preserve the exact goal and omit planner provenance. No tools or commands are available.",
        "base_revision_note" =>
          "1111111 is a synthetic fixture reference, not an executable Git revision."
      }

      {:ok, Map.put(context, "digest", PlanContract.digest(context))}
    end
  end

  def context(_), do: {:error, :unknown_case}

  def reference(case_id) when case_id in @cases,
    do: read_file(path("cases/#{case_id}/reference.json"))

  def reference(_), do: {:error, :unknown_case}

  def compare(case_id, proposal_json) do
    with {:ok, context} <- context(case_id),
         {:ok, reference_json} <- reference(case_id),
         {:ok, reference} <- validate(reference_json, context) do
      candidate = validate(proposal_json, context)

      {:ok,
       %{
         "version" => 1,
         "case_id" => case_id,
         "context_digest" => context["digest"],
         "reference_review_status" => "user_approved_with_language_change",
         "reference_review_note" =>
           "The user approved these task scopes and requested Python or Go. The artifacts were translated to Python; the converted bytes were not separately human-reviewed. This is evaluation baseline review, not execution approval.",
         "candidate_output_digest" => output_digest(proposal_json),
         "reference" => observations(reference, context),
         "candidate" => candidate_result(candidate, context),
         "semantic_review" => %{
           "status" => "unreviewed",
           "criteria" =>
             Enum.map(@criteria, &%{"criterion" => &1, "score" => nil, "evidence" => []})
         },
         "execution" => %{"status" => "not_run", "evidence" => []},
         "quality_verdict" => "UNVERIFIED",
         "note" =>
           "Schema validity and relative counts do not establish goal coverage, correct dependencies, useful checkpoints or execution success. This command never runs a model or a gate."
       }}
    else
      {:error, _} -> {:error, :invalid_case}
    end
  end

  # Read at most the authority's byte bound plus one; no raw input is echoed.
  def read_file(file_path) do
    limit = PlanContract.max_plan_bytes()

    case File.open(file_path, [:read, :binary], fn file ->
           IO.binread(file, limit + 1)
         end) do
      {:ok, json} when is_binary(json) and byte_size(json) <= limit -> {:ok, json}
      _ -> {:error, :unreadable_or_oversized_file}
    end
  end

  defp validate(json, context) do
    projection = %{
      "goal_id" => "01950000-0000-7000-8000-000000000001",
      "goal_contract" => context["goal_contract"],
      "source_context_refs" => []
    }

    configuration = %{"adapter" => "fixture", "model" => "offline-comparison", "version" => "1"}

    with {:ok, contract} <- Output.validate(json, projection, configuration) do
      # Offline provenance authorizes nothing and is excluded from comparison digests.
      PlanContract.new(Map.delete(contract.content, "planner"))
    end
  end

  defp candidate_result({:ok, contract}, context),
    do: Map.put(observations(contract, context), "schema_status", "valid")

  defp candidate_result({:error, {status, errors}}, _context) when is_list(errors),
    do: %{
      "schema_status" => status,
      "error_codes" => Enum.map(errors, & &1["code"]),
      "metrics" => nil
    }

  defp candidate_result(_, _),
    do: %{
      "schema_status" => "schema_failed",
      "error_codes" => ["invalid_output"],
      "metrics" => nil
    }

  defp observations(contract, context) do
    tasks = contract.content["tasks"]
    files = Map.keys(context["repository_files"])

    cited_paths =
      Enum.flat_map(tasks, fn task ->
        task["hints"]["files"] ++ Enum.flat_map(task["gates"], &Map.get(&1, "test_paths", []))
      end) ++
        Enum.flat_map(
          contract.content["goal"]["acceptance"]["gates"],
          &Map.get(&1, "test_paths", [])
        )

    %{
      "digest" => contract.digest,
      "metrics" => %{
        "task_count" => length(tasks),
        "dependency_edges" => Enum.sum(Enum.map(tasks, &length(&1["depends_on"]))),
        "sequential_task_transitions" => length(tasks) - 1,
        "declared_attempts" => Enum.sum(Enum.map(tasks, & &1["execution"]["max_attempts"])),
        "declared_task_seconds" =>
          Enum.sum(Enum.map(tasks, & &1["execution"]["max_duration_seconds"])),
        "goal_budget" => contract.content["budget"]
      },
      "paths_absent_from_snapshot" =>
        cited_paths |> Enum.uniq() |> Enum.reject(&(&1 in files)) |> Enum.sort(),
      "path_note" =>
        "Absent paths require review; they may describe intended new files. Existing paths do not prove correct repository facts. Task transitions do not predict provider handoffs."
    }
  end

  defp repository_files do
    Enum.reduce_while(@files, {:ok, %{}}, fn file, {:ok, acc} ->
      case read_file(path("repository/#{file}")) do
        {:ok, content} -> {:cont, {:ok, Map.put(acc, file, content)}}
        error -> {:halt, error}
      end
    end)
  end

  defp path(relative), do: Application.app_dir(:shoestring, "priv/planner_eval/#{relative}")

  defp output_digest(json) when is_binary(json),
    do: :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)

  defp output_digest(_), do: nil
end
