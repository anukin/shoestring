defmodule Mix.Tasks.Shoestring.Execution do
  use Mix.Task
  alias Shoestring.Cobbler.ExecutionControl
  @shortdoc "Start or inspect durable approved-plan execution"
  @moduledoc """
  Queue execution for the running Shoestring service. This CLI starts no providers.

      mix shoestring.execution start GOAL --revision N --digest DIGEST --repo PATH --agent ID --agent-revision N --agent-digest DIGEST --role ROLE --by human:NAME
      mix shoestring.execution status GOAL
      mix shoestring.execution continue GOAL --execution-id ID

  Start binds exact approved plan and saved-agent revisions. The service admits
  every new task using current provider observations. Missing capacity holds
  execution; approval alone and closing this CLI never start or stop an Elf.
  Continue repairs delivery of the same intent; it never approves an amendment.
  """
  @switches [
    revision: :integer,
    digest: :string,
    repo: :string,
    agent: :string,
    agent_revision: :integer,
    agent_digest: :string,
    role: :string,
    by: :string,
    execution_id: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: Enum.map(@switches, fn {key, type} -> {key, [type, :keep]} end)
      )

    with [command, goal_id] <- positional,
         {:ok, goal_id} <- Ecto.UUID.cast(goal_id),
         true <- invalid == [] and valid?(command, opts) do
      Shoestring.CLI.Repository.with_repo(fn _ ->
        if is_nil(Shoestring.Repo.get(Shoestring.Trajectory.Goal, goal_id)),
          do: Mix.raise("Goal not found")

        result =
          case command do
            "status" ->
              ExecutionControl.status(goal_id)

            _ ->
              Shoestring.CLI.Jobs.with_client(fn client ->
                execute(command, goal_id, opts, client)
              end)
          end

        case result do
          {:ok, output} ->
            Mix.shell().info(Jason.encode!(output, pretty: true))

          {:error, reason} ->
            Mix.raise("Execution request refused: #{inspect(reason, limit: 20)}")
        end
      end)
    else
      _ -> Mix.raise("Invalid arguments. See mix help shoestring.execution")
    end
  end

  defp execute("start", goal_id, opts, client) do
    ExecutionControl.start(
      goal_id,
      %{
        revision_number: opts[:revision],
        digest: opts[:digest],
        repository_path: opts[:repo],
        requested_by: opts[:by],
        agent_profile: %{
          "profile_id" => opts[:agent],
          "revision" => opts[:agent_revision],
          "digest" => opts[:agent_digest],
          "role" => opts[:role]
        }
      },
      oban: client
    )
  end

  defp execute("continue", goal_id, opts, client),
    do: ExecutionControl.continue(goal_id, opts[:execution_id], oban: client)

  defp valid?(command, opts) do
    required =
      case command do
        "status" -> []
        "continue" -> [:execution_id]
        "start" -> [:revision, :digest, :repo, :agent, :agent_revision, :agent_digest, :role, :by]
        _ -> nil
      end

    is_list(required) and Enum.sort(Keyword.keys(opts)) == Enum.sort(required) and
      Enum.all?(opts, fn
        {key, value} when key in [:revision, :agent_revision] -> value > 0
        {_, value} -> String.trim(value) != ""
      end)
  end
end
