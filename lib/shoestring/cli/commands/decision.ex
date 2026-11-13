defmodule Shoestring.CLI.Commands.Decision do
  @moduledoc "`shoestring decision`: what plans wait on the person to choose, and the answers."

  import Ecto.Query

  alias Shoestring.{Decisions, Repo}
  alias Shoestring.Decisions.Decision
  alias Shoestring.CLI.{Command, Refusal, Terminal, WorkLoop}
  alias Shoestring.Trajectory.{Artifact, ArtifactStore}

  @help """
  shoestring decision list [--goal ID] [--all] [--json]
  shoestring decision show DECISION [--json]
  shoestring decision answer DECISION --choose KEY [--note TEXT] [--by human:NAME]
  shoestring decision answer DECISION --reject --note TEXT [--by human:NAME]

  A plan task can produce candidates and wait, before the tasks that depend
  on it, for you to choose one (a decision). `list` shows the decisions
  waiting on you (--all: answered ones too; --goal: one goal's). `show`
  prints the question, each option's key and label, where its file is under
  the state directory, and the web page where the candidates can be seen.
  `answer --choose KEY` picks one; the next tasks start with it. `answer
  --reject` ("none of these", when the decision allows it) needs --note
  saying why, and stops the task for you to decide what next. The first
  answer wins, from here or the web or the chat screen; `answer` queues the
  plan again for the running service and prints whether it did ("plan").
  Open the web page at the address `show` prints (its host name matters:
  the page's buttons work only there). Nothing decides a
  decision on a timer. DECISION is its id or the first 8 characters of it.
  `answer` refuses without a terminal, so an agent cannot answer as you.
  """

  @switches [
    goal: :string,
    all: :boolean,
    json: :boolean,
    choose: :string,
    reject: :boolean,
    note: :string,
    by: :string
  ]

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, ["list"], []} ->
        context.with_repo.(fn _repo -> list(opts, context) end)

      {opts, ["show", decision], []} ->
        context.with_repo.(fn _repo -> show(find!(decision), opts, context) end)

      {opts, ["answer", decision], []} ->
        unless Map.get(context, :interactive?, &Terminal.interactive?/0).(),
          do:
            Refusal.refuse!(
              "Answering a decision is a person's choice: run this yourself, in a terminal. " <>
                "An agent cannot answer as you."
            )

        choice =
          case {opts[:choose], opts[:reject]} do
            {key, nil} when is_binary(key) ->
              key

            {nil, true} ->
              Decisions.reject()

            {key, true} when is_binary(key) ->
              Refusal.refuse!("Give --choose or --reject, not both.", exit_status: 2)

            _ ->
              Refusal.refuse!("Give --choose KEY or --reject --note TEXT.", exit_status: 2)
          end

        by = opts[:by] || WorkLoop.default_human()

        context.with_repo.(fn _repo ->
          # The service is another process: the plan is queued again through
          # the command line's job client, as `execution continue` does, and
          # the outcome is reported, never assumed.
          Map.get(context, :jobs, &Shoestring.CLI.Jobs.with_client/1).(fn client ->
            case Decisions.answer(find!(decision).id, choice, opts[:note], by,
                   resume_fun: fn _goal, _execution -> :ok end
                 ) do
              {:ok, decision} ->
                Command.json(context, %{
                  decision: decision.id,
                  state: decision.state,
                  answer: decision.answer_key,
                  plan: resume(decision, client)
                })

              {:error, reason} ->
                Refusal.refuse!(message(reason))
            end
          end)
        end)

      _ ->
        Refusal.usage!("decision")
    end
  end

  defp list(opts, context) do
    decisions =
      Decisions.list(
        Keyword.reject(
          [
            goal_ids: opts[:goal] && [goal!(opts[:goal])],
            states: if(opts[:all], do: nil, else: ["pending"])
          ],
          fn {_key, value} -> is_nil(value) end
        )
      )
      |> Enum.reverse()

    if opts[:json] do
      Command.json(context, Enum.map(decisions, &row/1))
    else
      if decisions == [],
        do: context.shell.info(if(opts[:all], do: "No decisions.", else: "No plan waits on you."))

      for decision <- decisions do
        short = String.slice(decision.id, 0, 8)

        context.shell.info(
          "#{short}  #{decision.plan_task_id} (goal #{String.slice(decision.goal_id, 0, 8)}) " <>
            "#{state_text(decision)}\n    #{decision.question}\n" <>
            Enum.map_join(decision.options, "", &"    #{&1["key"]}  #{&1["label"]}\n") <>
            if(decision.state == "pending",
              do:
                "    shoestring decision show #{short}   |   shoestring decision answer #{short} --choose KEY" <>
                  if(decision.allow_reject,
                    do: "   |   ... --reject --note \"...\"",
                    else: ""
                  ),
              else: ""
            )
        )
      end
    end
  end

  defp show(decision, opts, context) do
    if opts[:json] do
      Command.json(context, row(decision))
    else
      short = String.slice(decision.id, 0, 8)

      context.shell.info(
        "Decision #{decision.id}\n" <>
          "Task #{decision.plan_task_id} attempt #{decision.attempt} of goal #{decision.goal_id}\n" <>
          "State: #{state_text(decision)}\n\n" <>
          "#{decision.question}\n" <>
          if(decision.note, do: "\n#{decision.note}\n", else: "") <>
          "\n" <>
          Enum.map_join(decision.options, "", &option_text/1) <>
          "\nSee them: #{page_url(decision)}\n" <>
          if(decision.state == "pending",
            do:
              "Answer: shoestring decision answer #{short} --choose KEY" <>
                if(decision.allow_reject,
                  do: "\n    or: shoestring decision answer #{short} --reject --note \"WHY\"",
                  else: ""
                ) <> "\nIt waits for you: nothing decides this on a timer.",
            else: ""
          )
      )
    end
  end

  defp option_text(option) do
    "  #{option["key"]}  #{option["label"]}  (#{option["media_type"]})\n" <>
      "      file: #{stored_path(option["artifact_id"]) || "(not stored)"}\n" <>
      if(option["source"],
        do: "      full candidate: #{option["source"]} (in the task's worktree)\n",
        else: ""
      )
  end

  # Where the candidate's bytes are under the state directory.
  defp stored_path(artifact_id) do
    case Repo.get(Artifact, artifact_id) do
      %Artifact{location: location} -> Path.join(ArtifactStore.root(), location)
      nil -> nil
    end
  end

  defp state_text(%Decision{state: "pending"}), do: "waits for you"

  defp state_text(%Decision{state: "answered"} = d),
    do: "chosen: #{d.answer_key} by #{d.decided_by}"

  defp state_text(%Decision{state: "rejected"} = d),
    do: "none of these, by #{d.decided_by}: #{d.answer_note}"

  defp state_text(%Decision{state: "withdrawn"}), do: "withdrawn: the goal was cancelled"

  # Whether the plan was queued again: "queued", or why not ("needs_user"
  # while another decision or a stop waits; a refusal for an execution the
  # command line cannot queue).
  defp resume(decision, client) do
    case Shoestring.Cobbler.ExecutionControl.continue(decision.goal_id, decision.execution_id,
           oban: client
         ) do
      {:ok, %{outcome: outcome}} -> Atom.to_string(outcome)
      {:error, reason} -> "not queued (#{inspect(reason)}): shoestring execution continue"
    end
  end

  @doc """
  The goal page where a decision's candidates can be seen, at the web UI's
  configured host and port: the page's live connection accepts only that
  origin, so a page opened at another host name shows but cannot be answered.
  """
  def page_url(decision) do
    endpoint = Application.get_env(:shoestring, ShoestringWeb.Endpoint, [])
    url = endpoint[:url] || []
    port = url[:port] || get_in(endpoint, [:http, :port]) || 4000
    "http://#{url[:host] || "localhost"}:#{port}/cobbler/goals/#{decision.goal_id}"
  end

  defp row(decision),
    do: %{
      "decision_id" => decision.id,
      "goal_id" => decision.goal_id,
      "task" => decision.plan_task_id,
      "attempt" => decision.attempt,
      "key" => decision.key,
      "question" => decision.question,
      "note" => decision.note,
      "allow_reject" => decision.allow_reject,
      "state" => decision.state,
      "answer" => decision.answer_key,
      "answer_note" => decision.answer_note,
      "decided_by" => decision.decided_by,
      "options" =>
        Enum.map(decision.options, fn option ->
          option
          |> Map.take(~w(key label media_type artifact_id source))
          |> Map.put("path", stored_path(option["artifact_id"]))
        end),
      "page_url" => page_url(decision),
      "asked_at" => decision.inserted_at
    }

  defp goal!(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> id
      :error -> Refusal.refuse!("--goal must be a goal id.", exit_status: 2)
    end
  end

  defp find!(prefix) do
    if Regex.match?(~r/\A[0-9a-f-]{8,36}\z/, prefix) do
      case Repo.all(from d in Decision, where: like(d.id, ^"#{prefix}%"), limit: 2) do
        [decision] -> decision
        [] -> Refusal.refuse!(message(:decision_not_found))
        _ -> Refusal.refuse!("More than one decision starts with #{prefix}; give more of its id.")
      end
    else
      Refusal.refuse!(message(:decision_not_found))
    end
  end

  def message(:decision_not_found), do: "No such decision."
  def message(:already_answered), do: "That decision was already answered."
  def message(:decision_withdrawn), do: "That decision was withdrawn: its goal was cancelled."

  def message(:unknown_option),
    do: "That is not one of its options; see shoestring decision show."

  def message(:reject_not_allowed), do: "This decision does not allow --reject."
  def message(:note_required), do: "--reject needs --note saying why none of these will do."
  def message(:note_too_long), do: "--note is longer than 2000 characters."
  def message(:non_human_identity), do: "--by must be human:NAME"
  def message(other), do: "Not answered: #{inspect(other)}"
end
