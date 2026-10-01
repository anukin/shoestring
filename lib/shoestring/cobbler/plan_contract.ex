defmodule Shoestring.Cobbler.PlanContract do
  @moduledoc "Strict JSON-only v1 human plan contracts; gates are trusted names, never commands."

  @max_bytes 131_072
  @gates ["mix_precommit"]
  @event_types ~w(cobbler.plan.goal_defined cobbler.plan.revision_proposed cobbler.plan.revision_approved cobbler.plan.revision_rejected)

  def trusted_gates, do: @gates

  def goal(input), do: validate(input, &goal_schema/0)
  def plan(input), do: validate(input, &plan_schema/0)

  def digest(content) do
    content
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {k, v} -> {k, canonical(v)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp validate(input, schema) do
    with :ok <- bounded_json(input),
         [] <- check(input, {:object, schema.()}, []) do
      {:ok, input}
    else
      {:error, errors} -> {:error, errors}
      errors when is_list(errors) -> {:error, errors}
    end
  end

  # Bound before encoding, including depth and aggregate nodes. Never traverse
  # unbounded terms, accept structs/atoms, or silently truncate oversized input.
  defp bounded_json(value) do
    case scan(value, 0, {32_768, @max_bytes}) do
      {:ok, _remaining} ->
        if byte_size(Jason.encode!(value)) <= @max_bytes,
          do: :ok,
          else: {:error, [error([], :oversized)]}

      :error ->
        {:error, [error([], :malformed_or_oversized)]}
    end
  end

  defp scan(_value, depth, {nodes, bytes}) when depth > 16 or nodes <= 0 or bytes < 0,
    do: :error

  defp scan(value, _depth, {nodes, bytes}) when is_binary(value) do
    if byte_size(value) <= bytes and String.valid?(value) and
         not Shoestring.Harness.Security.secret_value?(value),
       do: {:ok, {nodes - 1, bytes - byte_size(value)}},
       else: :error
  end

  defp scan(value, _depth, {nodes, bytes})
       when is_integer(value) and value in -10_000_000..10_000_000,
       do: {:ok, {nodes - 1, bytes - 8}}

  defp scan(value, _depth, {nodes, bytes}) when is_boolean(value) or is_nil(value),
    do: {:ok, {nodes - 1, bytes - 5}}

  defp scan(value, depth, left) when is_map(value) and not is_struct(value) do
    if map_size(value) <= 64 and Enum.all?(Map.keys(value), &is_binary/1) do
      scan_many(Enum.flat_map(value, fn {k, v} -> [k, v] end), depth, left)
    else
      :error
    end
  end

  defp scan(value, depth, left) when is_list(value), do: scan_many(value, depth, left)
  defp scan(_value, _depth, _left), do: :error

  defp scan_many(values, depth, {nodes, bytes}),
    do: scan_items(values, depth, {nodes - 1, bytes - 2})

  defp scan_items([], _depth, {nodes, bytes}) when nodes > 0 and bytes >= 0,
    do: {:ok, {nodes, bytes}}

  defp scan_items([value | rest], depth, left) do
    case scan(value, depth + 1, left) do
      {:ok, next} -> scan_items(rest, depth, next)
      :error -> :error
    end
  end

  defp scan_items(_improper, _depth, _left), do: :error

  defp check(value, {:object, fields}, path) when is_map(value) do
    unknown =
      if Map.keys(value) -- Map.keys(fields) == [], do: [], else: [error(path, :unknown_fields)]

    unknown ++
      Enum.flat_map(Enum.sort(fields), fn {key, type} ->
        case Map.fetch(value, key) do
          {:ok, nested} -> check(nested, type, path ++ [key])
          :error -> [error(path ++ [key], :required)]
        end
      end)
  end

  defp check(value, {:text, max}, path) when is_binary(value) do
    if String.trim(value) != "" and byte_size(value) <= max,
      do: [],
      else: [error(path, :blank_or_oversized)]
  end

  defp check(value, {:list, type, min, max}, path) when is_list(value) do
    if length(value) in min..max do
      Enum.with_index(value) |> Enum.flat_map(fn {v, i} -> check(v, type, path ++ [i]) end)
    else
      [error(path, :invalid_count)]
    end
  end

  defp check(value, {:integer, min, max}, path) when is_integer(value),
    do: if(value in min..max, do: [], else: [error(path, :out_of_bounds)])

  defp check(value, {:enum, values}, path),
    do: if(value in values, do: [], else: [error(path, :unsupported)])

  defp check(value, :uuid, path) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> []
      _ -> [error(path, :invalid_id)]
    end
  end

  defp check(value, :digest, path) when is_binary(value),
    do:
      if(Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: [], else: [error(path, :invalid_digest)])

  defp check(nil, {:nullable, _type}, _path), do: []
  defp check(value, {:nullable, type}, path), do: check(value, type, path)

  defp check(value, :sha, path) when is_binary(value),
    do:
      if(Regex.match?(~r/\A[0-9a-f]{40}\z/, value),
        do: [],
        else: [error(path, :invalid_revision)]
      )

  defp check(_value, _type, path), do: [error(path, :invalid_type)]

  defp acceptance do
    {:object,
     %{
       "criteria" => {:list, {:text, 2000}, 1, 32},
       "gates" => {:list, {:enum, @gates}, 1, 1},
       "evidence" => {:list, {:text, 500}, 1, 32}
     }}
  end

  defp execution do
    {:object,
     %{
       "max_attempts" => {:integer, 1, 10},
       "max_runtime_seconds" => {:integer, 1, 86_400},
       "max_response_tokens" => {:integer, 1, 1_000_000},
       "max_tool_calls" => {:integer, 1, 10_000}
     }}
  end

  def event(type, payload) when type in @event_types do
    schema = %{
      "request_id" => {:text, 100},
      "request_digest" => :digest,
      "request" => {:object, request_schema(type)}
    }

    with {:ok, _} <- validate(payload, fn -> schema end) do
      validate_event_semantics(type, payload["request"])
    end
  end

  def event(_type, _payload), do: {:error, [error([], :unsupported_event)]}

  defp validate_event_semantics("cobbler.plan.revision_proposed", request) do
    content = request["content"]

    with {:ok, _order} <- validate_dag(content),
         :ok <- validate_bounds(content["goal"], content) do
      :ok
    end
  end

  defp validate_event_semantics(_type, _request), do: :ok

  defp request_schema("cobbler.plan.goal_defined"), do: %{"contract" => {:object, goal_schema()}}

  defp request_schema("cobbler.plan.revision_proposed"),
    do: %{
      "base_revision" => {:nullable, :uuid},
      "content" => {:object, plan_schema()}
    }

  defp request_schema("cobbler.plan.revision_approved"),
    do: %{
      "revision_id" => :uuid,
      "digest" => :digest
    }

  defp request_schema("cobbler.plan.revision_rejected"),
    do: %{
      "revision_id" => :uuid,
      "digest" => :digest,
      "reason" => {:text, 2000}
    }

  defp goal_schema do
    %{
      "version" => {:enum, [1]},
      "statement" => {:text, 8000},
      "repository" => {:object, %{"reference" => {:text, 500}, "base_revision" => :sha}},
      "constraints" => {:list, {:text, 2000}, 0, 32},
      "non_goals" => {:list, {:text, 2000}, 0, 32},
      "acceptance" => acceptance(),
      "execution" => execution(),
      "budget" =>
        {:object,
         %{
           "max_planning_attempts" => {:integer, 0, 10},
           "max_revisions" => {:integer, 1, 100},
           "max_total_response_tokens" => {:integer, 1, 10_000_000},
           "max_total_tool_calls" => {:integer, 1, 100_000}
         }}
    }
  end

  defp plan_schema do
    %{
      "version" => {:enum, [1]},
      "goal" => {:object, goal_schema()},
      "provenance" =>
        {:object,
         %{
           "kind" => {:enum, ["human"]},
           "version" => {:text, 100},
           "source_context_refs" => {:list, {:text, 500}, 0, 32}
         }},
      "tasks" => {:list, {:object, task_schema()}, 1, 64}
    }
  end

  defp task_schema do
    %{
      "id" => :uuid,
      "title" => {:text, 500},
      "outcome" => {:text, 4000},
      "dependencies" => {:list, :uuid, 0, 63},
      "inputs" => {:list, {:text, 500}, 0, 32},
      "expected_artifacts" => {:list, {:text, 500}, 1, 32},
      "hints" => {:list, {:text, 500}, 0, 32},
      "acceptance" => acceptance(),
      "checkpoint" =>
        {:object,
         %{
           "condition" => {:text, 2000},
           "evidence" => {:list, {:text, 500}, 1, 32}
         }},
      "risk_notes" => {:list, {:text, 2000}, 0, 32},
      "execution" => execution()
    }
  end

  def validate_dag(plan) do
    with {:ok, plan} <- plan(plan) do
      tasks = plan["tasks"]
      ids = Enum.map(tasks, & &1["id"])

      errors =
        if(length(Enum.uniq(ids)) == length(ids),
          do: [],
          else: [error(["tasks"], :duplicate_ids)]
        ) ++
          Enum.flat_map(tasks, fn task ->
            deps = task["dependencies"]
            path = ["tasks", task["id"], "dependencies"]

            []
            |> add_if(length(Enum.uniq(deps)) != length(deps), path, :duplicate_edges)
            |> add_if(task["id"] in deps, path, :self_edge)
            |> add_if(Enum.any?(deps, &(&1 not in ids)), path, :missing_reference)
          end)

      if errors == [], do: order(tasks, [], []), else: {:error, errors}
    end
  end

  def validate_bounds(goal, plan) do
    with {:ok, goal} <- goal(goal),
         {:ok, plan} <- plan(plan) do
      do_validate_bounds(goal, plan)
    end
  end

  defp do_validate_bounds(goal, plan) do
    tasks = plan["tasks"]

    errors =
      Enum.flat_map(tasks, fn task ->
        Enum.flat_map(task["execution"], fn {key, value} ->
          if value <= goal["execution"][key],
            do: [],
            else: [error(["tasks", task["id"], "execution", key], :exceeds_goal)]
        end)
      end)

    errors =
      Enum.reduce(
        [
          {"max_response_tokens", "max_total_response_tokens"},
          {"max_tool_calls", "max_total_tool_calls"}
        ],
        errors,
        fn {task_key, goal_key}, acc ->
          total =
            Enum.sum(
              Enum.map(tasks, &(&1["execution"][task_key] * &1["execution"]["max_attempts"]))
            )

          add_if(acc, total > goal["budget"][goal_key], ["budget", goal_key], :exceeds_budget)
        end
      )

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp add_if(errors, true, path, code), do: errors ++ [error(path, code)]
  defp add_if(errors, false, _path, _code), do: errors
  defp order([], _done, ordered), do: {:ok, Enum.reverse(ordered)}

  defp order(tasks, done, ordered) do
    ready =
      tasks
      |> Enum.filter(fn t -> Enum.all?(t["dependencies"], &(&1 in done)) end)
      |> Enum.sort_by(& &1["id"])

    case ready do
      [] ->
        {:error, [error(["tasks"], :cycle)]}

      [next | _] ->
        order(Enum.reject(tasks, &(&1["id"] == next["id"])), [next["id"] | done], [
          next["id"] | ordered
        ])
    end
  end

  defp error(path, code), do: %{path: path, code: code}
end
