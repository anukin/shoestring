defmodule Shoestring.CLI.Commands.Asks do
  @moduledoc "`shoestring asks`: what workers are waiting on the person for, and the answers."

  import Ecto.Query

  alias Shoestring.{PermissionAsks, Repo}
  alias Shoestring.PermissionAsks.Ask
  alias Shoestring.CLI.{Command, Refusal, Terminal, WorkLoop}

  @help """
  shoestring asks [--session ID | --all] [--json]
  shoestring asks allow ASK [--for-agent] [--by human:NAME]
  shoestring asks deny ASK [--note TEXT] [--by human:NAME]

  A worker whose agent may ask (the Agents page) can ask you, while it works,
  to run one command outside its sandbox. Allowing it runs that one command
  with full access to your files, anywhere you can write; a Codex command's
  network stays as the agent's settings allow, a Claude command has no
  sandbox at all. --for-agent also lets that agent's workers run exactly
  this command again without asking (offered for one plain command, not a
  file change or a command joined with ;, &, | or $(...); the Agents page
  lists and removes these). Denying it lets the worker go on without it;
  --note is the reason it is told. The worker waits for your answer:
  nothing decides an ask on a timer. ASK is its id or the first 8
  characters of it. `allow` and `deny` refuse without a terminal, so an
  agent cannot answer as you. The session is ID or SHOESTRING_SESSION;
  --all lists every session's.
  """

  @switches [
    session: :string,
    all: :boolean,
    json: :boolean,
    note: :string,
    by: :string,
    for_agent: :boolean
  ]

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        context.with_repo.(fn _repo -> list(opts, context) end)

      {opts, [decision, ask], []} when decision in ~w(allow deny) ->
        unless Map.get(context, :interactive?, &Terminal.interactive?/0).(),
          do:
            Refusal.refuse!(
              "Answering a worker's ask is a person's decision: run this yourself, in a terminal. " <>
                "An agent cannot answer as you."
            )

        by = opts[:by] || WorkLoop.default_human()

        decision =
          cond do
            opts[:for_agent] && decision == "allow" -> "allow_agent"
            opts[:for_agent] -> Refusal.refuse!("--for-agent goes with allow.")
            true -> decision
          end

        context.with_repo.(fn _repo ->
          case PermissionAsks.decide(find!(ask).id, decision, by, opts[:note]) do
            {:ok, ask} -> Command.json(context, %{ask: ask.id, state: ask.state})
            {:error, reason} -> Refusal.refuse!(message(reason))
          end
        end)

      _ ->
        Refusal.usage!("asks")
    end
  end

  defp list(opts, context) do
    asks =
      if opts[:all] do
        from(a in Ask, where: a.state == "pending", order_by: [a.inserted_at, a.id])
        |> Repo.all()
        |> Enum.filter(&PermissionAsks.waiting?/1)
      else
        session =
          opts[:session] || Map.get(context, :env, &System.get_env/1).("SHOESTRING_SESSION") ||
            Refusal.refuse!("No session: pass --session ID or --all, or set SHOESTRING_SESSION")

        PermissionAsks.pending(session)
      end

    if opts[:json] do
      Command.json(context, Enum.map(asks, &row/1))
    else
      if asks == [], do: context.shell.info("No worker is waiting on you.")

      for ask <- asks do
        context.shell.info(
          "#{String.slice(ask.id, 0, 8)}  #{ask.agent || "worker"} (#{ask.provider}) asks to run:\n" <>
            "    $ #{ask.command}\n" <>
            if(ask.reason, do: "    why: #{ask.reason}\n", else: "") <>
            "    shoestring asks allow #{String.slice(ask.id, 0, 8)}   |   shoestring asks deny #{String.slice(ask.id, 0, 8)} --note \"...\"" <>
            if(ask.rule_key,
              do:
                "\n    shoestring asks allow #{String.slice(ask.id, 0, 8)} --for-agent   (and again without asking)",
              else: ""
            )
        )
      end
    end
  end

  defp row(ask),
    do: %{
      "ask_id" => ask.id,
      "session_id" => ask.session_id,
      "dispatch_id" => ask.dispatch_id,
      "agent" => ask.agent,
      "provider" => ask.provider,
      "command" => ask.command,
      "reason" => ask.reason,
      "cwd" => ask.cwd,
      "for_agent" => not is_nil(ask.rule_key),
      "asked_at" => ask.inserted_at
    }

  defp find!(prefix) do
    cond do
      not Regex.match?(~r/\A[0-9a-f-]{8,36}\z/, prefix) ->
        Refusal.refuse!(message(:ask_not_found))

      true ->
        case Repo.all(from a in Ask, where: like(a.id, ^"#{prefix}%"), limit: 2) do
          [ask] -> ask
          [] -> Refusal.refuse!(message(:ask_not_found))
          _ -> Refusal.refuse!("More than one ask starts with #{prefix}; give more of its id.")
        end
    end
  end

  def message(:ask_not_found), do: "No such ask."
  def message(:not_pending), do: "That ask was already answered or has ended."
  def message(:ask_gone), do: "That worker is no longer running; its ask has ended."
  def message(:non_human_identity), do: "--by must be human:NAME"
  def message(:invalid_decision), do: "Answer allow or deny."

  def message(:not_ruleable),
    do:
      "That ask cannot be allowed for the agent (a file change, or a command joined with ;, &, | or $(...)); allow it once."

  def message(:agent_gone), do: "Its agent no longer exists; allow it once."

  def message(:too_many_rules),
    do:
      "That agent already has #{Shoestring.Agents.Permissions.max_rules()} commands; remove one on the Agents page."

  def message(:agent_changed), do: "Its agent was just changed; try again."
  def message(other), do: "Not answered: #{inspect(other)}"
end
