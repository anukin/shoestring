defmodule Shoestring.CLI.Commands.Runs do
  @moduledoc "`shoestring runs`: a coordinator session's dispatches."

  alias Shoestring.Dispatches
  alias Shoestring.CLI.{Command, Jobs, Refusal, Result}
  alias Shoestring.CLI.Commands.Dispatch

  @help """
  shoestring runs list [--session ID] [--json]
  shoestring runs show DISPATCH [--json]
  shoestring runs cancel DISPATCH --reason TEXT [--session ID]

  `list` prints the session's dispatches (ID or SHOESTRING_SESSION; every
  dispatch without either) with their states. `show` adds the attempts and
  time used, what a `waiting` dispatch waits for (`waiting.until`,
  `waiting.reason`) and, once it completes, the verified commit, its checks
  and the commands to take it. `cancel` cancels a dispatch of this session through
  the ordinary cancellation path, which reaps everything it started; other
  dispatches keep running. Output is JSON on stdout.
  """

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: [session: :string, reason: :string, json: :boolean]) do
      {opts, ["list"], []} ->
        session = session(opts, context)

        context.with_repo.(fn _repo ->
          Command.json(context, Enum.map(Dispatches.list(session), &Dispatch.summary/1))
        end)

      {_opts, ["show", id], []} ->
        context.with_repo.(fn _repo ->
          dispatch = dispatch!(id)
          _ = Dispatches.advance(dispatch)
          Command.json(context, detail(dispatch))
        end)

      {opts, ["cancel", id], []} ->
        reason = opts[:reason] || Refusal.refuse!("runs cancel needs --reason TEXT")
        session = session(opts, context)
        context.with_repo.(fn _repo -> cancel(dispatch!(id), reason, session, context) end)

      _ ->
        Refusal.usage!("runs")
    end
  end

  defp detail(dispatch) do
    summary = Dispatch.summary(dispatch)

    status =
      case dispatch.goal_id && Shoestring.Cobbler.ExecutionControl.status(dispatch.goal_id) do
        {:ok, %{planned?: true} = status} ->
          %{
            "attempts_used" => status[:total_attempts],
            "duration_ms" => status[:total_duration_ms],
            "active_run_id" => status[:active_run_id],
            "reviews" => Enum.map(status[:reviews] || [], &Result.review/1),
            "waiting" =>
              case Dispatches.waiting_until(status) do
                {until, reason} -> %{"until" => until, "reason" => reason}
                nil -> nil
              end
          }

        _ ->
          %{}
      end

    result =
      if summary["state"] == "completed" do
        case Result.fetch(dispatch.goal_id) do
          {:ok, result} ->
            %{
              "commit" => result.commit,
              "base" => result.base,
              "checks" => result.checks,
              "diff_stat" => result.diff_stat,
              "take" => result.take
            }

          _ ->
            nil
        end
      end

    summary
    |> Map.merge(status)
    |> Map.put("result", result)
    |> Map.put(
      "next",
      case summary["state"] do
        "needs_you" -> "A person decides: shoestring follow #{dispatch.goal_id}"
        "held" -> "A person confirms the usage: shoestring follow #{dispatch.goal_id}"
        "waiting" -> waiting_next(dispatch, status["waiting"])
        "completed" -> "Take the commit with the commands in result.take"
        _ -> nil
      end
    )
  end

  defp waiting_next(dispatch, %{"until" => until}),
    do:
      "Starts by itself after #{dispatch.provider}'s usage resets at " <>
        "#{DateTime.to_iso8601(until)}. To use another model now: shoestring runs cancel " <>
        "#{dispatch.id} --reason TEXT, then dispatch it again with another --worker"

  defp waiting_next(_dispatch, _waiting), do: nil

  defp cancel(dispatch, reason, session, context) do
    if session != dispatch.session_id,
      do: Refusal.refuse!("That dispatch belongs to another session.")

    result =
      case Map.get(context, :oban) do
        nil -> Jobs.with_client(&Dispatches.cancel(dispatch, reason, oban: &1))
        client -> Dispatches.cancel(dispatch, reason, oban: client)
      end

    case result do
      {:ok, _} ->
        context.shell.error("Cancellation requested for #{dispatch.id}.")
        Command.json(context, Dispatch.summary(dispatch))

      {:error, :not_started} ->
        Refusal.refuse!("That dispatch never started; there is nothing to cancel.")

      {:error, reason} ->
        Refusal.refuse!("Not cancelled: #{inspect(reason, limit: 8)}")
    end
  end

  defp dispatch!(id), do: Dispatches.get(id) || Refusal.refuse!("Dispatch not found: #{id}")

  defp session(opts, context),
    do: opts[:session] || Map.get(context, :env, &System.get_env/1).("SHOESTRING_SESSION")
end
