defmodule Shoestring.CLI.Commands.Follow do
  @moduledoc "`shoestring follow`: follow a goal and answer what it waits for."

  alias Shoestring.CLI.{Command, Follow, Messages, Refusal, Result, WorkLoop}
  alias Shoestring.Cobbler.ExecutionControl

  @help """
  shoestring follow GOAL [--by human:NAME] [--json]

  Prints the goal's progress from its durable history, asks you to confirm
  capacity when a task attempt is held for it, and prints the result when the
  goal completes. Interrupting it leaves the work running; run it again to
  re-attach. It never starts, stops or cancels work.

  Progress and questions go to stderr; stdout carries the result when the goal
  completes. `--json` prints one JSON object instead (see docs/cli-output.md).
  A goal that has not finished needs the running service; without it this
  refuses and says how to start it. Exit status: 0 completed, 1 refused,
  2 invalid arguments, 3 ended without completing (held, cancelled or
  waiting for you).
  """

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: [by: :string, json: :boolean]) do
      {opts, [goal], []} ->
        goal_id = Command.goal_id!(goal)

        context.with_repo.(fn _repo ->
          unless finished?(goal_id) do
            with {:error, reason} <- context.service.() do
              Refusal.refuse!(Messages.message(reason, context.start_hint))
            end
          end

          follow(goal_id, context, by: opts[:by] || WorkLoop.default_human(), json: opts[:json])
        end)

      _ ->
        Refusal.usage!("follow")
    end
  end

  @doc """
  Follows `goal_id` and prints its outcome; `do` shares it. Options: `:by`,
  `:from_execution`, `:json`, and `:extra` (fields added to the JSON object).
  Returns the exit status.
  """
  def follow(goal_id, context, opts) do
    follow_opts = [
      by: Keyword.fetch!(opts, :by),
      from_execution: Keyword.get(opts, :from_execution, false),
      shell: context.shell
    ]

    report =
      opts |> Keyword.get(:extra, %{}) |> Map.put(:goal_id, goal_id)

    case Follow.run(goal_id, follow_opts) do
      {:ok, :completed} ->
        completed = Map.put(report, :state, "completed")

        case {opts[:json] == true, Result.fetch(goal_id)} do
          {true, {:ok, data}} ->
            Command.json(context, Map.put(completed, :result, data))

          {true, {:error, reason}} ->
            Command.json(context, Map.put(completed, :result_error, inspect(reason)))

          {false, {:ok, data}} ->
            Result.print(data, context.shell)

          {false, {:error, reason}} ->
            context.shell.error("No result: #{inspect(reason)}")
        end

        :ok

      {:ok, outcome} ->
        if opts[:json],
          do: Command.json(context, Map.put(report, :state, Atom.to_string(outcome)))

        3

      {:error, reason} ->
        Refusal.refuse!("Following stopped: #{inspect(reason)}")
    end
  end

  defp finished?(goal_id) do
    case ExecutionControl.status(goal_id) do
      {:ok, status} -> status[:completed?] == true or status[:cancelled?] == true
      _ -> false
    end
  end
end
