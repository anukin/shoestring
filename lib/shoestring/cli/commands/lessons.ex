defmodule Shoestring.CLI.Commands.Lessons do
  @moduledoc "`shoestring lessons`: a repository's lessons, and the person's decisions on them."

  alias Shoestring.Lessons
  alias Shoestring.CLI.{Command, Refusal, Terminal, WorkLoop}

  @help """
  shoestring lessons list [--repo PATH | --all] [--state STATE] [--json]
  shoestring lessons show CODE [--json]
  shoestring lessons approve CODE [--text TEXT] [--by human:NAME]
  shoestring lessons reject CODE [--note TEXT] [--by human:NAME]
  shoestring lessons replace CODE --replaces OLD [--text TEXT] [--by human:NAME]
  shoestring lessons edit CODE --text TEXT [--by human:NAME]
  shoestring lessons retire CODE [--note TEXT] [--by human:NAME]
  shoestring lessons space [--json]

  A lesson is one rule for work in one repository, shared by every agent
  that works there. Agents propose them (each agent's "may propose lessons"
  says whether it may; by default all but the explorer), naming where it came
  from: one of the session's dispatches, or your own words in its chat. The
  coordinator approves them: its own proposal when Shoestring's checks pass
  (a source, at most 1024 bytes, secrets removed, not a repeat, room in the
  space limit), a worker's when it decides. A worker sees a lesson only when
  a dispatch cites its code.

  You see every lesson and have the last word. `list` shows the repository's
  lessons (PATH, default this one; `--all` every repository), proposals
  first; STATE is proposed, approved, rejected or retired. `show` adds the
  source, who proposed and approved it, and what it is similar to. `approve`,
  `reject` and `replace` decide a proposal (`replace` approves it and retires
  OLD); `edit` rewords an approved lesson; `retire` stops using one. These
  refuse without a terminal, so an agent cannot make them as you. `space` is
  what lessons take, per repository and in total, against the limit set in
  Settings (default 200 MB per repository).
  """

  @switches [
    repo: :string,
    all: :boolean,
    state: :string,
    text: :string,
    note: :string,
    replaces: :string,
    by: :string,
    json: :boolean
  ]

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, ["list"], []} ->
        context.with_repo.(fn _repo -> list(opts, context) end)

      {opts, ["show", code], []} ->
        context.with_repo.(fn _repo ->
          case Lessons.get(code) do
            nil -> Refusal.refuse!(message(:lesson_not_found))
            lesson -> output(context, opts, [lesson], detail: true)
          end
        end)

      {opts, ["space"], []} ->
        context.with_repo.(fn _repo -> space(opts, context) end)

      {opts, [decision, code], []} when decision in ~w(approve reject replace edit retire) ->
        terminal!(context)
        by = opts[:by] || WorkLoop.default_human()

        context.with_repo.(fn _repo ->
          result =
            case decision do
              "approve" -> Lessons.decide(code, "approve", by, text: opts[:text])
              "reject" -> Lessons.decide(code, "reject", by, note: opts[:note])
              "replace" -> replace(code, by, opts)
              "edit" -> Lessons.edit(code, opts[:text] || Refusal.usage!("lessons"), by)
              "retire" -> Lessons.retire(code, by, opts[:note])
            end

          case result do
            {:ok, lesson} -> output(context, opts, [lesson], detail: true)
            {:error, reason} -> Refusal.refuse!(message(reason))
          end
        end)

      _ ->
        Refusal.usage!("lessons")
    end
  end

  defp replace(code, by, opts) do
    older = opts[:replaces] || Refusal.usage!("lessons")
    Lessons.decide(code, "replace", by, replaces: older, text: opts[:text])
  end

  defp terminal!(context) do
    unless Map.get(context, :interactive?, &Terminal.interactive?/0).(),
      do:
        Refusal.refuse!(
          "Deciding a lesson is a person's decision: run this yourself, in a terminal. " <>
            "An agent cannot decide as you."
        )
  end

  defp list(opts, context) do
    repository =
      if opts[:all], do: nil, else: Command.expand(opts[:repo], context) || context.cwd

    repository = repository && root(repository)

    lessons =
      Lessons.list(repository: repository, state: opts[:state])
      |> Enum.sort_by(&if(&1.state == "proposed", do: 0, else: 1))

    output(context, opts, lessons, detail: false)
  end

  # The repository's root as Shoestring records it, when it is one.
  defp root(path) do
    case Shoestring.Cobbler.Intake.repository(path, uncommitted: :allow) do
      {:ok, facts} -> facts.root
      _ -> Path.expand(path)
    end
  end

  defp output(context, opts, lessons, detail: detail?) do
    if opts[:json] do
      Command.json(context, Enum.map(lessons, &data(&1, detail?)))
    else
      if lessons == [], do: context.shell.info("No lessons.")

      for lesson <- lessons do
        context.shell.info("#{lesson.code}  #{lesson.state}  cited #{lesson.cite_count}")
        context.shell.info("  " <> lesson.text)

        if detail? do
          context.shell.info("  Repository: #{lesson.repository_root}")
          context.shell.info("  Source: " <> source(lesson))
          if lesson.why, do: context.shell.info("  Why: " <> lesson.why)

          if lesson.similar_to not in [nil, []],
            do: context.shell.info("  Similar to: " <> Enum.join(lesson.similar_to, ", "))

          context.shell.info("  Proposed by the #{lesson.proposer_role}" <> agent(lesson))

          if lesson.decided_by,
            do: context.shell.info("  Decided by #{decider(lesson)} at #{lesson.decided_at}")

          if lesson.decision_note, do: context.shell.info("  Note: " <> lesson.decision_note)
        end
      end
    end
  end

  defp agent(%{proposer_agent: nil}), do: ""
  defp agent(lesson), do: " (#{lesson.proposer_agent})"

  defp decider(lesson) do
    cond do
      Lessons.self_approved?(lesson) -> "the coordinator that proposed it"
      String.starts_with?(lesson.decided_by, "grant:") -> "the coordinator"
      true -> lesson.decided_by
    end
  end

  defp source(%{source_kind: "person"} = lesson),
    do: "your words in session #{lesson.session_id}: \"#{lesson.source_quote}\""

  defp source(lesson), do: "dispatch #{lesson.source_ref} (session #{lesson.session_id})"

  @doc "A lesson as data."
  def data(lesson, detail? \\ true) do
    base = %{
      "code" => lesson.code,
      "state" => lesson.state,
      "text" => lesson.text,
      "repository_root" => lesson.repository_root,
      "cited" => lesson.cite_count,
      "last_cited_at" => lesson.last_cited_at,
      "proposed_at" => lesson.inserted_at
    }

    if detail? do
      Map.merge(base, %{
        "source" => %{
          "kind" => lesson.source_kind,
          "ref" => lesson.source_ref,
          "quote" => lesson.source_quote
        },
        "why" => lesson.why,
        "session_id" => lesson.session_id,
        "proposed_by" => lesson.proposed_by,
        "proposer" => %{"role" => lesson.proposer_role, "agent" => lesson.proposer_agent},
        "self_approved" => Lessons.self_approved?(lesson),
        "similar_to" => lesson.similar_to || [],
        "decided_by" => lesson.decided_by,
        "decided_at" => lesson.decided_at,
        "decision_note" => lesson.decision_note,
        "retired_at" => lesson.retired_at
      })
    else
      base
    end
  end

  defp space(opts, context) do
    space = Lessons.space()

    if opts[:json] do
      Command.json(context, space)
    else
      for repository <- space.repositories do
        counts = Enum.map_join(repository.counts, ", ", fn {state, n} -> "#{n} #{state}" end)
        context.shell.info("#{repository.repository}: #{counts}; #{repository.bytes} bytes")
      end

      context.shell.info(
        "Total: #{space.count} lessons, #{space.bytes} bytes; limit " <>
          "#{div(space.limit_bytes, 1024 * 1024)} MB per repository"
      )
    end
  end

  @doc "What a refused lesson operation tells its requester."
  def message(:no_grant), do: "This session has no grant."
  def message(:lesson_not_found), do: "No such lesson."
  def message(:lesson_empty), do: "A lesson needs text."

  def message({:lesson_too_long, max}),
    do: "A lesson is at most #{max} bytes: one rule, not a document."

  def message(:lesson_source_required),
    do:
      "Name the lesson's source: `dispatch` (one of this session's) or `quote` (the person's " <>
        "words in this chat)."

  def message(:lesson_one_source), do: "Name one source: `dispatch` or `quote`, not both."

  def message(:lesson_source_not_found),
    do:
      "Its source was not found: a dispatch of this session, or words the person wrote in " <>
        "this session's chat, quoted exactly."

  def message({:lesson_quote_too_short, min}),
    do: "Quote at least #{min} characters of what the person said."

  def message({:lesson_duplicate, code}),
    do: "The same lesson is already #{code}; nothing was proposed."

  def message({:lessons_space_full, mb}),
    do:
      "Lessons in this repository have reached their #{mb} MB limit; nothing was proposed. " <>
        "The person retires some, or raises the limit in Settings."

  def message({:may_not_propose, role}),
    do: "This #{role} agent may not propose lessons (the Agents page says which may)."

  def message(:not_allowed),
    do: "Only the person, or a coordinator granted this repository, decides its lessons."

  def message({:invalid, :decision}), do: "Decide with approve, reject or replace."

  def message({:lesson_not_proposed, state}),
    do:
      "That lesson is #{state}; only a proposed one can be approved, rejected or replace another."

  def message({:lesson_not_approved, state}),
    do: "That lesson is #{state}; only an approved one can be reworded, retired or replaced."

  def message(:lesson_changed), do: "That lesson was just decided by someone else."
  def message(:non_human_identity), do: "--by must be human:NAME"
  def message({:too_long, field, max}), do: "The #{field} is at most #{max} bytes."
  def message({:invalid, field}), do: "The #{field} must be text."
  def message(other), do: "Refused: #{inspect(other)}"
end
