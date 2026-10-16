defmodule Mix.Tasks.Shoestring.Do do
  use Mix.Task
  @shortdoc "Plan, approve and run a request in a Git repository"
  @moduledoc """
      mix shoestring.do "REQUEST" [--repo PATH] [--agent NAME]
          [--gate NAME]... [--test PATH]... [--constraint TEXT]...
          [--by human:NAME] [--no-follow]

  From a clean Git repository (default: the current directory): records a
  goal for REQUEST at the repository's `HEAD`, asks the planner to draft a
  plan, shows it and asks you to approve, edit or decline it. On approval it
  queues the work for the running Shoestring service and follows progress
  (`mix shoestring.follow`), then prints the result (`mix shoestring.result`).

  Checks come from `--gate` (mix_test, mix_precommit, mix_format_check,
  mix_compile_strict) and `--test` (tracked test files), or are detected: a Mix
  project runs `mix_test`; Python with 1-16 `test/**/test_*.py` files runs
  `python_unittest` over them. The planner never chooses them.

  Requires a saved default agent (or `--agent`) whose Worker role names an
  explicit model, a planner (the agent's Claude Coordinator, or
  `config :shoestring, :planner`), and the service running against the same
  state directory. Nothing runs before you approve, and Shoestring never
  changes your repository: the result is a commit you fetch and merge.
  Interrupting this command leaves queued work running.
  """

  alias Shoestring.CLI.{Follow, Result, WorkLoop}

  @switches [
    repo: :string,
    agent: :string,
    gate: :keep,
    test: :keep,
    constraint: :keep,
    by: :string,
    no_follow: :boolean
  ]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    request = Enum.join(positional, " ") |> String.trim()

    if invalid != [] or request == "",
      do: Mix.raise("Invalid arguments. See mix help shoestring.do")

    loop_opts =
      [
        repo: Path.expand(opts[:repo] || File.cwd!()),
        agent: opts[:agent],
        gates: Keyword.get_values(opts, :gate),
        tests: Keyword.get_values(opts, :test),
        constraints: Keyword.get_values(opts, :constraint)
      ]
      |> then(&if opts[:by], do: Keyword.put(&1, :by, opts[:by]), else: &1)

    Shoestring.CLI.Repository.with_repo(fn _repo ->
      case WorkLoop.run(request, loop_opts) do
        {:ok, %{goal_id: goal_id}} ->
          if opts[:no_follow] do
            Mix.shell().info("Follow it with: mix shoestring.follow #{goal_id}")
          else
            by = opts[:by] || WorkLoop.default_human()

            case Follow.run(goal_id, by: by) do
              {:ok, :completed} -> Result.show(goal_id)
              {:ok, _} -> :ok
              {:error, reason} -> Mix.raise("Following stopped: #{inspect(reason)}")
            end
          end

        {:declined, goal_id} ->
          Mix.shell().info(
            "Not approved; nothing runs. The goal and draft stay recorded (#{goal_id})."
          )

        {:error, reason} ->
          Mix.raise(message(reason))
      end
    end)
  end

  @doc false
  def message({:dirty_worktree, paths}),
    do:
      "The repository has uncommitted changes (#{Enum.join(paths, ", ")}). Commit or stash them first."

  def message(:not_a_git_repository),
    do: "Not a Git repository. Run it inside one or pass --repo."

  def message(:no_commits), do: "The repository has no commits yet."
  def message(:not_a_directory), do: "--repo is not a directory."

  def message(:no_gate_detected),
    do: "No checks detected. Pass --test PATH (a tracked test file) or --gate mix_test."

  def message({:too_many_python_tests, count}),
    do: "#{count} Python test files found; name up to 16 with --test."

  def message({:unknown_gate, name}),
    do:
      "Unknown gate #{name}. Use mix_test, mix_precommit, mix_format_check or mix_compile_strict."

  def message({:untracked_test_path, path}), do: "#{path} is not a tracked file."

  def message({:unsupported_test_path, path}),
    do: "#{path} is not a test/**/test_*.py or test/**/*_test.exs file."

  def message(:empty_request), do: "Say what you want done."

  def message(:no_default_agent),
    do:
      "No default agent. Create one: mix shoestring.agents create NAME --worker claude:MODEL --default"

  def message(:agent_not_found), do: "Agent not found. See mix shoestring.agents list."

  def message(:worker_model_required),
    do:
      "The agent's Worker role needs an explicit model: mix shoestring.agents set-role NAME Worker claude:MODEL"

  def message(:worker_role_required),
    do: "The agent needs a Worker role: mix shoestring.agents set-role NAME Worker claude:MODEL"

  def message(:planner_not_configured),
    do:
      "No planner. Give the agent a Claude Coordinator with an explicit model " <>
        "(mix shoestring.agents set-role NAME Coordinator claude:MODEL) or configure :planner."

  def message(:service_unreachable),
    do: "The Shoestring service is not running. Start it in another terminal: mix phx.server"

  def message(:service_uses_another_database),
    do:
      "The running service uses a different state directory than this command. Use the same SHOESTRING_STATE_DIR."

  def message(:service_too_old), do: "The running service is older than this command. Restart it."

  def message({:service_not_ready, status}),
    do: "The service is not ready (HTTP #{status}). See /status."

  def message(:planning_not_confirmed),
    do: "Planning not confirmed; nothing was charged. The goal stays recorded."

  def message(:plan_refused), do: "The drafted plan was refused and not repaired."

  def message({:planning_failed, state, detail}),
    do: "Planning ended without a usable plan (#{state}): #{detail}"

  def message(reason), do: "Refused: #{inspect(reason, limit: 12)}"
end
