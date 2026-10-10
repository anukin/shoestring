defmodule Shoestring.Cobbler.Planner.Projection do
  @moduledoc "Bounded model-visible inputs from a durable goal and goal-owned evidence references."
  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Harness.{Contract, Security}
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}
  @max_bytes 24_576

  def build(repo, goal_id, attrs) when is_map(attrs) do
    with %Goal{status: "active"} = goal <- repo.get(Goal, goal_id),
         false <- Goal.observatory?(goal),
         {:ok, requested_by} <- Contract.text(attrs[:requested_by], :requested_by, max: 187),
         true <- Regex.match?(~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/, requested_by),
         {:ok, contract} <- PlanContract.validate_goal(attrs[:goal_contract]),
         {:ok, evidence} <- references(repo, goal_id, Map.get(attrs, :context_event_ids, [])),
         projection = %{
           "goal_id" => goal.id,
           "title" => goal.title,
           "description" => goal.description,
           "requested_by" => requested_by,
           "goal_contract" => contract,
           "source_context_refs" => Enum.map(evidence, & &1["reference"]),
           "evidence_summaries" => %{"items" => evidence}
         },
         :ok <- validate(projection) do
      {:ok, projection}
    else
      nil -> {:error, :goal_not_found}
      %Goal{} -> {:error, :goal_not_active}
      true -> {:error, :protected_goal}
      false -> {:error, :non_human_planner_request}
      error -> error
    end
  end

  def build(_, _, _), do: {:error, :invalid_planner_request}

  def validate(projection) when is_map(projection) do
    with true <-
           Map.keys(Map.delete(projection, "amendment")) |> Enum.sort() ==
             Enum.sort(
               ~w(goal_id title description requested_by goal_contract source_context_refs evidence_summaries)
             ),
         {:ok, _} <- Ecto.UUID.cast(projection["goal_id"]),
         {:ok, _} <- Contract.text(projection["title"], :title, max: 500),
         true <-
           is_binary(projection["requested_by"]) &&
             Regex.match?(
               ~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/,
               projection["requested_by"]
             ),
         {:ok, _} <- PlanContract.validate_goal(projection["goal_contract"]),
         true <-
           is_nil(projection["description"]) ||
             (is_binary(projection["description"]) && byte_size(projection["description"]) <= 4000),
         refs when is_list(refs) and length(refs) <= 15 <- projection["source_context_refs"],
         true <-
           Enum.all?(
             refs,
             &(is_binary(&1) && String.match?(&1, ~r/\Aevent:[0-9a-f-]{36}:[a-z0-9._]{1,100}\z/))
           ),
         %{"items" => evidence} when is_list(evidence) <- projection["evidence_summaries"],
         true <- Enum.all?(evidence, &valid_summary?/1),
         true <- Enum.map(evidence, &Map.get(&1, "reference")) == refs,
         true <- Shoestring.Cobbler.Planner.Amendment.valid_projection?(projection),
         [] <- Security.scan_term(projection),
         true <- byte_size(Jason.encode!(projection)) <= @max_bytes do
      :ok
    else
      _ -> {:error, :unsafe_or_oversized_planner_projection}
    end
  end

  def validate(_), do: {:error, :invalid_planner_projection}

  # References are explicit and finite. We never project raw provider output,
  # transcript or hidden reasoning, nor fetch files based on model requests.
  defp references(repo, goal_id, ids) when is_list(ids) and length(ids) <= 15 do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, refs} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          case repo.get(TrajectoryEvent, uuid) do
            %TrajectoryEvent{goal_id: ^goal_id, type: type} = event
            when type in [
                   "goal.created",
                   "decision.recorded",
                   "checkpoint.created",
                   "task.completed"
                 ] ->
              {:cont, {:ok, refs ++ [summarize_event(event)]}}

            _ ->
              {:halt, {:error, :planner_context_not_owned}}
          end

        _ ->
          {:halt, {:error, :invalid_planner_context_reference}}
      end
    end)
  end

  defp references(_, _, _), do: {:error, :invalid_planner_context_reference}

  @doc false
  def summarize_event(event) do
    facts = Map.take(event.payload, summary_fields(event.type))
    %{"reference" => "event:#{event.id}:#{event.type}", "facts" => facts}
  end

  defp summary_fields("goal.created"), do: ~w(title description)
  defp summary_fields("decision.recorded"), do: ~w(decision rationale)
  defp summary_fields("task.completed"), do: ~w(task_id result)
  defp summary_fields("checkpoint.created"), do: ~w(repository_state next_action stop_reason)

  defp summary_fields("cobbler.plan.task.accepted"),
    do: ~w(plan_task_id revision_number plan_digest run_id attempt commit)

  defp summary_fields("cobbler.plan.task.gate_failed"),
    do: ~w(plan_task_id revision_number plan_digest run_id attempt gate retry_state)

  defp summary_fields(_), do: []

  defp valid_summary?(%{"reference" => ref, "facts" => facts} = summary)
       when map_size(summary) == 2 and is_binary(ref) and is_map(facts) do
    case String.split(ref, ":") do
      ["event", id, type] ->
        match?({:ok, _}, Ecto.UUID.cast(id)) and summary_fields(type) != [] and
          Enum.all?(Map.keys(facts), &(&1 in summary_fields(type))) and
          Enum.all?(facts, &valid_fact?/1) and
          byte_size(Jason.encode!(facts)) <= 4000

      _ ->
        false
    end
  end

  defp valid_summary?(_), do: false

  defp valid_fact?({"repository_state", %{"revision" => revision, "dirty" => dirty} = state}) do
    map_size(state) == 2 and is_binary(revision) and byte_size(revision) <= 128 and
      is_boolean(dirty)
  end

  defp valid_fact?({key, value}) when key in ["revision_number", "attempt"],
    do: is_integer(value) and value > 0

  defp valid_fact?({_key, value}),
    do: is_nil(value) or (is_binary(value) and byte_size(value) <= 2000)
end
