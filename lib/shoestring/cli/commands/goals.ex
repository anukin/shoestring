defmodule Shoestring.CLI.Commands.Goals do
  @moduledoc "`shoestring goals`: create a goal or list goals."

  import Ecto.Query

  alias Shoestring.CLI.{Command, Refusal}
  alias Shoestring.Trajectory.Goal

  @help """
  shoestring goals create --title TITLE [--description TEXT]
  shoestring goals list

  Starts only the repository. No provider, monitor, planner or execution
  process starts. Output is JSON on stdout (`--json` is accepted and changes
  nothing).

  `create` records a new `active` goal and prints it; pass its `id` as GOAL to
  `shoestring plans`. It plans and approves nothing. The CLI has no
  authenticated identity, so each goal gets a fresh owner ID, as `/runs/new`
  does without a session. `list` prints every goal, newest first, without the
  protected capacity observatory goal.
  """

  def help, do: @help

  def run(args, context) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [title: :string, description: :string, json: :boolean])

    opts = Keyword.delete(opts, :json)

    unless invalid == [] and valid?(positional, opts), do: Refusal.usage!("goals")

    context.with_repo.(fn repo ->
      case positional do
        ["create"] -> create(repo, opts, context)
        ["list"] -> list(repo, context)
      end
    end)
  end

  defp valid?(["create"], opts), do: Keyword.has_key?(opts, :title)
  defp valid?(["list"], opts), do: opts == []
  defp valid?(_positional, _opts), do: false

  defp create(repo, opts, context) do
    attrs = %{title: opts[:title], description: opts[:description]}

    case %Goal{} |> Goal.create_changeset(Ecto.UUID.generate(), attrs) |> repo.insert() do
      {:ok, goal} -> Command.json(context, view(goal))
      {:error, changeset} -> Refusal.refuse!("Goal not created: #{errors(changeset)}")
    end
  end

  defp list(repo, context) do
    from(goal in Goal.user_goals(), order_by: [desc: goal.inserted_at, desc: goal.id])
    |> repo.all()
    |> Enum.map(&view/1)
    |> then(&Command.json(context, &1))
  end

  defp view(%Goal{} = goal) do
    %{
      id: goal.id,
      title: goal.title,
      description: goal.description,
      status: goal.status,
      inserted_at: goal.inserted_at
    }
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
