defmodule Shoestring.Cobbler.Planner.Output do
  @moduledoc "Untrusted structured-output validation, fixed goal and trusted provenance binding."
  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Harness.Security

  def validate(json, projection, configuration) when is_binary(json) do
    with :ok <- byte_limit(json),
         {:ok, attrs} when is_map(attrs) <- Jason.decode(json),
         {:ok, contract} <- PlanContract.new(attrs),
         true <- contract.content["goal"] == projection["goal_contract"],
         false <- Map.has_key?(attrs, "planner"),
         :ok <- preservation(contract, projection),
         [] <- Security.scan_term(contract.content) do
      attrs
      |> Map.put("planner", provenance(projection, configuration))
      |> PlanContract.new()
    else
      false ->
        failure(
          "unsafe_proposal",
          "goal_or_provenance_changed",
          "Preserve the goal contract and leave planner provenance to Shoestring."
        )

      true ->
        failure(
          "unsafe_proposal",
          "planner_provenance_supplied",
          "Planner provenance is owned by Shoestring."
        )

      {:error, :amendment_preservation_failed} ->
        failure(
          "unsafe_proposal",
          "amendment_preservation_failed",
          "Preserve approved task identities, accepted contracts and existing retirements; scope retirement requires a human edit."
        )

      {:error, {:forbidden_command_field, _}} ->
        failure(
          "unsafe_proposal",
          "embedded_command",
          "Use trusted gate references; embedded command fields are forbidden."
        )

      {:error, {:invalid_graph, reason}} ->
        failure("schema_failed", "invalid_graph", graph_message(reason))

      {:error, {:invalid_plan, changeset}} ->
        {:error, {"schema_failed", field_errors(changeset)}}

      {:error, {:budget_exceeded, _}} ->
        failure(
          "schema_failed",
          "execution_budget",
          "The execution budget must cover all task bounds."
        )

      {:error, {:plan_too_large, _}} ->
        failure("schema_failed", "output_too_large", "The plan exceeds the byte limit.")

      {:error, %Jason.DecodeError{}} ->
        failure(
          "schema_failed",
          "invalid_json",
          "Return a single JSON object without fences or commentary."
        )

      {:ok, _} ->
        failure("schema_failed", "invalid_object", "Return a JSON object.")

      [_ | _] ->
        failure(
          "unsafe_proposal",
          "forbidden_content",
          "Remove credentials, private paths and forbidden content."
        )

      _ ->
        failure(
          "schema_failed",
          "invalid_output",
          "The output does not satisfy the plan contract."
        )
    end
  end

  def validate(_, _, _), do: failure("schema_failed", "invalid_output", "Return a JSON string.")

  defp preservation(contract, projection) do
    if Shoestring.Cobbler.Planner.Amendment.output_allowed?(contract, projection),
      do: :ok,
      else: {:error, :amendment_preservation_failed}
  end

  def provenance(projection, configuration) do
    %{
      "identity" => "#{configuration["adapter"]}:#{configuration["model"]}",
      "version" => configuration["version"],
      "source_context_refs" =>
        ["goal:#{projection["goal_id"]}"] ++ projection["source_context_refs"]
    }
  end

  defp failure(state, code, message),
    do: {:error, {state, [%{"code" => code, "message" => message}]}}

  defp byte_limit(json) do
    if byte_size(json) <= PlanContract.max_plan_bytes(),
      do: :ok,
      else: {:error, {:plan_too_large, :output}}
  end

  defp graph_message({:cycle, _}), do: "Dependencies contain a cycle."

  defp graph_message(_),
    do: "Check duplicate task IDs, self-dependencies and missing dependency references."

  defp field_errors(changeset) do
    changeset.errors
    |> Enum.take(8)
    |> Enum.map(fn {field, {message, _}} ->
      %{
        "code" => "invalid_field",
        "message" => Security.redact("#{field}: #{message}")
      }
    end)
  end
end
