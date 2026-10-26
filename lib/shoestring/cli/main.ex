defmodule Shoestring.CLI.Main do
  @moduledoc """
  The `shoestring` work commands, the same in both installations (iteration
  12):

  - The installed release runs `main/1` under `bin/shoestring eval`, through
    `shoestringctl`. It opens the state database only when its schema is
    exactly this release's (`Shoestring.CLI.Repository.with_current_repo/1`)
    and never migrates a database the service owns.
  - The source checkout's `bin/shoestring` runs `mix shoestring`, which calls
    `run/2` with `installation: :checkout`; that opens state the way the Mix
    tasks always have.

  Output contract: data on stdout, messages and progress on stderr
  (`Shoestring.CLI.Shell`). A refusal is one line on stderr. Exit status:
  0 success, 1 refused, 2 invalid arguments, 3 the work ended without
  completing (`do` and `follow`).
  """

  alias Shoestring.CLI.{Messages, Refusal, Repository, Shell, WorkLoop}
  alias Shoestring.CLI.Commands

  @commands [
    {"do", Commands.Do},
    {"follow", Commands.Follow},
    {"result", Commands.Result},
    {"review", Commands.Review},
    {"checks", Commands.Checks},
    {"goals", Commands.Goals},
    {"plans", Commands.Plans},
    {"execution", Commands.Execution},
    {"agents", Commands.Agents},
    {"models", Commands.Models},
    {"reservations", Commands.Reservations},
    {"setup", Commands.Setup},
    {"doctor", Commands.Doctor},
    {"grant", Commands.Grant},
    {"grants", Commands.Grants},
    {"dispatch", Commands.Dispatch},
    {"wait", Commands.Wait},
    {"runs", Commands.Runs},
    {"chat", Commands.Chat}
  ]

  @usage """
  usage: shoestring COMMAND [ARGS...]

    setup       check the agent CLIs, record their models and save a default agent
    doctor [--probe-providers]
                check each agent CLI and, with the flag, its version and sign-in
    do "REQUEST" [--agent NAME] [--test PATH]... [--gate NAME]... [--no-follow]
                plan, approve and run REQUEST in the current Git repository
    follow GOAL follow a goal and answer what it waits for
    result GOAL show a completed goal's result and how to take it
    review list|show|accept|reject|retry GOAL [TASK] [--reason TEXT]
                list cross-reviews and decide the ones that wait for you
    checks GOAL [--output N]
                list the checks a goal ran, or print one check's output
    goals | plans | execution | agents | models | reservations ...
                the step-by-step commands

  For a coordinator (Claude Code, Codex or opencode) working under a grant:
    chat [--agent NAME] [--coordinator PROVIDER:MODEL] [--session ID]
                start one in this repository, after granting its session
    grant | grants ...
                give a coordinator session an allowance, or change it
    dispatch --purpose implement --worker PROVIDER:MODEL --title T --brief FILE
                hand Shoestring one task under the session's grant
    wait DISPATCH...
                return when one of them settles
    runs list | show | cancel ...
                the session's dispatches

  `shoestring COMMAND --help` describes a command. Commands that print data
  accept --json. Data goes to stdout; messages and progress go to stderr.
  """

  @service_usage """

  Service commands:
    start       start the service in the foreground (stop it with Ctrl-C)
    init        create and upgrade the state directory without starting
    version     print the installed version
    text | diagnostics-preview | diagnostics-export
                see docs/releases.md
  """

  @doc "Release entry point: runs `argv` and halts with its exit status."
  def main(argv) do
    _ = Application.load(:shoestring)
    log_to_stderr()
    System.halt(run(argv))
  end

  @doc """
  Runs one command and returns its exit status. Options: `:installation`
  (`:release`, the default, or `:checkout`), and for tests `:shell`, `:cwd`,
  `:service` and `:with_repo`.
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ []) do
    context = context(opts)
    shell = context.shell

    case argv do
      [] ->
        shell.error(usage(context))
        2

      [help] when help in ["help", "-h", "--help"] ->
        shell.info(usage(context))
        0

      ["help", name] ->
        run([name, "--help"], opts)

      [name | args] ->
        case List.keyfind(@commands, name, 0) do
          {_, module} when args in [["--help"], ["-h"]] ->
            shell.info(module.help())
            0

          {_, module} ->
            invoke(module, args, context)

          nil ->
            shell.error("shoestring: unknown command '#{name}'")
            shell.error(usage(context))
            2
        end
    end
  end

  @doc "The command names `run/2` accepts."
  def commands, do: Enum.map(@commands, &elem(&1, 0))

  @doc """
  Runs a command module for its Mix task (`mix shoestring.do` and so on):
  the checkout context, the test shell when Mix's shell has been replaced,
  and refusals as `Mix.Error`.
  """
  def mix_task(module, args) do
    shell = if Mix.shell() == Mix.Shell.IO, do: Shell, else: Mix.shell()

    try do
      module.run(args, context(installation: :checkout, shell: shell))
    rescue
      refusal in Refusal -> Mix.raise(refusal.message, exit_status: refusal.exit_status)
    end
  end

  @doc """
  Sends log output to stderr, so stdout carries only data. The release's
  default handler writes to stdout.
  """
  def log_to_stderr do
    with {:ok, handler} <- :logger.get_handler_config(:default),
         false <- get_in(handler, [:config, :type]) == :standard_error,
         :ok <- :logger.remove_handler(:default) do
      config = Map.drop(handler.config, [:type, :file, :modes, :max_no_bytes, :max_no_files])

      :logger.add_handler(
        :default,
        handler.module,
        handler
        |> Map.drop([:id, :module])
        |> Map.put(:config, Map.put(config, :type, :standard_error))
      )
    end

    :ok
  end

  defp invoke(module, args, context) do
    case module.run(args, context) do
      status when is_integer(status) -> status
      _ -> 0
    end
  rescue
    refusal in Refusal ->
      context.shell.error(refusal.message)
      refusal.exit_status
  end

  defp context(opts) do
    installation = Keyword.get(opts, :installation, :release)

    defaults =
      case installation do
        :release ->
          %{with_repo: &release_repo/1, start_hint: "shoestring start"}

        :checkout ->
          %{
            with_repo: &Repository.with_repo/1,
            start_hint: "mix phx.server (in the Shoestring checkout)"
          }
      end

    %{
      installation: installation,
      shell: Shell,
      cwd: File.cwd!(),
      service: &WorkLoop.check_service/0
    }
    |> Map.merge(defaults)
    |> Map.merge(Map.new(Keyword.take(opts, [:shell, :cwd, :service, :with_repo])))
  end

  defp release_repo(fun) do
    case Repository.with_current_repo(fun) do
      {:ok, result} -> result
      {:error, reason} -> Refusal.refuse!(Messages.message(reason))
    end
  end

  defp usage(%{installation: :release}), do: @usage <> @service_usage
  defp usage(_context), do: @usage
end
