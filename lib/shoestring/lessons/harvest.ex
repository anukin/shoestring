defmodule Shoestring.Lessons.Harvest do
  @moduledoc """
  Reads the lessons a worker proposed through its dispatch (iteration 16 B)
  and proposes them under its agent, with the dispatch as their source:

    * an IMPLEMENT's worker writes them to `Shoestring.Lessons.lessons_file/0`
      in its worktree, one `- ` line each; that path is excluded from its
      commits in Shoestring's private storage;
    * an EXPLORE's or REVIEW's report carries them in `lessons`.

  At most three per run or call, read once the dispatch has settled. Each
  has an origin (run or call, and its place), so reading again adds nothing.
  A proposal the checks refuse is left out; the worker's agent may have no
  right to propose at all.
  """
  import Ecto.Query

  alias Shoestring.{Dispatches, Lessons, Repo, Worktrees}
  alias Shoestring.Dispatches.{Calls, Dispatch}
  alias Shoestring.Harness.RunRecord

  @max_file 8192
  @per_source 3
  @settled ~w(completed failed needs_you cancelled)

  @doc "Proposes what `dispatch`'s worker left, once it has settled. Returns the lessons it added."
  def dispatch(%Dispatch{} = dispatch) do
    if Dispatches.state(dispatch) in @settled do
      dispatch
      |> proposals()
      |> Enum.flat_map(fn {origin, text} ->
        proposer = %{
          session_id: dispatch.session_id,
          role: Dispatches.worker_role(dispatch.purpose),
          agent: dispatch.agent,
          dispatch_id: dispatch.id,
          origin_key: origin
        }

        case Lessons.propose(%{"text" => text}, proposer) do
          {:ok, lesson} -> [lesson]
          {:error, _refused_or_already_read} -> []
        end
      end)
    else
      []
    end
  end

  def dispatch(_dispatch), do: []

  @doc "The lessons proposed through `dispatch` by its worker, newest first."
  def proposed_by_worker(%Dispatch{id: id}),
    do: Enum.reject(Lessons.list(source_ref: id), &(&1.proposer_role == "coordinator"))

  defp proposals(%Dispatch{purpose: "implement", goal_id: goal_id}) when is_binary(goal_id) do
    Repo.all(from r in RunRecord, where: r.goal_id == ^goal_id, order_by: [r.inserted_at, r.id])
    |> Enum.flat_map(fn run ->
      with {:ok, worktree} <- Worktrees.get(run.id),
           {:ok, text} <- read(Path.join(worktree.path, Lessons.lessons_file())) do
        text
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.flat_map(fn
          "- " <> lesson -> [String.trim(lesson)]
          "* " <> lesson -> [String.trim(lesson)]
          _ -> []
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(@per_source)
        |> Enum.with_index(1)
        |> Enum.map(fn {lesson, n} -> {"run:#{run.id}:#{n}", lesson} end)
      else
        _ -> []
      end
    end)
  end

  defp proposals(%Dispatch{purpose: purpose} = dispatch) when purpose in ~w(explore review) do
    with %{id: call_id} = call <- Calls.get(dispatch.id),
         %{"lessons" => [_ | _] = lessons} <- Calls.report(call) do
      lessons
      |> Enum.take(@per_source)
      |> Enum.with_index(1)
      |> Enum.map(fn {lesson, n} -> {"call:#{call_id}:#{n}", lesson} end)
    else
      _ -> []
    end
  end

  defp proposals(_dispatch), do: []

  # A file in a worker's worktree: a regular file, bounded, never followed
  # through a link.
  defp read(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= @max_file -> File.read(path)
      _ -> :none
    end
  end
end
