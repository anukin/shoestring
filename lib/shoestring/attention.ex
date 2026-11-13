defmodule Shoestring.Attention do
  @moduledoc """
  What needs the person now, built in one place for every screen that shows
  it (iteration 17): the Sessions page, the nav's count and the chat
  screen's asks.

    * an ask a worker is waiting on (`Shoestring.PermissionAsks`), answered
      with `answer/5`;
    * a decision a plan waits on (`Shoestring.Decisions`, iteration 19): a
      task produced candidates and a person chooses one, answered with
      `answer_decision/5`. It replaces the dispatch's stopped item;
    * a held dispatch, one whose provider's remaining usage could not be
      confirmed (`Shoestring.Dispatches.confirm_hold/3`), started with
      `start_held/3`;
    * a stopped dispatch, one whose execution waits for a person
      (`Shoestring.Dispatches.state/2` is `needs_you`): Shoestring's merge of
      a batch stopped, a review needs a decision, Shoestring lost the worker,
      or its tasks stopped some other way (out of time or attempts, files
      outside their scope, failed final checks). These are decided in a
      terminal, so their items say what happened and give the commands.

  Each item carries the words the chat screen and `runs show` use and the
  choices that answer it. Nothing here decides anything by itself: an item
  stays until the person answers it or its work ends.

  Anything that changes the list broadcasts `{:attention_changed,
  session_id}` on `topic/0`: an ask recorded or settled, and a held dispatch
  started. A hold itself appears when an admission is decided, which nothing
  broadcasts, so a screen that shows the count also re-reads it on a timer.
  """

  alias Shoestring.{AgentProfiles, Decisions, Dispatches, PermissionAsks, Repo, Sessions}
  alias Shoestring.CLI.Commands.Runs
  alias Shoestring.Cobbler.{ExecutionControl, PlanMerge}
  alias Shoestring.Cobbler.Review.Findings
  alias Shoestring.PermissionAsks.Ask

  @topic "attention"
  @max_note 500

  def topic, do: @topic

  @doc "Tells every screen showing attention that `session_id`'s list may have changed."
  def changed(session_id),
    do: Phoenix.PubSub.broadcast(Shoestring.PubSub, @topic, {:attention_changed, session_id})

  @doc """
  Everything in `session_id` that needs the person: its asks, oldest first,
  then its held dispatches, then its stopped ones. `states` (dispatch id to
  `Shoestring.Dispatches.state/2`) spares re-deriving states a caller
  already has; `status:` reads an execution's status (tests pass a fixed
  one; `Shoestring.Cobbler.ExecutionControl.status/1` otherwise).
  """
  def items(session_id, states \\ %{}, opts \\ []) do
    decisions = decisions(session_id)
    deciding = MapSet.new(decisions, & &1.decision.goal_id)
    dispatches = waiting(session_id, states, deciding)
    status = Keyword.get(opts, :status, &ExecutionControl.status/1)

    asks(session_id) ++
      decisions ++
      externals(session_id) ++
      for({dispatch, "held"} <- dispatches, do: held_item(dispatch)) ++
      for({dispatch, "needs_you"} <- dispatches, do: stopped_item(dispatch, status))
  end

  # The session's dispatches that wait for the person, with their state. A
  # dispatch whose goal waits on a decision is shown by that decision; an
  # EXTERNAL that started is shown by its own item (`externals/1`).
  defp waiting(session_id, states, deciding) do
    for dispatch <- Dispatches.list(session_id),
        dispatch.state == "started",
        not MapSet.member?(deciding, dispatch.goal_id),
        state = states[dispatch.id] || Dispatches.state(dispatch),
        state in ~w(held needs_you),
        not (dispatch.purpose == "external" and state == "needs_you"),
        do: {dispatch, state}
  end

  @doc """
  `session_id`'s EXTERNAL dispatches that wait for the person's outside work
  or a new completion (iteration 20), as items.
  """
  def externals(session_id) do
    for dispatch <- Dispatches.list(session_id),
        dispatch.purpose == "external" and dispatch.state == "started",
        %Shoestring.Dispatches.External{state: state} = external <-
          [Shoestring.Dispatches.Externals.get(dispatch.id)],
        state in ~w(awaiting needs_you),
        do: external_item(dispatch, external)
  end

  @doc "The decisions `session_id`'s dispatches wait on, as items, oldest first."
  def decisions(session_id) do
    dispatches = Dispatches.list(session_id)
    by_goal = Map.new(dispatches, &{&1.goal_id, &1})

    case Map.keys(by_goal) do
      [] ->
        []

      goal_ids ->
        Decisions.list(goal_ids: goal_ids, states: ["pending"])
        |> Enum.reverse()
        |> Enum.map(&decision_item(&1, by_goal[&1.goal_id]))
    end
  end

  @doc "The asks `session_id`'s workers are waiting on, as items."
  def asks(session_id), do: Enum.map(PermissionAsks.pending(session_id), &ask_item/1)

  @doc "`session_id`'s held dispatches, as items."
  def held(session_id, states \\ %{}) do
    for dispatch <- Dispatches.list(session_id),
        dispatch.state == "started",
        (states[dispatch.id] || Dispatches.state(dispatch)) == "held",
        do: held_item(dispatch)
  end

  @doc """
  How many things need the person: every ask a worker is waiting on, and the
  held and stopped dispatches of the sessions the Sessions page lists
  (`session_days`).
  """
  def count do
    asks = PermissionAsks.pending()
    decisions = Decisions.list(states: ["pending"], limit: 1_000)
    deciding = MapSet.new(decisions, & &1.goal_id)

    sessions =
      Sessions.recent(AgentProfiles.settings().session_days, DateTime.utc_now(), counts: false).sessions

    length(asks) + length(decisions) +
      Enum.sum_by(sessions, fn session ->
        length(waiting(session.session_id, %{}, deciding)) + length(externals(session.session_id))
      end)
  end

  # -- Answering -----------------------------------------------------------------

  @doc """
  The person's answer to an ask of `session_id`: `"allow"`, `"allow_agent"`
  or `"deny"`, with an optional `note` that tells the worker why it was
  denied. The first answer wins, from whichever screen: a later one is
  `{:error, :not_pending}`. `{:error, :ask_not_found}` for an ask of
  another session, and `:not_ruleable` for "allow for this agent" on an ask
  a rule cannot cover (a network ask, a file change or a compound command).
  """
  def answer(session_id, ask_id, decision, by, note \\ nil)

  def answer(session_id, ask_id, decision, by, note) when is_binary(ask_id) do
    case Shoestring.Repo.get(Ask, ask_id) do
      %Ask{session_id: ^session_id} = ask when is_binary(session_id) ->
        if decision == "allow_agent" and not for_agent?(ask) do
          {:error, :not_ruleable}
        else
          PermissionAsks.decide(ask.id, decision, by, clip(note))
        end

      _ ->
        {:error, :ask_not_found}
    end
  end

  def answer(_session_id, _ask_id, _decision, _by, _note), do: {:error, :ask_not_found}

  @doc """
  The person's answer to a decision a plan of `session_id` waits on: one
  option's key, or `"reject"` ("none of these", with a note). `session_id`
  nil answers a decision of a goal no coordinator session owns (the goal
  page). The first answer wins, from whichever screen (see
  `Shoestring.Decisions.answer/5`); `{:error, :decision_not_found}` for a
  decision of another session.
  """
  def answer_decision(session_id, decision_id, choice, by, note \\ nil) do
    with %Decisions.Decision{} = decision <- Decisions.get(decision_id),
         true <- owned?(session_id, decision) do
      result = Decisions.answer(decision.id, choice, clip_decision_note(note), by)
      notify(decision.goal_id)
      result
    else
      _ -> {:error, :decision_not_found}
    end
  end

  defp owned?(nil, _decision), do: true

  defp owned?(session_id, decision),
    do: Enum.any?(Dispatches.list(session_id), &(&1.goal_id == decision.goal_id))

  @doc "Tells the screens of every session whose dispatch runs `goal_id` to re-read."
  def notify(goal_id) do
    import Ecto.Query

    Repo.all(
      from d in Dispatches.Dispatch,
        where: d.goal_id == ^goal_id and not is_nil(d.session_id),
        select: d.session_id,
        distinct: true
    )
    |> Enum.each(&changed/1)

    changed(nil)
  end

  @doc """
  The person starts a held dispatch of `session_id`: their confirmation,
  spending none of the grant's pre-approvals. `:confirmed`, `:none` (it is
  not held any more) or `{:error, reason}`.
  """
  def start_held(session_id, dispatch_id, by) do
    case Dispatches.get(dispatch_id) do
      %{session_id: ^session_id} = dispatch when is_binary(session_id) ->
        result = Dispatches.confirm_hold(dispatch, by)
        if result == :confirmed, do: changed(session_id)
        result

      _ ->
        {:error, :dispatch_not_found}
    end
  end

  # -- Items -----------------------------------------------------------------------

  @doc "Whether \"allow for this agent\" is offered: one plain command an agent's rule may cover."
  def for_agent?(%Ask{kind: "network"}), do: false
  def for_agent?(%Ask{rule_key: key, agent: agent}), do: is_binary(key) and is_binary(agent)

  defp ask_item(%Ask{} = ask) do
    network? = ask.kind == "network"

    %{
      id: "ask-" <> ask.id,
      kind: :ask,
      ask: ask,
      dispatch_id: ask.dispatch_id,
      agent: ask.agent,
      at: ask.inserted_at,
      title:
        if(network?,
          do: "A worker asks to reach a host not on its list",
          else: "A worker asks to run a command outside its sandbox"
        ),
      summary:
        if(network?,
          do: ask.command,
          else: "Run outside its sandbox: " <> ask.command
        ),
      subject: if(ask.kind == "command", do: "$ " <> ask.command, else: ask.command),
      why: ask.reason,
      note: ask_note(ask),
      choices: ask_choices(ask)
    }
  end

  defp ask_note(%Ask{kind: "network"}),
    do:
      "Allowing lets its commands reach this host for the rest of this run. To allow it for " <>
        "every run, add it to the agent's hosts. It waits for you: nothing decides this on a timer."

  defp ask_note(%Ask{kind: "file_change"}),
    do:
      "Allowing lets it make this change outside its sandbox. It waits for you: nothing " <>
        "decides this on a timer."

  defp ask_note(%Ask{provider: provider}),
    do:
      "Allowing runs this one command with full access to your files, anywhere you can write; " <>
        if(provider == "codex",
          do: "its network stays as the agent's settings allow.",
          else: "it runs with no sandbox, network included."
        ) <> " It waits for you: nothing decides this on a timer."

  defp ask_choices(%Ask{kind: "network"}),
    do: [{"allow", "Allow for this run"}, {"deny", "Deny"}]

  defp ask_choices(ask) do
    [{"allow", "Allow once"}] ++
      if(for_agent?(ask), do: [{"allow_agent", "Allow for this agent"}], else: []) ++
      [{"deny", "Deny"}, {"deny_reason", "Deny with a reason"}]
  end

  @doc "One decision as an item; `dispatch` is the one running its goal, when there is one."
  def decision_item(decision, dispatch \\ nil) do
    %{
      id: "decision-" <> decision.id,
      kind: :decision,
      decision: decision,
      dispatch: dispatch,
      dispatch_id: dispatch && dispatch.id,
      agent: dispatch && dispatch.agent,
      at: decision.inserted_at,
      title: "A plan waits for you to choose",
      summary: "Choose: " <> decision.question,
      subject: decision.question,
      why: decision.note,
      note:
        "Its next tasks start with what you choose. It waits for you: nothing decides " <>
          "this on a timer." <>
          if(decision.allow_reject,
            do: " None of these stops the task for you to decide what next.",
            else: ""
          ),
      choices:
        Enum.map(decision.options, &{&1["key"], &1["label"]}) ++
          if(decision.allow_reject, do: [{"reject", "None of these"}], else: [])
    }
  end

  defp external_item(dispatch, external) do
    view = Shoestring.CLI.Commands.External.view(dispatch, external)
    needs_you? = external.state == "needs_you"

    %{
      id: "external-" <> dispatch.id,
      kind: :external,
      dispatch: dispatch,
      dispatch_id: dispatch.id,
      agent: nil,
      at: external.updated_at,
      title:
        if(needs_you?,
          do: "This EXTERNAL's result was not accepted",
          else: "EXTERNAL work waits for you"
        ),
      summary: "EXTERNAL: " <> dispatch.title,
      subject: dispatch.title,
      why: needs_you? && Shoestring.CLI.Commands.External.failure_text(external.failure),
      note:
        "Done outside Shoestring's guarantee: Shoestring does not run or sandbox it. Work in " <>
          "its worktree, commit there, then complete it in a terminal; its checks decide." <>
          if(view["expired"], do: " It is past its deadline and still open.", else: ""),
      lines:
        [
          "Worktree: #{external.worktree_path}",
          "Brief: #{view["brief"]}",
          "Deadline: #{external.deadline_at}"
        ] ++
          for({name, n} <- external.units_reserved || %{}, do: "Units: #{name} #{n} reserved") ++
          if(view["source_changed"],
            do: ["Your checkout changed while it worked: Shoestring did not change it."],
            else: []
          ),
      commands: view["next"],
      run_id: nil,
      choices: []
    }
  end

  defp held_item(%{purpose: "external"} = dispatch) do
    %{
      id: "held-" <> dispatch.id,
      kind: :held,
      dispatch: dispatch,
      dispatch_id: dispatch.id,
      agent: nil,
      at: dispatch.inserted_at,
      title: "Start this EXTERNAL work?",
      summary: "Start EXTERNAL: " <> dispatch.title,
      subject: dispatch.title,
      why: nil,
      note:
        "It is done outside Shoestring's guarantee: Shoestring does not run or sandbox it. " <>
          "Starting makes its worktree from HEAD, writes the brief there and starts its clock.",
      choices: [{"start", "Start it"}]
    }
  end

  defp held_item(dispatch) do
    %{
      id: "held-" <> dispatch.id,
      kind: :held,
      dispatch: dispatch,
      dispatch_id: dispatch.id,
      agent: dispatch.agent,
      at: dispatch.inserted_at,
      title: "Start this held dispatch?",
      summary: "Start held dispatch: " <> dispatch.title,
      subject: dispatch.title,
      why: nil,
      note:
        "Its provider's remaining usage could not be confirmed. Starting it is your " <>
          "confirmation; none of the grant's pre-approvals is spent.",
      choices: [{"start", "Start it"}]
    }
  end

  # A stopped dispatch: why it stopped, in the words `runs show` and the
  # chat screen use, and the commands that decide it in a terminal.
  defp stopped_item(dispatch, read_status) do
    status =
      case read_status.(dispatch.goal_id) do
        {:ok, status} -> status
        _ -> %{}
      end

    review = Enum.find(status[:reviews] || [], &Map.get(&1, :needs_user?))
    merge = status != %{} && PlanMerge.blocked(dispatch.goal_id, status)

    base = %{
      id: "stopped-" <> dispatch.id,
      kind: :stopped,
      dispatch: dispatch,
      dispatch_id: dispatch.id,
      agent: dispatch.agent,
      at: dispatch.updated_at,
      subject: dispatch.title,
      why: nil,
      lines: [],
      commands: [],
      run_id: run_id(dispatch),
      choices: []
    }

    cond do
      merge -> Map.merge(base, merge_stopped(dispatch, merge))
      review -> Map.merge(base, review_blocked(dispatch, review))
      lost?(base.run_id, dispatch.goal_id) -> Map.merge(base, lost(dispatch))
      true -> Map.merge(base, other_stop(dispatch))
    end
  end

  defp merge_stopped(dispatch, merge) do
    take = get_in(Runs.detail(dispatch), ["batch", "take"]) || []

    how =
      if take == [],
        do: " Follow it in a terminal to see what is left: shoestring follow #{dispatch.goal_id}",
        else:
          " Merge the commits yourself in a terminal with the commands below, resolving it; " <>
            "the last two record your merge so the final checks run."

    %{
      reason: :merge,
      title: "Shoestring's merge stopped",
      summary: "Merge stopped: " <> dispatch.title,
      note:
        case merge["reason"] do
          "conflict" ->
            "Every task passed its checks, but merging #{merge["plan_task_id"]} conflicts in " <>
              "#{Enum.join(merge["files"] || [], ", ")}. Shoestring never resolves a conflict." <>
              how

          _ ->
            "Every task passed its checks, but Shoestring could not merge their commits" <>
              if(merge["detail"], do: " (#{merge["detail"]}).", else: ".") <> how
        end,
      commands: take
    }
  end

  defp review_blocked(dispatch, review) do
    task = review.plan_task_id
    goal = dispatch.goal_id

    why =
      cond do
        review.state == "escalated" ->
          "The reviewer still asks for changes after the last repair round."

        review.state == "failed" ->
          "The review could not finish" <>
            if(review.reason, do: " (#{review.reason}).", else: ".")

        review.unavailable ->
          "No reviewer could run (#{review.unavailable})."

        true ->
          "The review was called as many times as it may."
      end

    retry? =
      review.state == "failed" or (review.state == "pending" and is_nil(review.unavailable))

    %{
      reason: :review,
      title: "A review needs your decision",
      summary: "Review needs you: " <> dispatch.title,
      note:
        why <>
          " Decide in a terminal: accept takes the commit despite the review, reject fails " <>
          "the attempt" <> if(retry?, do: ", retry allows one more review call.", else: "."),
      lines:
        for finding <- review.findings || [], Findings.blocking?(finding) do
          where =
            case finding do
              %{"path" => path, "line" => line} when is_binary(path) and is_integer(line) ->
                " #{path}:#{line}"

              %{"path" => path} when is_binary(path) ->
                " #{path}"

              _ ->
                ""
            end

          "#{finding["id"]}#{where} #{finding["claim"]}"
        end,
      commands:
        [
          ~s(shoestring review accept #{goal} #{task} --reason "REASON"),
          ~s(shoestring review reject #{goal} #{task} --reason "REASON")
        ] ++
          if(retry?,
            do: [~s(shoestring review retry #{goal} #{task} --reason "REASON")],
            else: []
          )
    }
  end

  defp lost(dispatch) do
    %{
      reason: :lost,
      title: "Shoestring lost this worker",
      summary: "Lost worker: " <> dispatch.title,
      note:
        "Shoestring lost the worker during a service stop or crash; its exact running time " <>
          "is unknown. Ask the coordinator to dispatch it again, or cancel it in a terminal.",
      commands: [~s(shoestring runs cancel #{dispatch.id} --reason "REASON")]
    }
  end

  defp other_stop(dispatch) do
    last =
      case List.last(Runs.log(dispatch, 0)["entries"] || []) do
        %{"line" => line} when is_binary(line) -> [String.trim(line)]
        _ -> []
      end

    %{
      reason: :other,
      title: "This dispatch stopped and needs your decision",
      summary: "Stopped: " <> dispatch.title,
      note:
        "Its tasks stopped where Shoestring can't go on by itself: out of time or attempts, " <>
          "a change left uncommitted, files changed outside their scope, or failed checks. " <>
          "Its last step says which.",
      lines: last,
      commands: ["shoestring follow #{dispatch.goal_id}"]
    }
  end

  defp run_id(dispatch) do
    case Dispatches.latest_run(dispatch) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp lost?(nil, _goal_id), do: false

  defp lost?(run_id, goal_id) do
    import Ecto.Query

    Repo.exists?(
      from e in Shoestring.Trajectory.TrajectoryEvent,
        where:
          e.goal_id == ^goal_id and e.type == "run.failed" and
            fragment("json_extract(?, '$.run_id')", e.payload) == ^run_id and
            fragment("json_extract(?, '$.error_code')", e.payload) == "supervisor_crash"
    )
  end

  # A decision's note is bounded by `Shoestring.Decisions` (2000).
  defp clip_decision_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      text -> text
    end
  end

  defp clip_decision_note(_note), do: nil

  defp clip(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      text -> String.slice(text, 0, @max_note)
    end
  end

  defp clip(_note), do: nil
end
