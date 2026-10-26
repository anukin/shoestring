defmodule Shoestring.CLI.Commands.Chat do
  @moduledoc """
  `shoestring chat`: start the coordinator CLI a person chats with. Elixir
  prepares the session and writes a launch script; the `shoestring` wrapper
  (`bin/shoestring`, `shoestringctl`) then `exec`s it, so the coordinator's
  terminal interface owns the terminal.
  """

  alias Shoestring.{AgentProfiles, Dispatches, Grants, Harnesses, ModelCatalog}
  alias Shoestring.CLI.{Command, Messages, Refusal}
  alias Shoestring.CLI.Commands.Grant
  alias Shoestring.Coordinator

  @help """
  shoestring chat [--agent NAME] [--coordinator PROVIDER:MODEL] [--session ID]
  shoestring chat list [--json]

  Starts a coordinator in this repository: the coding CLI you chat with
  (Claude Code, Codex or opencode), told how to hand tasks to Shoestring
  with `shoestring dispatch`. The CLI and model are the agent's Coordinator
  role (NAME, else the default agent), or --coordinator for this session
  only. The service must be running.

  A new session (or --session ID without a grant) first shows the grant it
  proposes — the agent's other roles' models, every purpose and the default
  limits of `shoestring grant` — and asks; it does not start without one.
  --session ID continues an earlier session under its grant; the
  coordinator CLI starts a new conversation and can read what was
  dispatched with `shoestring runs list`.

  The coordinator runs as your own session of that CLI, under its own
  permission prompts. Its instructions say not to edit this checkout and to
  delegate every change. `chat list` prints the sessions with their grants
  and dispatches. Needs a terminal.
  """

  @switches [
    agent: :string,
    coordinator: :string,
    session: :string,
    launch_file: :string,
    json: :boolean
  ]

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: @switches) do
      {_opts, ["list"], []} ->
        context.with_repo.(fn _repo -> Command.json(context, sessions()) end)

      {opts, [], []} ->
        Grant.terminal!(context)

        case context.service.() do
          :ok -> :ok
          {:error, reason} -> Refusal.refuse!(Messages.message(reason, context.start_hint))
        end

        context.with_repo.(fn _repo -> chat(opts, context) end)

      _ ->
        Refusal.usage!("chat")
    end
  end

  defp chat(opts, context) do
    {agent, roles} = agent!(opts[:agent])
    find = Map.get(context, :find, &System.find_executable/1)
    coordinator = coordinator!(opts[:coordinator], roles, find)
    session = opts[:session] || Grants.new_session_id()
    grant = Grants.active(session) || grant!(session, roles, coordinator, context)

    command = command(context)
    dir = Path.join([Shoestring.State.root(), "chat", session])
    File.mkdir_p!(dir)

    instructions =
      Coordinator.instructions(%{
        session: session,
        grant: grant,
        roles: roles,
        agent_instructions: agent && agent.instructions,
        command: command
      })

    path = Path.join(dir, "instructions.md")
    File.write!(path, instructions)

    File.write!(
      Path.join(dir, "session.json"),
      Jason.encode!(%{
        "session_id" => session,
        "agent" => agent && agent.slug,
        "coordinator" => "#{coordinator["provider"]}:#{coordinator["model"]}",
        "repository_root" => grant.repository_root,
        "started_at" => DateTime.utc_now()
      })
    )

    launch =
      Coordinator.launch(
        coordinator["provider"],
        coordinator["model"],
        coordinator["effort"],
        instructions,
        path,
        session
      )

    script = Coordinator.script(launch, context.cwd)

    context.shell.error(
      "Starting #{Harnesses.name(coordinator["provider"])} (#{coordinator["model"]}) as the " <>
        "coordinator of session #{session}."
    )

    case opts[:launch_file] do
      nil ->
        Command.json(context, %{
          "session_id" => session,
          "argv" => launch.argv,
          "script" => script
        })

      file ->
        File.write!(file, script)
        :ok
    end
  end

  defp agent!(nil) do
    case AgentProfiles.default_snapshot() do
      {:ok, snapshot} ->
        {AgentProfiles.get(snapshot["profile_id"]), snapshot["configuration"]["roles"]}

      {:error, _} ->
        Refusal.refuse!(Messages.message(:no_default_agent))
    end
  end

  defp agent!(name) do
    case AgentProfiles.snapshot(name) do
      {:ok, snapshot} ->
        {AgentProfiles.get(snapshot["profile_id"]), snapshot["configuration"]["roles"]}

      {:error, _} ->
        Refusal.refuse!(Messages.message(:agent_not_found))
    end
  end

  defp coordinator!(nil, roles, find) do
    case Enum.find(roles, &(&1["name"] == "Coordinator")) do
      nil ->
        Refusal.refuse!("The agent has no Coordinator role; pass --coordinator PROVIDER:MODEL")

      role ->
        check!(role, find)
    end
  end

  defp coordinator!(value, _roles, find) do
    case String.split(value, ":", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        check!(%{"name" => "Coordinator", "provider" => provider, "model" => model}, find)

      _ ->
        Refusal.refuse!("Use PROVIDER:MODEL for --coordinator, for example claude:opus")
    end
  end

  defp check!(%{"provider" => provider, "model" => model} = role, find) do
    cond do
      not Harnesses.supports?(provider, :coordinate) ->
        Refusal.refuse!("#{Harnesses.name(provider)} cannot coordinate.")

      model != "default" and model not in ModelCatalog.enabled(provider) ->
        Refusal.refuse!(
          "#{provider}:#{model} is not an enabled model. See shoestring models show."
        )

      find.(provider) == nil ->
        Refusal.refuse!("The #{provider} CLI is not on PATH.")

      true ->
        role
    end
  end

  # The grant a new session proposes: every other role's model the grant can
  # use, all purposes, the default limits. A person confirms it here, at
  # this terminal.
  defp grant!(session, roles, coordinator, context) do
    models =
      roles
      |> Enum.reject(&(&1["name"] == "Coordinator"))
      |> Enum.map(&"#{&1["provider"]}:#{&1["model"]}")
      |> Enum.reject(&String.ends_with?(&1, ":default"))
      |> Enum.uniq()
      |> case do
        [] -> ["#{coordinator["provider"]}:#{coordinator["model"]}"]
        models -> models
      end

    attrs = %{
      session_id: session,
      repository_root: root!(context.cwd),
      models: models,
      purposes: Grants.purposes(),
      max_dispatches: 10,
      max_parallel: 3,
      max_total_seconds: 4 * 3600,
      max_dispatch_seconds: 3600,
      unread_usage: 0
    }

    Grant.describe(attrs, context)
    context.shell.error("Widen it later with shoestring grants extend.")

    unless Grant.confirmed?(context, "Grant this and start? [y/N] "),
      do: Refusal.refuse!("Not started: the session needs a grant (shoestring grant).")

    case Grants.create(attrs, Shoestring.CLI.WorkLoop.default_human()) do
      {:ok, grant} -> grant
      {:error, reason} -> Refusal.refuse!("Not granted: #{Grant.reason_text(reason)}")
    end
  end

  defp root!(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> String.trim(root)
      _ -> Refusal.refuse!("Not a Git repository. Run shoestring chat inside one.")
    end
  end

  # How the coordinator's shell calls Shoestring: the checkout's wrapper by
  # path, or the installed command.
  defp command(%{installation: :checkout}), do: Path.join(File.cwd!(), "bin/shoestring")

  defp command(_context) do
    cond do
      System.find_executable("shoestring") -> "shoestring"
      root = System.get_env("RELEASE_ROOT") -> Path.join(root, "bin/shoestringctl")
      true -> "shoestring"
    end
  end

  defp sessions do
    for grant <- Grants.list() do
      meta =
        [Shoestring.State.root(), "chat", grant.session_id, "session.json"]
        |> Path.join()
        |> File.read()
        |> case do
          {:ok, json} -> Jason.decode!(json)
          _ -> %{}
        end

      %{
        "session_id" => grant.session_id,
        "coordinator" => meta["coordinator"],
        "agent" => meta["agent"],
        "grant" => Grant.show(grant),
        "dispatches" => length(Dispatches.list(grant.session_id))
      }
    end
  end
end
