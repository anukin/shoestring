defmodule Mix.Tasks.Shoestring.Execution do
  use Mix.Task
  alias Shoestring.Cobbler.ExecutionControl
  @shortdoc "Start or inspect durable approved-plan execution"
  @moduledoc """
  Queue execution for the running Shoestring service. This CLI starts no providers.

      mix shoestring.execution start GOAL --revision N --digest DIGEST --repo PATH --agent ID --agent-revision N --agent-digest DIGEST --role ROLE --by human:NAME
      mix shoestring.execution status GOAL
      mix shoestring.execution check-scopes GOAL
      mix shoestring.execution continue GOAL --execution-id ID
      mix shoestring.execution confirm-capacity GOAL --execution-id ID --task-id TASK --attempt N --scope SCOPE --command-id ID --by human:NAME
      mix shoestring.execution cancel GOAL --execution-id ID [--run-id RUN] --reason TEXT --command-id ID --by human:NAME
      mix shoestring.execution integrate GOAL --execution-id ID --commit SHA --reason TEXT --command-id ID --by human:NAME
      mix shoestring.execution resolve-scope GOAL --execution-id ID --task-id TASK --attempt N --decision accept|reject --reason TEXT --command-id ID --by human:NAME
      mix shoestring.execution handoff GOAL --execution-id ID --run-id ID --checkpoint-id ID --decision-ref ID --role ROLE --scope SCOPE --command-id ID --reason TEXT --by human:NAME [--confirm-capacity]

  Start binds exact approved plan and saved-agent revisions. The service admits
  every new task using current provider observations. Missing capacity holds
  execution; approval alone and closing this CLI never start or stop an Elf.
  Continue repairs delivery of the same intent; it never approves an amendment.
  Handoff selects a role from the same saved agent revision and queues a fresh
  receiver admission. Repeat --decision-ref for the exact current reference set.
  --confirm-capacity permits confirmation-class capacity only, attributed to the
  goal owner; hard stops remain blocked. No provider is started by this CLI.
  The confirm-capacity command records a human confirmation for one admission
  decision of one dependency-ready task attempt, never for future tasks/retries.
  Resolve-scope decides one fan-out scope blocker: accept keeps the tested
  commit and acknowledges exactly its recorded blockers; reject resolves the
  attempt as failed within the plan's attempt limits. Neither merges branches.
  Integrate records a commit you made by merging accepted branches yourself;
  it must contain the approved base and every accepted commit. Shoestring only
  reads your repository and never merges. Remaining dependents continue from it.
  Cancel queues explicit service-owned cancellation: with --run-id it stops one
  unresolved child; without it, every unresolved child of the execution, and no
  further work is dispatched or continued for that execution.
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
    task_id: :string,
    attempt: :integer,
    run_id: :string,
    checkpoint_id: :string,
    decision_ref: :string,
    scope: :string,
    command_id: :string,
    reason: :string,
    decision: :string,
    commit: :string,
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

            "check-scopes" ->
              Shoestring.Cobbler.PlanScopeCheck.record(goal_id)

            "integrate" ->
              case ExecutionControl.integrate(goal_id, %{
                     execution_id: opts[:execution_id],
                     commit: opts[:commit],
                     reason: opts[:reason],
                     command_id: opts[:command_id],
                     requested_by: opts[:by]
                   }) do
                {:ok, event} -> {:ok, %{event_id: event.id, integration: event.payload}}
                error -> error
              end

            "resolve-scope" ->
              case ExecutionControl.resolve_scope(goal_id, %{
                     execution_id: opts[:execution_id],
                     task_id: opts[:task_id],
                     attempt: opts[:attempt],
                     decision: opts[:decision],
                     reason: opts[:reason],
                     command_id: opts[:command_id],
                     requested_by: opts[:by]
                   }) do
                {:ok, event} -> {:ok, %{event_id: event.id, resolution: event.payload}}
                error -> error
              end

            "confirm-capacity" ->
              case ExecutionControl.confirm_capacity(goal_id, %{
                     execution_id: opts[:execution_id],
                     task_id: opts[:task_id],
                     attempt: opts[:attempt],
                     scope: opts[:scope],
                     command_id: opts[:command_id],
                     requested_by: opts[:by]
                   }) do
                {:ok, event} -> {:ok, %{event_id: event.id, confirmation: event.payload}}
                error -> error
              end

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

  defp execute("cancel", goal_id, opts, client) do
    ExecutionControl.cancel(
      goal_id,
      %{
        execution_id: opts[:execution_id],
        run_id: opts[:run_id],
        reason: opts[:reason],
        command_id: opts[:command_id],
        requested_by: opts[:by]
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
        "status" ->
          []

        "check-scopes" ->
          []

        "continue" ->
          [:execution_id]

        "confirm-capacity" ->
          [:execution_id, :task_id, :attempt, :scope, :command_id, :by]

        "resolve-scope" ->
          [:execution_id, :task_id, :attempt, :decision, :reason, :command_id, :by]

        "integrate" ->
          [:execution_id, :commit, :reason, :command_id, :by]

        "cancel" ->
          if Keyword.has_key?(opts, :run_id),
            do: [:execution_id, :run_id, :reason, :command_id, :by],
            else: [:execution_id, :reason, :command_id, :by]

        "start" ->
          [:revision, :digest, :repo, :agent, :agent_revision, :agent_digest, :role, :by]

        _ ->
          nil
      end

    is_list(required) and Enum.sort(Keyword.keys(opts)) == Enum.sort(required) and
      Enum.all?(opts, fn
        {key, value} when key in [:revision, :agent_revision, :attempt] -> value > 0
        {_, value} -> String.trim(value) != ""
      end)
  end
end
