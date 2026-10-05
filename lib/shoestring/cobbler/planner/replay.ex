defmodule Shoestring.Cobbler.Planner.Replay do
  @moduledoc "Rebuilds initial planning state from events and detects cache divergence without mutation."
  alias Shoestring.Cobbler.{PlanContract, PlannerRequestRecord}
  alias Shoestring.Cobbler.Planner.{Output, Projection}

  @fields ~w(id goal_id request_key input_digest projection configuration state attempts charged_output_tokens attempt_history errors result_json result_digest)a

  def rebuild(goal_id, stored) do
    with {:ok, events} <- Shoestring.Trajectory.replay(goal_id),
         {:ok, rebuilt} <- fold(events, goal_id) do
      stored = if stored, do: Map.take(stored, @fields), else: nil
      {:ok, %{request: rebuilt, consistent?: stored == rebuilt}}
    end
  end

  defp fold(events, goal_id) do
    Enum.reduce_while(events, {:ok, nil}, fn event, {:ok, state} ->
      if String.starts_with?(event.type, "cobbler.planner.") do
        case apply_event(state, event, events, goal_id) do
          {:ok, next} -> {:cont, {:ok, next}}
          _ -> {:halt, {:error, {:invalid_planner_history, event.id}}}
        end
      else
        {:cont, {:ok, state}}
      end
    end)
  end

  defp apply_event(
         nil,
         %{type: "cobbler.planner.requested", payload: p} = request,
         events,
         goal_id
       ) do
    with {:ok, projection} <- Jason.decode(p["projection_json"]),
         true <- projection["goal_id"] == goal_id,
         true <- context_owned?(projection, events, request.sequence) do
      {:ok,
       %{
         id: p["request_id"],
         goal_id: goal_id,
         request_key: p["request_key"],
         input_digest: p["input_digest"],
         projection: projection,
         configuration: p["configuration"],
         state: "pending",
         attempts: 0,
         charged_output_tokens: 0,
         attempt_history: %{"items" => []},
         errors: %{"items" => []},
         result_json: nil,
         result_digest: nil
       }}
    end
  end

  defp apply_event(state, %{type: "cobbler.planner.blocked", payload: p} = event, events, _)
       when is_map(state) do
    if p["request_id"] == state.id and
         state.state in ~w(pending blocked schema_failed unsafe_proposal) and
         state.attempts < 2 and admission?(p, event, events, state, false) do
      {:ok, %{state | state: "blocked", errors: p["errors"]}}
    else
      :error
    end
  end

  defp apply_event(
         state,
         %{type: "cobbler.planner.attempt.started", payload: p} = event,
         events,
         _
       )
       when is_map(state) do
    if p["request_id"] == state.id and
         state.state in ~w(pending blocked schema_failed unsafe_proposal) and
         p["attempt"] == state.attempts + 1 and
         p["output_token_allowance"] == state.configuration["max_output_tokens"] and
         admission?(p, event, events, state, true) do
      history =
        state.attempt_history["items"] ++
          [
            %{
              "attempt" => p["attempt"],
              "status" => "running",
              "output_token_allowance" => p["output_token_allowance"],
              "admission_event_id" => p["admission_event_id"]
            }
          ]

      {:ok,
       %{
         state
         | state: "running",
           attempts: p["attempt"],
           charged_output_tokens: p["charged_output_tokens"],
           attempt_history: %{"items" => history}
       }}
    else
      :error
    end
  end

  defp apply_event(state, %{type: "cobbler.planner.attempt.finished", payload: p}, _, _)
       when is_map(state) do
    with true <-
           state.state == "running" and p["request_id"] == state.id and
             p["attempt"] == state.attempts,
         true <-
           is_nil(p["output_tokens"]) ||
             p["output_tokens"] <= state.configuration["max_output_tokens"],
         :ok <- bound_result(state, p) do
      history =
        Enum.map(state.attempt_history["items"], fn item ->
          if item["attempt"] == p["attempt"],
            do:
              item
              |> Map.put("status", p["state"])
              |> Map.put("errors", p["errors"])
              |> Map.put("output_tokens", p["output_tokens"]),
            else: item
        end)

      {:ok,
       %{
         state
         | state: p["state"],
           errors: p["errors"],
           attempt_history: %{"items" => history},
           result_json: p["plan_content"],
           result_digest: p["plan_digest"]
       }}
    end
  end

  defp apply_event(_, _, _, _), do: :error

  defp bound_result(state, %{"state" => "ready"} = payload) do
    with {:ok, contract} <- PlanContract.from_canonical_json(payload["plan_content"]),
         true <- contract.content["goal"] == state.projection["goal_contract"],
         true <-
           contract.content["planner"] == Output.provenance(state.projection, state.configuration) do
      :ok
    else
      _ -> :error
    end
  end

  defp bound_result(_, _), do: :ok

  defp admission?(payload, event, events, state, admitted?) do
    case Enum.find(events, &(&1.id == payload["admission_event_id"])) do
      %{type: "admission.decided", sequence: sequence, payload: admission}
      when sequence < event.sequence ->
        admission["result"] == "admit" == admitted? and
          admission["requested_capability"] == "read_only" and
          admission["scope"] == state.configuration["scope"] and
          admission["candidate"]["provider_id"] == state.configuration["provider_id"] and
          admission["candidate"]["adapter_id"] == "planner.#{state.configuration["adapter"]}"

      _ ->
        false
    end
  end

  @doc false
  def stored_fields(%PlannerRequestRecord{} = row), do: Map.take(row, @fields)

  defp context_owned?(projection, events, sequence) do
    Enum.all?(projection["evidence_summaries"]["items"], fn summary ->
      ["event", id, _type] = String.split(summary["reference"], ":")

      case Enum.find(events, &(&1.id == id and &1.sequence < sequence)) do
        nil -> false
        event -> Projection.summarize_event(event) == summary
      end
    end)
  end
end
