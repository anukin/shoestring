defmodule Shoestring.CLI.Commands.Grant do
  @moduledoc "`shoestring grant`: a person gives a coordinator session an allowance."

  alias Shoestring.{Dispatches, Grants}
  alias Shoestring.CLI.{Command, Refusal, Terminal, WorkLoop}

  @help """
  shoestring grant --models PROVIDER:MODEL[,PROVIDER:MODEL...]
      [--purposes explore,implement,review] [--max-dispatches N]
      [--max-parallel N] [--max-hours H] [--max-dispatch-minutes M]
      [--unread-usage N] [--max-turns N] [--units NAME=CAP/RESERVE]...
      [--session ID] [--repo PATH]
      [--team NAME] [--by human:NAME] [--json]

  Lets a coordinator (Claude Code, Codex or opencode in a chat session) hand
  work to Shoestring without asking you each time, within these limits:

    --models                the only models it may dispatch to (enabled ones)
    --team NAME             snapshot this team's agents, limits and switches
    --purposes              what it may dispatch (default: explore,implement,review;
                            add external for work done outside Shoestring)
    --units NAME=CAP/RESERVE
                            a named budget for EXTERNAL work, for example
                            flow_credits=200/40: at most CAP in total, RESERVE
                            held per EXTERNAL until it settles (at most 4)
    --max-dispatches N      attempts in total, retries included (default 10)
    --max-parallel N        dispatches queued or running at once (default 3).
                            At Settings' parallel tasks 1 they run one after
                            another; at 2 or more, up to that many run side by
                            side when each names separate files with --file
    --max-hours H           total time its dispatches may use (default 4)
    --max-dispatch-minutes  the most one dispatch may use (default 60)
    --unread-usage N        dispatches it may start when a provider's
                            remaining usage cannot be read (default 0)
    --max-turns N           turns a coordinator conversation Shoestring
                            drives may take, wake-ups included (default 20)

  The grant covers one repository (PATH, default the current one) and one
  session: ID, or a new one, which it prints for SHOESTRING_SESSION. A
  dispatch outside it is refused, never queued; widen it with
  `shoestring grants extend`. It shows the grant and asks before saving, and
  refuses without a terminal: a coordinator cannot grant itself. The
  standing usage reserves still apply to every dispatch. Output is JSON on
  stdout.
  """

  @switches [
    models: :string,
    team: :string,
    purposes: :string,
    max_dispatches: :integer,
    max_parallel: :integer,
    max_hours: :integer,
    max_dispatch_minutes: :integer,
    unread_usage: :integer,
    max_turns: :integer,
    units: :keep,
    session: :string,
    repo: :string,
    by: :string,
    json: :boolean
  ]

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        unless opts[:models], do: Refusal.usage!("grant")
        terminal!(context)
        context.with_repo.(fn _repo -> grant(opts, context) end)

      _ ->
        Refusal.usage!("grant")
    end
  end

  @doc false
  def terminal!(context) do
    unless Map.get(context, :interactive?, &Terminal.interactive?/0).(),
      do:
        Refusal.refuse!(
          "A grant is a person's decision: run this yourself, in a terminal. " <>
            "A coordinator cannot grant itself."
        )
  end

  defp units!(values) do
    Enum.map(values, fn value ->
      with [name, rest] <- String.split(value, "=", parts: 2),
           [cap, reserve] <- String.split(rest, "/", parts: 2),
           {cap, ""} <- Integer.parse(cap),
           {reserve, ""} <- Integer.parse(reserve) do
        %{"name" => name, "cap" => cap, "reserve" => reserve}
      else
        _ -> Refusal.refuse!("Use NAME=CAP/RESERVE for --units, for example flow_credits=200/40")
      end
    end)
  end

  defp grant(opts, context) do
    attrs = %{
      session_id: opts[:session] || Grants.new_session_id(),
      repository_root: root!(Command.expand(opts[:repo], context) || context.cwd),
      models: list(opts[:models]),
      purposes: if(opts[:purposes], do: list(opts[:purposes]), else: Grants.purposes()),
      max_dispatches: Keyword.get(opts, :max_dispatches, 10),
      max_parallel: Keyword.get(opts, :max_parallel, 3),
      max_total_seconds: Keyword.get(opts, :max_hours, 4) * 3600,
      max_dispatch_seconds: Keyword.get(opts, :max_dispatch_minutes, 60) * 60,
      unread_usage: Keyword.get(opts, :unread_usage, 0),
      max_turns: Keyword.get(opts, :max_turns, 20),
      team: team!(opts[:team]),
      units: units!(Keyword.get_values(opts, :units))
    }

    describe(attrs, context)

    unless confirmed?(context, "Grant this? [y/N] "), do: Refusal.refuse!("Not granted.")

    case Grants.create(attrs, opts[:by] || WorkLoop.default_human()) do
      {:ok, grant} ->
        context.shell.error(
          "Granted. In the coordinator's shell: export SHOESTRING_SESSION=#{grant.session_id}"
        )

        Command.json(context, show(grant))

      {:error, reason} ->
        Refusal.refuse!("Not granted: #{reason_text(reason)}")
    end
  end

  defp team!(nil), do: nil

  defp team!(name) do
    case Shoestring.AgentProfiles.get_by_slug(name) do
      nil -> Refusal.refuse!("Unknown team: #{name}")
      team -> Shoestring.Agents.snapshot(team)
    end
  end

  @doc false
  def describe(attrs, context) do
    shell = context.shell
    shell.error("Grant for coordinator session #{attrs.session_id} in #{attrs.repository_root}:")
    shell.error("  Models: #{Enum.join(attrs.models, ", ")}")
    shell.error("  Purposes: #{Enum.join(attrs.purposes, ", ")}")

    shell.error(
      "  Up to #{attrs.max_dispatches} attempts, #{attrs.max_parallel} queued or running at once, " <>
        "#{div(attrs.max_total_seconds, 3600)} hours in total, " <>
        "#{div(attrs.max_dispatch_seconds, 60)} minutes each"
    )

    shell.error("  Dispatches started with unreadable usage: #{attrs.unread_usage}")
    shell.error("  Coordinator turns: #{attrs.max_turns}")

    for unit <- Map.get(attrs, :units) || [] do
      shell.error(
        "  EXTERNAL units #{unit["name"]}: #{unit["cap"]} in total, #{unit["reserve"]} held per dispatch"
      )
    end

    case Map.get(attrs, :team) do
      %{"agents" => [_ | _] = agents} = team ->
        shell.error("  Team #{team["team"]}:")

        for agent <- agents do
          limit =
            cond do
              agent["kind"] == "coordinator" -> "the turns above"
              agent["max_minutes"] -> "at most #{agent["max_minutes"]} minutes a dispatch"
              true -> "no limit of its own"
            end

          shell.error(
            "    #{Shoestring.Agents.label(agent["kind"])} #{agent["slug"]}: " <>
              "#{agent["provider"]}:#{agent["model"]}, #{limit}"
          )
        end

      _ ->
        :ok
    end
  end

  @doc false
  def confirmed?(context, question) do
    answer = context.shell.prompt(question) |> to_string() |> String.trim()
    String.downcase(answer) in ["y", "yes"]
  end

  @doc false
  def show(grant) do
    %{
      "grant_id" => grant.id,
      "team" => grant.team,
      "session_id" => grant.session_id,
      "granted_by" => grant.granted_by,
      "repository_root" => grant.repository_root,
      "models" => grant.models,
      "purposes" => grant.purposes,
      "limits" => %{
        "max_dispatches" => grant.max_dispatches,
        "max_parallel" => grant.max_parallel,
        "max_total_seconds" => grant.max_total_seconds,
        "max_dispatch_seconds" => grant.max_dispatch_seconds,
        "unread_usage" => grant.unread_usage,
        "max_turns" => grant.max_turns
      },
      "turns" => %{
        "used" => grant.turns_used,
        "left" => max(grant.max_turns - grant.turns_used, 0)
      },
      "limits_revision" => grant.limits_revision,
      "room" => Dispatches.room(grant),
      "revoked_at" => grant.revoked_at,
      "revoked_by" => grant.revoked_by,
      "created_at" => grant.inserted_at
    }
  end

  @doc false
  def list(value),
    do: value |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp root!(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> String.trim(root)
      _ -> Refusal.refuse!("Not a Git repository. Run it inside one or pass --repo.")
    end
  rescue
    _ -> Refusal.refuse!("Not a Git repository. Run it inside one or pass --repo.")
  end

  @doc false
  def reason_text(:non_human_identity), do: "--by must be human:NAME"
  def reason_text(:grant_revoked), do: "the grant is revoked"

  def reason_text({:invalid_grant, {:model, model}}),
    do: "#{model} is not an enabled model of a harness that can do these purposes"

  def reason_text({:invalid_grant, :limits}),
    do: "max-parallel cannot exceed max-dispatches, nor one dispatch the total time"

  def reason_text({:invalid_grant, field}), do: "invalid #{field}"
  def reason_text(reason), do: inspect(reason)
end
