defmodule Shoestring.CLI.Commands.Chat do
  @moduledoc """
  `shoestring chat`: start the coordinator CLI a person chats with. Elixir
  prepares the session and writes a launch script; the `shoestring` wrapper
  (`bin/shoestring`, `shoestringctl`) then `exec`s it, so the coordinator's
  terminal interface owns the terminal.
  """

  alias Shoestring.{AgentProfiles, Conversations, Dispatches, Grants, Harnesses, ModelCatalog}
  alias Shoestring.CLI.{Command, Messages, Refusal}
  alias Shoestring.CLI.Commands.Grant
  alias Shoestring.Coordinator
  alias Shoestring.Conversations.ChatToken

  @help """
  shoestring chat [--agent NAME] [--coordinator PROVIDER:MODEL] [--session ID] [--external]
  shoestring chat list [--json]

  Opens Shoestring's chat screen in this repository. You talk to a
  coordinator (Claude Code, Codex or opencode, driven by the service,
  read-only in this checkout) that hands tasks to Shoestring with its tools;
  the screen shows the conversation, every dispatch and the grant. The
  coordinator and model are the agent's Coordinator role (NAME, else the
  default agent), or --coordinator for this session only. The service must
  be running.

  --session ID reattaches an earlier session: its whole conversation is
  shown again and its coordinator resumes where it left off. Leaving the
  screen (/exit) leaves the conversation and every dispatch running. In the
  screen, /handoff continues a long session in a fresh conversation with the
  same grant and dispatches; --session then reattaches the fresh one.

  --external starts the coordinator's own CLI in this terminal instead
  (Claude Code, Codex or opencode), told how to hand tasks to Shoestring with
  `shoestring dispatch`, as before.

  A new session (or --session ID without a grant) first shows the grant it
  proposes — the agent's other roles' models, every purpose and the default
  limits of `shoestring grant` — and asks; it does not start without one.
  --session ID continues an earlier session under its grant; the
  coordinator CLI starts a new conversation and can read what was
  dispatched with `shoestring runs list`.

  With --external the coordinator runs as your own session of that CLI,
  under its own permission prompts; its instructions say not to edit this
  checkout and to delegate every change. `chat list` prints the sessions with
  their grants and dispatches. Needs a terminal.
  """

  @switches [
    agent: :string,
    coordinator: :string,
    session: :string,
    launch_file: :string,
    external: :boolean,
    json: :boolean
  ]

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: @switches) do
      {_opts, ["list"], []} ->
        context.with_repo.(fn _repo -> Command.json(context, sessions()) end)

      {opts, [], []} ->
        Grant.terminal!(context)

        # Inside the repository: a checkout knows its database only then, and
        # the check compares it with the service's.
        context.with_repo.(fn _repo ->
          case context.service.() do
            :ok -> :ok
            {:error, reason} -> Refusal.refuse!(Messages.message(reason, context.start_hint))
          end

          chat(opts, context)
        end)

      _ ->
        Refusal.usage!("chat")
    end
  end

  defp chat(opts, context) do
    {agent, roles} = agent!(opts[:agent])
    find = Map.get(context, :find, &System.find_executable/1)
    coordinator = coordinator!(opts[:coordinator], roles, find)

    if opts[:external],
      do: external(opts, context, agent, roles, coordinator),
      else: native(opts, context, agent, roles, coordinator)
  end

  # The chat screen: the service drives the coordinator; this terminal runs
  # the client, which `bin/shoestring` execs from the launch file.
  defp native(opts, context, agent, roles, coordinator) do
    converses!(coordinator)
    client = client!(context)
    session = opts[:session] || Grants.new_session_id()
    grant = Grants.active(session) || grant!(session, roles, coordinator, context)
    conversation = conversation!(session, coordinator, grant)

    instructions =
      Coordinator.conversation_instructions(%{
        session: session,
        grant: grant,
        roles: roles,
        agent_instructions: agent && agent.instructions
      })

    path = Conversations.instructions_path(session)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, instructions)

    token_file =
      case ChatToken.ensure(session) do
        {:ok, _token} ->
          ChatToken.path(session)

        {:error, reason} ->
          Refusal.refuse!("Could not prepare the chat token: #{inspect(reason)}")
      end

    argv = [client, "--url", socket_url(), "--session", session, "--token-file", token_file]

    context.shell.error(
      "Opening session #{session}: #{Harnesses.name(conversation.provider)} " <>
        "(#{conversation.model}) coordinates, read-only in #{conversation.repository_root}."
    )

    case opts[:launch_file] do
      nil ->
        Command.json(context, %{"session_id" => session, "argv" => argv})

      file ->
        File.write!(file, Coordinator.script(%{argv: argv, env: []}, context.cwd))
        :ok
    end
  end

  defp converses!(%{"provider" => provider, "model" => model}) do
    cond do
      not Harnesses.supports?(provider, :converse) ->
        Refusal.refuse!(
          "#{Harnesses.name(provider)} cannot coordinate in the chat screen yet " <>
            "(#{Harnesses.offering(:converse)} can). Use --external to start its own CLI."
        )

      model == "default" ->
        Refusal.refuse!(
          "The chat screen needs an explicit coordinator model; pass --coordinator PROVIDER:MODEL."
        )

      true ->
        :ok
    end
  end

  @doc "Native client location in a checkout or relocated installed release."
  def client_path do
    System.get_env("SHOESTRING_CHAT_CLIENT") ||
      Application.app_dir(:shoestring, "priv/bin/shoestring-chat")
  end

  defp client!(context) do
    path =
      Map.get_lazy(context, :chat_client, &client_path/0)

    if File.regular?(path),
      do: path,
      else:
        Refusal.refuse!(
          "The chat client is not installed (#{path}). In a checkout: mix chat_client.check. " <>
            "Or use --external."
        )
  end

  defp conversation!(session, coordinator, grant) do
    attrs = %{
      session_id: session,
      provider: coordinator["provider"],
      model: coordinator["model"],
      effort: coordinator["effort"],
      repository_root: grant.repository_root
    }

    case Conversations.open(attrs) do
      {:ok, conversation} ->
        conversation

      {:error, :conversation_has_another_coordinator} ->
        existing = Conversations.get(session)

        Refusal.refuse!(
          "Session #{session} already has #{existing.provider}:#{existing.model} as its " <>
            "coordinator. Reattach with --coordinator #{existing.provider}:#{existing.model}, " <>
            "or start a new session."
        )

      {:error, reason} ->
        Refusal.refuse!("Could not open the conversation: #{inspect(reason)}")
    end
  end

  defp socket_url do
    http = Application.get_env(:shoestring, ShoestringWeb.Endpoint, [])[:http] || []
    "ws://127.0.0.1:#{Keyword.get(http, :port, 4000)}/chat/socket"
  end

  defp external(opts, context, agent, roles, coordinator) do
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
      unread_usage: 0,
      max_turns: 20
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
