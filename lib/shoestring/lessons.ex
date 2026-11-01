defmodule Shoestring.Lessons do
  @moduledoc """
  Lessons (iteration 16 B): short, durable rules for work in one repository,
  shared by every agent and vendor that works there. Each one names its
  source, and every use of one is recorded.

  Who does what:

    * **Proposing.** Any agent whose `may_propose_lessons` allows it (by
      default every job but the explorer): the coordinator with its
      `lessons_propose` tool, naming a dispatch of its session or the
      person's words in its chat, quoted exactly; a worker through its
      dispatch (`Shoestring.Lessons.Harvest`), with that dispatch as source.
    * **Checks**, on every proposal: a source Shoestring can find, at most
      1024 bytes, secret-looking values removed, not a repeat of a lesson
      already proposed or approved, and room in the repository's space limit
      (Settings, default 200 MB). Lessons with much the same words are
      marked as similar.
    * **Approving.** The coordinator's own proposal is approved when it
      passes the checks, unless it is much like an approved lesson: then it
      waits, as a worker's does, for the coordinator's decision
      (`decide/4`): approve, reword, reject, or replace the older one.
    * **The person** sees every lesson, and may approve, reject, reword
      (`edit/3`) or retire (`retire/3`) any; their decision stands.

  Approved lessons reach a coordinator in its instructions and through
  `search/3`. They reach a worker only when a dispatch cites them
  (`for_brief/2`): the brief carries their text and the dispatch their codes.

  Keeping and finding lessons is `Shoestring.Lessons.Store`'s; this module
  holds only the rules, so another store can replace the default.
  """

  alias Shoestring.{AgentProfiles, Agents, Authority, Conversations, Dispatches, Grants, Repo}
  alias Shoestring.Harness.Security
  alias Shoestring.Lessons.{Lesson, Store}

  @max_text 1024
  @max_why 500
  @min_quote 12
  @max_quote 500
  @max_cited 5
  @code_alphabet ~c"23456789ABCDEFGHJKMNPQRSTVWXYZ"
  @instructions_lessons 20
  @instructions_bytes 8 * 1024
  @roles ~w(coordinator explorer implementer reviewer)

  def max_text, do: @max_text
  def max_cited, do: @max_cited

  defp store, do: Store.impl()

  # -- Proposing -------------------------------------------------------------

  @doc """
  An agent proposes a lesson. `proposer`: `:session_id`, `:role` (the
  agent's job), and optionally `:agent` (its slug), `:dispatch_id` (a
  worker's own dispatch, its source) and `:origin_key` (where a worker's
  proposal was read from; the same origin adds nothing twice). `attrs`:
  `"text"`, `"why"`, and for the coordinator its source, `"dispatch"` or
  `"quote"`. `{:ok, lesson}` (approved or proposed) or `{:error, reason}`.
  """
  def propose(attrs, %{session_id: session_id, role: role} = proposer) when role in @roles do
    with {:ok, grant} <- proposer_grant(proposer),
         :ok <- may_propose(grant, role, proposer[:agent]),
         {:ok, text} <- lesson_text(attrs["text"]),
         {:ok, why} <- optional_text(attrs["why"], @max_why, :why),
         {:ok, source} <- source(attrs, proposer),
         :ok <- not_duplicate(grant.repository_root, text),
         :ok <- room(grant.repository_root, byte_size(text) + byte_size(why || "")) do
      root = grant.repository_root
      by = Authority.grant_identity(grant.id)
      similar = store().similar(root, text, ~w(proposed approved))
      like_approved? = Enum.any?(similar, &(&1.state == "approved"))
      now = now()

      decided =
        if role == "coordinator" and not like_approved?,
          do: %{state: "approved", decided_by: by, decided_at: now},
          else: %{state: "proposed"}

      lesson =
        struct!(
          Lesson,
          Map.merge(decided, %{
            code: new_code(),
            repository_root: root,
            text: text,
            source_kind: source.kind,
            source_ref: source.ref,
            source_quote: source[:quote],
            why: why,
            session_id: session_id,
            proposed_by: by,
            proposer_role: role,
            proposer_agent: proposer[:agent],
            origin_key: proposer[:origin_key],
            similar_to: Enum.map(similar, & &1.code),
            cite_count: 0
          })
        )

      store().insert(lesson)
    end
  end

  def propose(_attrs, _proposer), do: {:error, :invalid_proposer}

  defp proposer_grant(%{dispatch_id: id}) when is_binary(id) do
    case Dispatches.get(id) do
      %{grant_id: grant_id} -> Grants.get(grant_id) |> found(:no_grant)
      nil -> {:error, :lesson_source_not_found}
    end
  end

  defp proposer_grant(%{session_id: session_id}),
    do: Grants.active(session_id) |> found(:no_grant)

  defp found(nil, reason), do: {:error, reason}
  defp found(value, _reason), do: {:ok, value}

  @doc """
  Whether the agent may propose: its `may_propose_lessons`, read when it
  proposes, so a change on the Agents page applies at once. An agent not in
  the agents table (a session without a team) follows its job's default:
  every job but the explorer.
  """
  def may_propose?(grant, role, agent_slug \\ nil) do
    slug =
      agent_slug ||
        Enum.find_value(get_in(grant.team || %{}, ["agents"]) || [], fn entry ->
          if entry["kind"] == role, do: entry["slug"]
        end)

    case slug && Agents.get_by_slug(slug) do
      %{may_propose_lessons: allowed} when is_boolean(allowed) -> allowed
      _ -> role != "explorer"
    end
  end

  defp may_propose(grant, role, agent),
    do: if(may_propose?(grant, role, agent), do: :ok, else: {:error, {:may_not_propose, role}})

  # -- Deciding --------------------------------------------------------------

  @doc """
  Decides a proposed lesson. `by`: the person (`human:`), or the
  coordinator, under a grant of the lesson's repository. `decision`:
  `"approve"` (`opts[:text]` rewords it), `"reject"` (`opts[:note]`) or
  `"replace"` (`opts[:replaces]`, an approved lesson's code: this one is
  approved, that one retired).
  """
  def decide(code, decision, by, opts \\ []) do
    with %Lesson{} = lesson <- get(code) || {:error, :lesson_not_found},
         :ok <- may_decide(lesson, by),
         :ok <- in_state(lesson, "proposed") do
      case decision do
        "approve" ->
          with {:ok, text} <- reworded(lesson, opts[:text]),
               do: approve(lesson, by, text)

        "reject" ->
          with {:ok, note} <- optional_text(opts[:note], @max_why, :note) do
            transition(lesson, "proposed", %{
              state: "rejected",
              decided_by: by,
              decided_at: now(),
              decision_note: note
            })
          end

        "replace" ->
          replace(lesson, opts[:replaces], by, opts[:text])

        _ ->
          {:error, {:invalid, :decision}}
      end
    end
  end

  defp approve(lesson, by, text),
    do:
      transition(lesson, "proposed", %{
        state: "approved",
        text: text,
        decided_by: by,
        decided_at: now()
      })

  defp replace(lesson, older_code, by, text) do
    with %Lesson{state: "approved"} = older <-
           get(older_code) || {:error, :lesson_not_found},
         true <- older.repository_root == lesson.repository_root || {:error, :lesson_not_found},
         {:ok, text} <- reworded(lesson, text),
         {:ok, approved} <- approve(lesson, by, text),
         {:ok, _retired} <-
           transition(older, "approved", %{
             state: "retired",
             retired_by: by,
             retired_at: now(),
             decision_note: "Replaced by #{approved.code}."
           }) do
      {:ok, approved}
    else
      %Lesson{state: state} -> {:error, {:lesson_not_approved, state}}
      error -> error
    end
  end

  @doc "The person rewords an approved lesson."
  def edit(code, text, by) do
    with :ok <- human(by),
         %Lesson{} = lesson <- get(code) || {:error, :lesson_not_found},
         :ok <- in_state(lesson, "approved"),
         {:ok, text} <- lesson_text(text),
         :ok <- not_duplicate(lesson.repository_root, text, lesson.code) do
      transition(lesson, "approved", %{text: text})
    end
  end

  @doc "The person retires an approved lesson: no longer listed, searched or cited."
  def retire(code, by, note \\ nil) do
    with :ok <- human(by),
         {:ok, note} <- optional_text(note, @max_why, :note),
         %Lesson{} = lesson <- get(code) || {:error, :lesson_not_found},
         :ok <- in_state(lesson, "approved") do
      transition(lesson, "approved", %{
        state: "retired",
        retired_by: by,
        retired_at: now(),
        decision_note: note
      })
    end
  end

  defp transition(lesson, from, changes) do
    case store().transition(lesson, from, changes) do
      {:ok, lesson} -> {:ok, lesson}
      :stale -> {:error, :lesson_changed}
    end
  end

  defp in_state(%Lesson{state: state}, state), do: :ok
  defp in_state(%Lesson{state: state}, "proposed"), do: {:error, {:lesson_not_proposed, state}}
  defp in_state(%Lesson{state: state}, "approved"), do: {:error, {:lesson_not_approved, state}}

  defp reworded(lesson, nil), do: {:ok, lesson.text}
  defp reworded(lesson, ""), do: {:ok, lesson.text}

  defp reworded(lesson, text) do
    with {:ok, text} <- lesson_text(text),
         :ok <- not_duplicate(lesson.repository_root, text, lesson.code),
         do: {:ok, text}
  end

  # The person decides anything; a coordinator decides in the repository its
  # grant covers, while the grant stands.
  defp may_decide(lesson, by) do
    cond do
      Authority.human?(by) ->
        :ok

      Authority.grant?(by) ->
        case Grants.get(String.replace_prefix(by, "grant:", "")) do
          %{revoked_at: nil, repository_root: root} when root == lesson.repository_root -> :ok
          _ -> {:error, :not_allowed}
        end

      true ->
        {:error, :not_allowed}
    end
  end

  defp human(by),
    do: if(Authority.human?(by), do: :ok, else: {:error, :non_human_identity})

  # -- Reading ---------------------------------------------------------------

  @doc "The lesson with `code` (any case), or nil."
  def get(code) when is_binary(code), do: store().get(code |> String.trim() |> String.upcase())
  def get(_code), do: nil

  @doc "Lessons, newest first. Filters: `:repository`, `:state` (one or a list)."
  def list(filters \\ []), do: store().list(filters)

  @doc "The repository's approved lessons that best answer `query`, at most `limit`."
  def search(repository, query, limit \\ 10), do: store().search(repository, query || "", limit)

  @doc "Whether `lesson` was approved by the coordinator that proposed it."
  def self_approved?(%Lesson{decided_by: by, proposed_by: by}) when is_binary(by), do: true
  def self_approved?(_lesson), do: false

  # -- Citing ----------------------------------------------------------------

  @doc """
  The approved lessons of `repository` with `codes`, for a dispatch's brief:
  `{:ok, lessons}` in the order cited, or `{:error, reason}`.
  """
  def for_brief(_repository, []), do: {:ok, []}

  def for_brief(repository, codes) when is_list(codes) do
    codes = codes |> Enum.map(&(&1 |> String.trim() |> String.upcase())) |> Enum.uniq()

    if length(codes) > @max_cited do
      {:error, {:too_many_lessons, @max_cited}}
    else
      Enum.reduce_while(codes, {:ok, []}, fn code, {:ok, acc} ->
        case get(code) do
          %Lesson{state: "approved", repository_root: ^repository} = lesson ->
            {:cont, {:ok, acc ++ [lesson]}}

          _ ->
            {:halt, {:error, {:lesson_not_approved, code}}}
        end
      end)
    end
  end

  @doc "The text a brief carries for its cited lessons; empty for none."
  def brief_block([]), do: ""

  def brief_block(lessons),
    do:
      "\n\nLessons for this repository (cited by the coordinator):\n" <>
        Enum.map_join(lessons, "\n", &"- #{&1.code}: #{&1.text}") <> "\n"

  @doc """
  What a worker of `purpose` is told about proposing a lesson, when its agent
  may; empty otherwise. An IMPLEMENT writes it to `lessons_file/0` in its
  worktree (never committed); an EXPLORE or REVIEW puts it in its report.
  """
  def proposal_hint(false, _purpose), do: ""

  def proposal_hint(true, "implement"),
    do:
      "\n\nIf this task taught you a rule that will hold for later work in this repository " <>
        "(a check that fails for a reason a worker could not know, a command that must be run " <>
        "a certain way), write it to `#{lessons_file()}` in the working directory, one `- ` " <>
        "line each, at most 3, each under #{@max_text} bytes. Never commit that file. Most " <>
        "tasks teach none; then write nothing.\n"

  def proposal_hint(true, _call),
    do:
      "\n\nIf this taught you a rule that will hold for later work in this repository, put it " <>
        "in `lessons` (at most 3, each under #{@max_text} bytes); most answers have none.\n"

  @doc "Where an IMPLEMENT worker writes the lessons it proposes, in its worktree."
  def lessons_file, do: ".shoestring/lessons.md"

  @doc "Counts one citation of each of `codes`."
  def cite(codes, at \\ now()), do: store().cite(codes, at)

  # -- Instructions and space ---------------------------------------------------

  @doc """
  The coordinator's instructions about lessons for `repository`: how to cite,
  propose and decide them, and the newest approved ones (at most
  #{@instructions_lessons}, within #{@instructions_bytes} bytes).
  """
  def instructions(repository) do
    {listed, _bytes} =
      list(repository: repository, state: "approved")
      |> Enum.reduce_while({[], 0}, fn lesson, {acc, bytes} ->
        line = "- `#{lesson.code}`: #{lesson.text}"

        if length(acc) >= @instructions_lessons or bytes + byte_size(line) > @instructions_bytes,
          do: {:halt, {acc, bytes}},
          else: {:cont, {acc ++ [line], bytes + byte_size(line)}}
      end)

    lessons =
      case listed do
        [] -> "None approved yet."
        lines -> Enum.join(lines, "\n")
      end

    """

    ## Lessons for this repository

    Rules for work in this repository, shared by every agent. A worker sees one
    only when you cite it: pass its code in the dispatch's `lessons` (at most
    #{@max_cited}). `lessons_search` finds more than are listed here.

    #{lessons}

    You approve lessons. Your own proposal (`lessons_propose`, naming a dispatch
    or quoting the person exactly) is approved when Shoestring's checks pass,
    unless it is much like an approved one. Workers propose through their
    dispatches; `runs_show` lists what a dispatch proposed, and you decide each
    with `lessons_decide`: approve (rewording it if needed), reject, or replace
    the older lesson it repeats. Keep a lesson only when it is:

    - durable: still true after this task;
    - actionable: one rule a worker can follow, not advice;
    - not already in the repository's own documents;
    - earned: it cost something, such as a failed check, a review finding that
      came back, or the person correcting you.

    The person sees every lesson and may reword or retire any.
    """
  end

  @doc "The space lessons may take in one repository, in bytes (Settings)."
  def limit_bytes, do: AgentProfiles.settings().lessons_space_mb * 1024 * 1024

  @doc """
  The space lessons take: per repository and in total, the count in each
  state and the bytes kept (text, quoted source and reasons), with the limit.
  """
  def space(repository \\ nil),
    do: Map.put(store().space(repository), :limit_bytes, limit_bytes())

  @doc "The person explicitly reassigns lessons after moving a repository; codes and sources survive."
  def move_repository(from, to, by) do
    with :ok <- human(by),
         true <-
           (is_binary(from) and is_binary(to) and from != to) ||
             {:error, :invalid_repository_move} do
      store().move_repository(from, to)
    end
  end

  defp room(repository, incoming) do
    limit = limit_bytes()

    if store().space(repository).bytes + incoming > limit,
      do: {:error, {:lessons_space_full, div(limit, 1024 * 1024)}},
      else: :ok
  end

  # -- Checks --------------------------------------------------------------

  defp lesson_text(text) when is_binary(text) do
    text = text |> Security.redact_retained() |> String.trim()

    cond do
      text == "" -> {:error, :lesson_empty}
      byte_size(text) > @max_text -> {:error, {:lesson_too_long, @max_text}}
      true -> {:ok, text}
    end
  end

  defp lesson_text(_text), do: {:error, :lesson_empty}

  defp optional_text(nil, _max, _field), do: {:ok, nil}
  defp optional_text("", _max, _field), do: {:ok, nil}

  defp optional_text(text, max, field) when is_binary(text) do
    text = text |> Security.redact_retained() |> String.trim()
    if byte_size(text) > max, do: {:error, {:too_long, field, max}}, else: {:ok, text}
  end

  defp optional_text(_text, _max, field), do: {:error, {:invalid, field}}

  # A worker's source is its own dispatch; the coordinator names one.
  defp source(_attrs, %{dispatch_id: id}) when is_binary(id),
    do: {:ok, %{kind: "dispatch", ref: id}}

  defp source(%{"dispatch" => id, "quote" => quote}, _proposer)
       when is_binary(id) and is_binary(quote),
       do: {:error, :lesson_one_source}

  defp source(%{"dispatch" => id}, %{session_id: session_id}) when is_binary(id) do
    case Dispatches.get(id) do
      %{session_id: ^session_id} = dispatch -> {:ok, %{kind: "dispatch", ref: dispatch.id}}
      _ -> {:error, :lesson_source_not_found}
    end
  end

  defp source(%{"quote" => quote}, %{session_id: session_id}) when is_binary(quote) do
    quote = String.trim(quote)

    cond do
      String.length(quote) < @min_quote ->
        {:error, {:lesson_quote_too_short, @min_quote}}

      byte_size(quote) > @max_quote ->
        {:error, {:too_long, :quote, @max_quote}}

      true ->
        wanted = normal(quote)

        case Enum.find(person_messages(session_id), &String.contains?(normal(&1.text), wanted)) do
          nil -> {:error, :lesson_source_not_found}
          message -> {:ok, %{kind: "person", ref: message.id, quote: quote}}
        end
    end
  end

  defp source(_attrs, _proposer), do: {:error, :lesson_source_required}

  # The person's own messages in every conversation of the session.
  defp person_messages(session_id) do
    import Ecto.Query

    from(c in Conversations.Conversation, where: c.session_id == ^session_id)
    |> Repo.all()
    |> Enum.flat_map(fn conversation ->
      case Conversations.history(conversation) do
        {:ok, history} -> Enum.filter(history.messages, &(&1.kind == :human))
        _ -> []
      end
    end)
  end

  defp normal(text),
    do: text |> String.downcase() |> String.split(~r/\s+/u, trim: true) |> Enum.join(" ")

  defp not_duplicate(repository, text, except \\ nil) do
    wanted = normal(text)

    case Enum.find(
           list(repository: repository, state: ["proposed", "approved"]),
           &(&1.code != except and normal(&1.text) == wanted)
         ) do
      nil -> :ok
      lesson -> {:error, {:lesson_duplicate, lesson.code}}
    end
  end

  defp new_code do
    code = "L-" <> for(_ <- 1..6, into: "", do: <<Enum.random(@code_alphabet)>>)
    if store().get(code), do: new_code(), else: code
  end

  defp now, do: DateTime.utc_now()
end
