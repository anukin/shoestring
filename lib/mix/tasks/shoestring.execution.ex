defmodule Mix.Tasks.Shoestring.Execution do
  use Mix.Task
  alias Shoestring.Cobbler.ExecutionControl
  @shortdoc "Start or inspect durable approved-plan execution"
  @moduledoc """
  Queue execution for the running Shoestring service. This CLI starts no providers.

      mix shoestring.execution start GOAL --revision N --digest DIGEST --repo PATH --agent ID --agent-revision N --agent-digest DIGEST --role ROLE --by human:NAME
      mix shoestring.execution status GOAL
      mix shoestring.execution continue GOAL --execution-id ID
      mix shoestring.execution handoff GOAL --execution-id ID --run-id ID --checkpoint-id ID --decision-ref ID --role ROLE --scope SCOPE --command-id ID --reason TEXT --by human:NAME [--confirm-capacity]

  Start binds exact approved plan and saved-agent revisions. The service admits
  every new task using current provider observations. Missing capacity holds
  execution; approval alone and closing this CLI never start or stop an Elf.
  Continue repairs delivery of the same intent; it never approves an amendment.
  Handoff selects a role from the same saved agent revision and queues a fresh
  receiver admission. Repeat --decision-ref for the exact current reference set.
  --confirm-capacity permits confirmation-class capacity only, attributed to the
  goal owner; hard stops remain blocked. No provider is started by this CLI.
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
    execution_id: :string,
    run_id: :string,
    checkpoint_id: :string,
    decision_ref: :string,
    scope: :string,
    command_id: :string,
    reason: :string,
    confirm_capacity: :boolean
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

  defp execute("handoff", goal_id, opts, client) do
    ExecutionControl.handoff(
      goal_id,
      %{
        execution_id: opts[:execution_id],
        run_id: opts[:run_id],
        checkpoint_id: opts[:checkpoint_id],
        decision_refs: Keyword.get_values(opts, :decision_ref),
        receiver_role: opts[:role],
        scope: opts[:scope],
        command_id: opts[:command_id],
        reason: opts[:reason],
        requested_by: opts[:by],
        confirm_capacity: opts[:confirm_capacity]
      },
      oban: client
    )
  end

  defp valid?("handoff", opts) do
    required = [:execution_id, :run_id, :checkpoint_id, :role, :scope, :command_id, :reason, :by]
    singles = Keyword.drop(opts, [:decision_ref, :confirm_capacity])
    refs = Keyword.get_values(opts, :decision_ref)

    Enum.sort(Keyword.keys(singles)) == Enum.sort(required) and
      length(Keyword.get_values(opts, :confirm_capacity)) <= 1 and refs != [] and
      length(refs) == length(Enum.uniq(refs)) and
      Enum.all?(singles ++ Enum.map(refs, &{:decision_ref, &1}), fn {_, value} ->
        String.trim(value) != ""
      end)
  end

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
