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
  and the commands to take it; for EXPLORE and REVIEW, its call and its
  `report`. `cancel` cancels a dispatch of this session through
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
      if summary["state"] == "completed" and dispatch.purpose == "implement" do
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

    call = Dispatches.Calls.get(dispatch.id)

    summary
    |> Map.merge(status)
    |> Map.merge(call_detail(call))
    |> Map.put("result", result)
    |> Map.put(
      "next",
      next(summary["state"], dispatch, call, Map.merge(status, call_detail(call)))
    )
  end

  # An EXPLORE or REVIEW dispatch's one call (`Shoestring.Dispatches.Calls`).
  defp call_detail(nil), do: %{}

  defp call_detail(call) do
    %{
      "call" => %{
        "state" => call.state,
        "error" => call.error_code,
        "output_tokens" => call.output_tokens,
        "confirmed_by" => call.confirmed_by,
        "admission" => call.admission && Map.take(call.admission, ["result", "reason_code"])
      },
      "report" => Dispatches.Calls.report(call),
      "waiting" =>
        if(Dispatches.Calls.state(call) == "waiting",
          do: %{"until" => call.defer_until, "reason" => call.admission["reason_code"]}
        )
    }
  end

  defp next("needs_you", dispatch, _call, _detail),
    do: "A person decides: shoestring follow #{dispatch.goal_id}"

  defp next("held", dispatch, %Dispatches.Call{}, _detail),
    do:
      "Its provider's usage needs a confirmation and the grant has no unread-usage " <>
        "pre-approval left. A person allows more, in a terminal: shoestring grants extend " <>
        "#{dispatch.grant_id} --unread-usage 1; the next wait or runs show then confirms it"

  defp next("held", dispatch, nil, _detail),
    do: "A person confirms the usage: shoestring follow #{dispatch.goal_id}"

  defp next("waiting", dispatch, _call, detail), do: waiting_next(dispatch, detail["waiting"])

  defp next("completed", %{purpose: "implement"}, _call, _detail),
    do: "Take the commit with the commands in result.take"

  defp next("completed", %{purpose: "review"}, _call, %{"report" => %{"outcome" => outcome}}),
    do:
      if(outcome == "changes_requested",
        do: "Blocking findings: dispatch an IMPLEMENT that addresses them, or tell the person",
        else: "Approved: no supported blocking finding"
      )

  defp next("failed", _dispatch, call, _detail),
    do: "The call failed (#{call.error_code}); dispatch it again with another --request-id"

  defp next(_state, _dispatch, _call, _detail), do: nil

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
