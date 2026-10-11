defmodule Mix.Tasks.Shoestring.Plans.Eval do
  use Mix.Task

  alias Shoestring.Cobbler.Planner.Evaluation

  @shortdoc "Compare saved planner proposals with reference fixtures offline"
  @moduledoc """
  No application, database, provider or gate is started.

      mix shoestring.plans.eval list
      mix shoestring.plans.eval context CASE
      mix shoestring.plans.eval compare CASE --file proposal.json
      mix shoestring.plans.eval reference CASE

  `context` exports a pinned synthetic repository snapshot and goal/schema.
  `compare` validates raw structured output and reports reference/candidate counts
  separately from unreviewed semantic criteria and unrun execution evidence.
  `reference` smoke-checks the reference fixture; it is not a model-quality result.
  See docs/planner-evaluation.md for the rubric and evidence procedure.
  """
  @impl true
  def run(args) do
    Mix.Task.run("compile")

    case args do
      ["list"] ->
        output(%{"cases" => Evaluation.cases()})

      ["context", case_id] ->
        result!(Evaluation.context(case_id)) |> output()

      ["reference", case_id] ->
        json = result!(Evaluation.reference(case_id))

        Evaluation.compare(case_id, json)
        |> result!()
        |> Map.put("source", "reference_fixture_smoke_check")
        |> output()

      ["compare", case_id, "--file", file] ->
        json = result!(Evaluation.read_file(file))

        Evaluation.compare(case_id, json)
        |> result!()
        |> Map.put("source", "saved_proposal_unverified_origin")
        |> output()

      _ ->
        Mix.raise("Invalid arguments. See mix help shoestring.plans.eval")
    end
  end

  defp result!({:ok, value}), do: value
  defp result!({:error, reason}), do: Mix.raise("Offline evaluation refused: #{reason}")
  defp output(value), do: Mix.shell().info(Jason.encode!(value, pretty: true))
end
