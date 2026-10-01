defmodule Shoestring.Cobbler.PlanGraph do
  @moduledoc """
  Deterministic dependency-graph validation and ordering for plan tasks.

  Dependencies are expressed only by stable task ids, never by position, so
  an edit that reorders the task list changes no edge. Validation is
  fail-closed and returns a structured reason — never a boolean and never a
  repaired graph:

    * `{:duplicate_task_ids, [id]}`
    * `{:self_dependency, [id]}`
    * `{:unknown_dependency, [%{task: id, depends_on: id}]}`
    * `{:duplicate_dependency, [%{task: id, depends_on: id}]}`
    * `{:cycle, [id]}` — a deterministic witness cycle, not just "a cycle
      exists", so the caller can show the operator which edges to break.

  Ordering is Kahn's algorithm with the ready set broken by declared index,
  so the same plan always yields the same order on every machine and every
  replay. The order is what later sequential execution consumes; producing
  it here keeps ordering a property of the durable plan rather than of
  whichever process happened to walk it.
  """

  @type task :: %{required(String.t()) => term()}
  @type error ::
          {:duplicate_task_ids, [String.t()]}
          | {:self_dependency, [String.t()]}
          | {:unknown_dependency, [%{task: String.t(), depends_on: String.t()}]}
          | {:duplicate_dependency, [%{task: String.t(), depends_on: String.t()}]}
          | {:cycle, [String.t()]}

  @doc """
  Validates the graph and returns the deterministic topological order.

  Returns `{:ok, [task_id]}` or `{:error, reason}` with a structured reason.
  """
  @spec validate([task()]) :: {:ok, [String.t()]} | {:error, error()}
  def validate(tasks) when is_list(tasks) do
    ids = Enum.map(tasks, &Map.fetch!(&1, "id"))

    with :ok <- check_duplicate_ids(ids),
         :ok <- check_self_dependencies(tasks),
         :ok <- check_duplicate_dependencies(tasks),
         :ok <- check_unknown_dependencies(tasks, MapSet.new(ids)) do
      topological_order(tasks)
    end
  end

  defp check_duplicate_ids(ids) do
    case ids -- Enum.uniq(ids) do
      [] -> :ok
      duplicates -> {:error, {:duplicate_task_ids, duplicates |> Enum.uniq() |> Enum.sort()}}
    end
  end

  defp check_self_dependencies(tasks) do
    offenders =
      for task <- tasks,
          Map.fetch!(task, "id") in dependencies(task),
          do: Map.fetch!(task, "id")

    case offenders do
      [] -> :ok
      ids -> {:error, {:self_dependency, Enum.sort(ids)}}
    end
  end

  defp check_duplicate_dependencies(tasks) do
    offenders =
      for task <- tasks,
          deps = dependencies(task),
          duplicate <- Enum.uniq(deps -- Enum.uniq(deps)),
          do: %{task: Map.fetch!(task, "id"), depends_on: duplicate}

    case offenders do
      [] -> :ok
      pairs -> {:error, {:duplicate_dependency, Enum.sort_by(pairs, &{&1.task, &1.depends_on})}}
    end
  end

  defp check_unknown_dependencies(tasks, known) do
    offenders =
      for task <- tasks,
          dependency <- dependencies(task),
          not MapSet.member?(known, dependency),
          do: %{task: Map.fetch!(task, "id"), depends_on: dependency}

    case offenders do
      [] -> :ok
      pairs -> {:error, {:unknown_dependency, Enum.sort_by(pairs, &{&1.task, &1.depends_on})}}
    end
  end

  # Kahn's algorithm. The ready set is kept sorted by declared index rather
  # than by id, so the order honours how the author wrote the plan while
  # staying a pure function of the plan content.
  defp topological_order(tasks) do
    index = tasks |> Enum.with_index() |> Map.new(fn {task, i} -> {Map.fetch!(task, "id"), i} end)
    remaining = Map.new(tasks, fn task -> {Map.fetch!(task, "id"), dependencies(task)} end)

    drain(remaining, index, [])
  end

  defp drain(remaining, _index, acc) when map_size(remaining) == 0, do: {:ok, Enum.reverse(acc)}

  defp drain(remaining, index, acc) do
    ready =
      remaining
      |> Enum.filter(fn {_id, deps} -> deps == [] end)
      |> Enum.map(fn {id, _deps} -> id end)
      |> Enum.sort_by(&Map.fetch!(index, &1))

    case ready do
      [] ->
        {:error, {:cycle, cycle_witness(remaining, index)}}

      [next | _rest] ->
        remaining =
          remaining
          |> Map.delete(next)
          |> Map.new(fn {id, deps} -> {id, List.delete(deps, next)} end)

        drain(remaining, index, [next | acc])
    end
  end

  # Every node left when nothing is ready either sits on a cycle or depends
  # on one. Walking first-declared edges from the lowest declared index
  # reaches a repeat in bounded steps, and the slice from that repeat is the
  # witness. Deterministic because both the start node and each step are
  # chosen by declared index.
  defp cycle_witness(remaining, index) do
    start =
      remaining
      |> Map.keys()
      |> Enum.min_by(&Map.fetch!(index, &1))

    walk(start, remaining, index, [])
  end

  defp walk(node, remaining, index, visited) do
    if node in visited do
      visited
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 != node))
    else
      next =
        remaining
        |> Map.fetch!(node)
        |> Enum.filter(&Map.has_key?(remaining, &1))
        |> Enum.min_by(&Map.fetch!(index, &1))

      walk(next, remaining, index, [node | visited])
    end
  end

  defp dependencies(task), do: Map.get(task, "depends_on", [])
end
