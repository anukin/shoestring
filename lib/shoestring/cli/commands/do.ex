defmodule Shoestring.CLI.Commands.Do do
  @moduledoc "`shoestring do`: plan, approve and run a request in a Git repository."

  alias Shoestring.CLI.{Command, Messages, Refusal, WorkLoop}
  alias Shoestring.CLI.Commands.Follow

  @help """
  shoestring do "REQUEST" [--repo PATH] [--agent NAME]
      [--gate NAME]... [--test PATH]... [--constraint TEXT]...
      [--by human:NAME] [--no-follow] [--json]

  From a clean Git repository (default: the current directory): records a
  goal for REQUEST at the repository's `HEAD`, asks the planner to draft a
  plan, shows it and asks you to approve, edit or decline it. On approval it
  queues the work for the running Shoestring service and follows progress
  (`shoestring follow`), then prints the result (`shoestring result`).

  Checks come from `--gate` (mix_test, mix_precommit, mix_format_check,
  mix_compile_strict, or `project:NAME` for a command approved in
  `config :shoestring, :project_gates`) and `--test` (tracked test files), or
  are detected: a Mix project runs `mix_test`; Python with 1-16
  `test/**/test_*.py` files runs `python_unittest` over them. The planner
  never chooses them.

  Requires a saved default agent (or `--agent`) whose Worker role names an
  explicit model, a planner (the agent's Claude Coordinator, or
  `config :shoestring, :planner`), and the service running against the same
  state directory. Nothing runs before you approve, and Shoestring never
  changes your repository: the result is a commit you fetch and merge.
  Interrupting this command leaves queued work running.

  The plan, questions and progress go to stderr. stdout carries the result
  when the goal completes, or the goal id with `--no-follow`. `--json` prints
  one JSON object instead (see docs/cli-output.md). Exit status: 0 completed
  (or queued with `--no-follow`), 1 refused, 2 invalid arguments, 3 ended
  without completing (declined, held, cancelled or waiting for you).
  """

  @switches [
    repo: :string,
    agent: :string,
    gate: :keep,
    test: :keep,
    constraint: :keep,
    by: :string,
    no_follow: :boolean,
    json: :boolean
  ]

  def help, do: @help

  def run(args, context) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    request = Enum.join(positional, " ") |> String.trim()

    if invalid != [] or request == "", do: Refusal.usage!("do")

    loop_opts =
      [
        repo: Command.expand(opts[:repo], context) || context.cwd,
        agent: opts[:agent],
        gates: Keyword.get_values(opts, :gate),
        tests: Keyword.get_values(opts, :test),
        constraints: Keyword.get_values(opts, :constraint),
        shell: context.shell,
        service: context.service
      ]
      |> then(&if opts[:by], do: Keyword.put(&1, :by, opts[:by]), else: &1)

    context.with_repo.(fn _repo ->
      case WorkLoop.run(request, loop_opts) do
        {:ok, %{goal_id: goal_id} = queued} ->
          queued = %{
            goal_id: goal_id,
            execution_id: queued.execution_id,
            revision: queued.revision
          }

          if opts[:no_follow] do
            context.shell.error("Follow it with: shoestring follow #{goal_id}")

            if opts[:json],
              do: Command.json(context, Map.put(queued, :state, "queued")),
              else: context.shell.info(goal_id)

            :ok
          else
            Follow.follow(goal_id, context,
              by: opts[:by] || WorkLoop.default_human(),
              from_execution: true,
              json: opts[:json],
              extra: queued
            )
          end

        {:declined, goal_id} ->
          context.shell.error(
            "Not approved; nothing runs. The goal and draft stay recorded (#{goal_id})."
          )

          if opts[:json], do: Command.json(context, %{goal_id: goal_id, state: "declined"})
          3

        {:error, reason} ->
          Refusal.refuse!(Messages.message(reason, context.start_hint))
      end
    end)
  end
end
