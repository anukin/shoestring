defmodule Shoestring.CLI.Commands.External do
  @moduledoc "`shoestring external`: work done outside Shoestring, checked inside it (iteration 20)."

  import Ecto.Query

  alias Shoestring.{Dispatches, Repo}
  alias Shoestring.CLI.{Command, Refusal, Terminal, WorkLoop}
  alias Shoestring.Dispatches.{Dispatch, External, Externals}

  @help """
  shoestring external start --title TEXT --brief FILE [--units NAME=N]...
      [--gate NAME]... [--test PATH]... [--minutes N] [--after DISPATCH]
      [--session ID] [--repo PATH]
  shoestring external list [--session ID | --all] [--json]
  shoestring external show DISPATCH [--json]
  shoestring external confirm DISPATCH [--by human:NAME]
  shoestring external complete DISPATCH [--units NAME=N]... [--by human:NAME]
  shoestring external abandon DISPATCH --reason TEXT [--by human:NAME]

  An EXTERNAL dispatch is work a person or a program does outside
  Shoestring's guarantee (a desktop app, a signed-in browser, a tool with
  only a GUI): Shoestring does not run it, watch it or sandbox it. It owns
  the brief, a run worktree made from the repository's HEAD, the grant's
  time and units, and the checks that accept the result.

  `start` records one under the session's grant (the grant must allow the
  external purpose; units are reserved now: NAME=N, else each grant unit's
  per-dispatch reserve). It is held until you `confirm` it (or press Start on
  the Sessions page): Shoestring then makes the worktree, writes the brief to
  .shoestring/brief.md in it, and starts the clock. Work in that directory
  only and commit there. `complete` checks that it is clean and holds a
  commit, runs the checks under Shoestring's gate sandbox, and on success
  prints the commands that take the commit; otherwise it says why and you
  may complete again. --units reports what the work actually used. Past its
  deadline it is reported expired and can still be completed: nothing is
  stopped or deleted. `abandon` ends it, keeps the worktree, and keeps its
  reserved units counted. `confirm`, `complete` and `abandon` are a
  person's: they refuse without a terminal. DISPATCH is its id or the first
  8 characters of it.
  """

  @switches [
    session: :string,
    all: :boolean,
    json: :boolean,
    units: :keep,
    by: :string,
    reason: :string
  ]

  def help, do: @help

  def run(["start" | args], context),
    do: Shoestring.CLI.Commands.Dispatch.run(["--purpose", "external" | args], context)

  def run(args, context) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, ["list"], []} ->
        context.with_repo.(fn _repo -> list(opts, context) end)

      {opts, ["show", id], []} ->
        context.with_repo.(fn _repo -> show(find!(id), opts, context) end)

      {opts, [action, id], []} when action in ~w(confirm complete abandon) ->
        person!(context)
        by = opts[:by] || WorkLoop.default_human()
        context.with_repo.(fn _repo -> act(action, find!(id), by, opts, context) end)

      _ ->
        Refusal.usage!("external")
    end
  end

  defp person!(context) do
    unless Map.get(context, :interactive?, &Terminal.interactive?/0).(),
      do:
        Refusal.refuse!(
          "This is a person's step: run it yourself, in a terminal. An agent cannot act as you."
        )
  end

  defp act("confirm", dispatch, by, _opts, context) do
    case Externals.confirm(dispatch, by, Map.get(context, :external_opts, [])) do
      :confirmed ->
        external = Externals.get(dispatch.id)
        context.shell.error("Started. Work in #{external.worktree_path} and commit there.")
        Command.json(context, view(dispatch, external))

      :none ->
        Refusal.refuse!("It is not held: nothing to confirm.")

      {:error, reason} ->
        Refusal.refuse!(message(reason))
    end
  end

  defp act("complete", dispatch, by, opts, context) do
    units =
      case Externals.parse_units(Keyword.get_values(opts, :units)) do
        {:ok, units} -> units
        {:error, _} -> Refusal.refuse!("Use NAME=N for --units, for example flow_credits=30")
      end

    case Externals.complete(dispatch, by, units, Map.get(context, :external_opts, [])) do
      {:ok, %External{state: "completed"} = external} ->
        context.shell.error("Completed: its checks passed at #{external.commit}. To take it:")
        Enum.each(Externals.take(dispatch, external), &context.shell.error("  #{&1}"))
        Command.json(context, view(dispatch, external))

      {:ok, external} ->
        context.shell.error(
          "Not accepted: #{failure_text(external.failure)} Fix it in #{external.worktree_path} " <>
            "and complete again."
        )

        Command.json(context, view(dispatch, external))

      {:error, reason} ->
        Refusal.refuse!(message(reason))
    end
  end

  defp act("abandon", dispatch, by, opts, context) do
    case Externals.abandon(dispatch, by, opts[:reason]) do
      {:ok, external} ->
        context.shell.error(
          "Abandoned. Its worktree is kept: #{external.worktree_path || "none"}"
        )

        Command.json(context, view(dispatch, external))

      {:error, reason} ->
        Refusal.refuse!(message(reason))
    end
  end

  defp list(opts, context) do
    dispatches =
      cond do
        opts[:all] ->
          Repo.all(from d in Dispatch, where: d.purpose == "external", order_by: d.inserted_at)

        true ->
          session =
            opts[:session] || Map.get(context, :env, &System.get_env/1).("SHOESTRING_SESSION") ||
              Refusal.refuse!("No session: pass --session ID or --all, or set SHOESTRING_SESSION")

          session |> Dispatches.list() |> Enum.filter(&(&1.purpose == "external"))
      end

    rows = for d <- dispatches, e = Externals.get(d.id), do: view(d, e)

    if opts[:json] do
      Command.json(context, rows)
    else
      if rows == [], do: context.shell.info("No EXTERNAL dispatches.")

      for row <- rows do
        context.shell.info(
          "#{String.slice(row["dispatch_id"], 0, 8)}  #{row["state"]}#{if row["expired"], do: " (expired)", else: ""}  #{row["title"]}\n" <>
            Enum.map_join(row["next"], "", &"    #{&1}\n")
        )
      end
    end
  end

  defp show(dispatch, opts, context) do
    external = Externals.get(dispatch.id) || Refusal.refuse!("That dispatch is not an EXTERNAL.")
    row = view(dispatch, external)

    if opts[:json] do
      Command.json(context, row)
    else
      context.shell.info(
        """
        EXTERNAL #{dispatch.id}: #{dispatch.title}
        State: #{row["state"]}#{if row["expired"], do: " (past its deadline)", else: ""}
        Worktree: #{row["worktree"] || "made when it is confirmed"}
        Deadline: #{row["deadline_at"] || "starts when it is confirmed"}
        Units: #{units_text(row["units_reserved"], row["units_actual"])}
        Checks: #{Enum.map_join(dispatch.plan["gates"] || [], ", ", & &1["gate"])}
        """ <>
          if(row["failure"], do: "Last completion: #{failure_text(row["failure"])}\n", else: "") <>
          if(row["source_changed"],
            do:
              "Your checkout changed while it worked (HEAD or files): Shoestring did not change it.\n",
            else: ""
          ) <>
          "This work is done outside Shoestring's guarantee: it is not sandboxed.\n" <>
          Enum.map_join(row["next"], "", &"  #{&1}\n")
      )
    end
  end

  @doc "One EXTERNAL as data: what `show --json`, `runs show` and the web share."
  def view(%Dispatch{} = dispatch, %External{} = external) do
    short = String.slice(dispatch.id, 0, 8)

    %{
      "dispatch_id" => dispatch.id,
      "title" => dispatch.title,
      "state" => external.state,
      "expired" => Externals.expired?(external),
      "remaining" => remaining(external),
      "worktree" => external.worktree_path,
      "brief" =>
        external.worktree_path && Path.join(external.worktree_path, Externals.brief_path()),
      "base_commit" => external.base_commit,
      "deadline_at" => external.deadline_at,
      "units_reserved" => external.units_reserved,
      "units_actual" => external.units_actual,
      "attempts" => external.attempts,
      "commit" => external.commit,
      "checks" => external.checks,
      "failure" => external.failure,
      "source_changed" => Externals.source_changed?(external),
      "take" => Externals.take(dispatch, external),
      "next" => next(external.state, short)
    }
  end

  @doc "The commands for an EXTERNAL in `state`."
  def next("held", short),
    do: ["shoestring external confirm #{short}   (a person; or Start on the Sessions page)"]

  def next(state, short) when state in ~w(awaiting needs_you),
    do: [
      "shoestring external complete #{short} [--units NAME=N]",
      "shoestring external abandon #{short} --reason \"...\""
    ]

  def next(_state, _short), do: []

  @doc "The time left to an EXTERNAL's deadline, human; nil without one."
  def remaining(external, now \\ DateTime.utc_now())

  def remaining(%External{deadline_at: %DateTime{} = deadline, state: state}, now)
      when state in ~w(awaiting needs_you) do
    case DateTime.diff(deadline, now, :second) do
      secs when secs <= 0 -> "past due"
      secs when secs >= 3600 -> "#{div(secs, 3600)}h #{div(rem(secs, 3600), 60)}m"
      secs -> "#{div(secs, 60)}m"
    end
  end

  def remaining(_external, _now), do: nil

  def failure_text("no_commit"), do: "nothing was committed in its worktree."
  def failure_text("gate_worktree_dirty"), do: "its worktree has uncommitted or untracked files."
  def failure_text("check_failed:" <> gate), do: "the check #{gate} failed."
  def failure_text("check_error:" <> rest), do: "a check could not run (#{rest})."
  def failure_text(other), do: to_string(other)

  defp units_text(reserved, actual) when map_size(reserved) == 0 and is_nil(actual), do: "none"

  defp units_text(reserved, actual) do
    Enum.map_join(reserved, ", ", fn {name, n} ->
      case actual do
        %{^name => used} -> "#{name} #{used} used (#{n} reserved)"
        _ -> "#{name} #{n} reserved"
      end
    end)
  end

  defp find!(prefix) do
    if Regex.match?(~r/\A[0-9a-f-]{8,36}\z/, prefix) do
      case Repo.all(
             from d in Dispatch,
               where: like(d.id, ^"#{prefix}%") and d.purpose == "external",
               limit: 2
           ) do
        [dispatch] -> dispatch
        [] -> Refusal.refuse!("No such EXTERNAL dispatch.")
        _ -> Refusal.refuse!("More than one dispatch starts with #{prefix}; give more of its id.")
      end
    else
      Refusal.refuse!("No such EXTERNAL dispatch.")
    end
  end

  def message(:non_human_identity), do: "--by must be human:NAME"
  def message(:not_started), do: "It is still held: confirm it first."
  def message(:already_finished), do: "It already completed or was abandoned."
  def message(:unknown_unit), do: "--units names a unit it did not reserve."
  def message(:reason_required), do: "abandon needs --reason TEXT"
  def message(:not_external), do: "That dispatch is not an EXTERNAL."
  def message(other), do: "Refused: #{inspect(other)}"
end
