defmodule Shoestring.CLI.Commands.Dispatch do
  @moduledoc "`shoestring dispatch`: a coordinator hands Shoestring one task under its grant."

  alias Shoestring.Dispatches
  alias Shoestring.CLI.{Command, Jobs, Messages, Refusal}

  @help """
  shoestring dispatch --purpose implement (--agent NAME | --worker PROVIDER:MODEL) --title TEXT
      --brief FILE [--effort LEVEL] [--reviewer PROVIDER:MODEL]
      [--file PATH]... [--stay-out PATH]...
      [--accept TEXT]... [--gate NAME]... [--test PATH]... [--attempts N]
      [--minutes M] [--batch LABEL --batch-size N] [--after DISPATCH]
      [--lesson CODE]... [--tasks FILE]
      [--session ID] [--request-id ID] [--repo PATH] [--dry-run] [--json]
  shoestring dispatch --purpose explore --worker PROVIDER:MODEL --title TEXT
      --brief FILE [--effort LEVEL] [common options]
  shoestring dispatch --purpose review --of DISPATCH --worker PROVIDER:MODEL
      --title TEXT --brief FILE [common options]

  For a coordinator (Claude Code, Codex or opencode) acting under the grant
  a person gave its session (`shoestring grant`). The task runs as a
  sandboxed Elf on WORKER in a private copy of the repository at its `HEAD`;
  the checks (`--gate`, `--test`, or detected as for `shoestring do`) decide
  acceptance, and the result is a verified commit to fetch and merge. Your
  checkout is never changed.

  `--agent` names an agent of the session's team (its slug, or its job:
  explorer, implementer, reviewer) instead of a worker: its model and effort
  are used. An agent's limit (its most minutes per dispatch) bounds every
  dispatch of its job on its model, however it is named; asking for more is
  refused.

  TITLE is one line; FILE is the brief the worker reads (up to 16000
  characters). Secret-looking values in either are recorded, and given to
  the worker, as `[REDACTED]`. `--file` hints at files to change, `--stay-out` names paths
  the task must not change, and `--accept` adds acceptance criteria.
  `--reviewer` names a model from another vendor that reviews the change
  before it is accepted (the grant must allow REVIEW and that model):
  blocking findings send the task back to the worker once, then it waits
  for a person. `--attempts` (default 1) and `--minutes` are what the
  dispatch reserves from the grant: an IMPLEMENT's minutes default to 30;
  an EXPLORE or REVIEW runs until it answers, up to its minutes or else the
  grant's per-dispatch limit. A finished dispatch counts the time it took. `--batch` declares a strategy of
  `--batch-size` dispatches; one more is refused.

  `--lesson CODE` cites an approved lesson of this repository (at most
  #{Shoestring.Lessons.max_cited()}; `shoestring lessons list`): the worker gets its text after the brief,
  and the dispatch records it. A lesson reaches a worker only this way.

  `--tasks FILE` (IMPLEMENT only) makes a batch: FILE is a JSON list of 2
  to 8 tasks, each `{"title", "brief" (optional, at most 1000 characters),
  "files" (the files or directories it changes)}`. The tasks share the
  coordinator's brief, checks and reviewer; each worker changes only its own
  files, and a change outside them goes to the person. A batch whose files
  overlap, or touch something shared (lockfiles, configuration, migrations,
  symlinks), is refused. Its tasks run at once, each in its own worktree,
  when the person's Settings allow more than one task at a time, else one
  after another; each takes one of the grant's parallel places, and its
  attempts and minutes count per task. The result is one commit per task:
  `runs show` lists them and the commands that take them all. When Settings
  allow more than one task at a time, separate IMPLEMENT dispatches also run
  side by side, up to that number, if each names its own separate files with
  `--file`; one whose files overlap a running dispatch in the same
  repository, touch something shared, or are not named waits for it.

  `--after DISPATCH` (IMPLEMENT only) follows another IMPLEMENT of this
  session: the new one is recorded `chained`, its room in the grant
  reserved, and starts by itself from DISPATCH's verified commit once
  DISPATCH completes, instead of from `HEAD`. Taking its commit takes both.
  It waits as long as DISPATCH does (a person deciding included), and is
  called off, its room released, if DISPATCH is cancelled.

  The session is ID or SHOESTRING_SESSION. The request id (default: derived
  from the session, purpose, worker, title and brief) makes a retry return
  the same dispatch. A dispatch the grant does not cover is refused and
  nothing is queued. `--dry-run` checks the grant and the plan and records
  nothing; it also shows the advice for the worker and its provider's
  capacity outlook (`shoestring capacity`). Output is JSON on stdout;
  follow it with `shoestring wait` and `shoestring runs show`.

  EXPLORE answers the brief from a private copy of the repository at its
  `HEAD`, read-only and without network, in one call to WORKER: `runs show`
  then has a report of findings, each citing files and lines, and open
  questions. REVIEW has WORKER, a model of another vendor than the one that
  wrote it, review the completed IMPLEMENT dispatch DISPATCH of this session:
  its diff from its base, its contract and its checks. The findings' rules,
  not the reviewer, decide `approved` or `changes_requested`. Neither
  changes anything; each needs the grant to allow its purpose and model.
  """

  @switches [
    purpose: :string,
    worker: :string,
    title: :string,
    brief: :string,
    effort: :string,
    agent: :string,
    reviewer: :string,
    of: :string,
    file: :keep,
    stay_out: :keep,
    lesson: :keep,
    accept: :keep,
    gate: :keep,
    test: :keep,
    attempts: :integer,
    minutes: :integer,
    batch: :string,
    batch_size: :integer,
    after: :string,
    tasks: :string,
    session: :string,
    request_id: :string,
    repo: :string,
    dry_run: :boolean,
    json: :boolean
  ]

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        # Checked before the repository opens; the request itself, which
        # reads the session's team for `--agent`, only once it is open.
        fields = fields!(opts, context)

        if opts[:dry_run] do
          context.with_repo.(fn _repo ->
            request = request!(fields)

            case Dispatches.dry_run(request) do
              {:ok, report} ->
                capacity = Shoestring.CLI.Commands.Capacity.for_provider(request.provider)
                Command.json(context, Map.put(report, "capacity", capacity))

              {:error, reason} ->
                Refusal.refuse!(message(reason, request))
            end
          end)
        else
          # Inside the repository: a checkout knows its database only then,
          # and the check compares it with the service's.
          context.with_repo.(fn _repo ->
            case context.service.() do
              :ok -> :ok
              {:error, reason} -> Refusal.refuse!(Messages.message(reason, context.start_hint))
            end

            create(request!(fields), context)
          end)
        end

      _ ->
        Refusal.usage!("dispatch")
    end
  end

  defp create(request, context) do
    result =
      case Map.get(context, :oban) do
        nil -> Jobs.with_client(&Dispatches.create(request, oban: &1))
        client -> Dispatches.create(request, oban: client)
      end

    case result do
      {:ok, dispatch, outcome} ->
        # The stored brief also carries the lessons text Shoestring adds, so
        # it is compared before that: only a real redaction is reported.
        if redacted?(request.title) or redacted?(request.brief) do
          context.shell.error(
            "Secret-looking text in the title or brief was recorded as [REDACTED]; " <>
              "the worker reads the redacted brief."
          )
        end

        context.shell.error(
          if(outcome == :replayed,
            do: "Already dispatched as #{dispatch.id}.",
            else: "Dispatched #{dispatch.id}. Wait for it with: shoestring wait #{dispatch.id}"
          )
        )

        created = created(dispatch, outcome)

        if left_out = created["left_out"] do
          context.shell.error(
            "Not in its copy (the repository at HEAD): uncommitted " <>
              Enum.join(left_out["paths"], ", ") <>
              if(left_out["more"] > 0, do: " and #{left_out["more"]} more", else: "") <> "."
          )
        end

        Command.json(context, created)

      {:error, reason} ->
        Refusal.refuse!(message(reason, request))
    end
  end

  defp redacted?(text) when is_binary(text),
    do: Shoestring.Harness.Security.redact_retained(text) != text

  defp redacted?(_text), do: false

  defp fields!(opts, context) do
    for key <- [:purpose, :title, :brief],
        is_nil(opts[key]),
        do: Refusal.refuse!("dispatch needs --#{key}")

    if is_nil(opts[:worker]) and is_nil(opts[:agent]),
      do: Refusal.refuse!("dispatch needs --agent NAME or --worker PROVIDER:MODEL")

    session =
      opts[:session] || Map.get(context, :env, &System.get_env/1).("SHOESTRING_SESSION") ||
        Refusal.refuse!(
          "No coordinator session: pass --session ID or set SHOESTRING_SESSION (shoestring grant prints it)"
        )

    opts
    |> Map.new()
    |> Map.merge(%{
      session_id: session,
      brief: read_brief!(Command.expand(opts[:brief], context)),
      repository: Command.expand(opts[:repo], context) || context.cwd,
      files: Keyword.get_values(opts, :file),
      stay_out: Keyword.get_values(opts, :stay_out),
      lessons: Keyword.get_values(opts, :lesson),
      tasks: opts[:tasks] && read_tasks!(Command.expand(opts[:tasks], context)),
      accept: Keyword.get_values(opts, :accept),
      gates: Keyword.get_values(opts, :gate),
      tests: Keyword.get_values(opts, :test)
    })
  end

  defp request!(fields) do
    case build_request(fields) do
      {:ok, request} -> request
      {:error, message} -> Refusal.refuse!(message)
    end
  end

  @doc """
  A dispatch request from already-resolved fields, as `Shoestring.Dispatches`
  takes it, or `{:error, message}`. Shared by this command and the
  coordinator's MCP `dispatch` tool (`Shoestring.Coordinator.Tools`), so both
  refuse the same way. `fields`: `:session_id`, `:repository`, `:brief` (its
  text) and the options as named in `@switches`, with `:files`, `:stay_out`,
  `:accept`, `:gates` and `:tests` as lists.
  """
  @spec build_request(map()) :: {:ok, map()} | {:error, String.t()}
  def build_request(fields) do
    with {:ok, fields} <- named_agent(fields),
         {:ok, {provider, model}} <-
           model_pair(
             fields[:worker],
             "Use PROVIDER:MODEL for --worker, for example codex:gpt-6-luna"
           ),
         :ok <- purpose_options(fields),
         {:ok, {reviewer_provider, reviewer_model}} <-
           reviewer_pair(fields[:reviewer]) do
      request = %{
        session_id: fields.session_id,
        purpose: fields[:purpose],
        provider: provider,
        model: model,
        effort: fields[:effort],
        agent: fields[:agent],
        reviewer_provider: reviewer_provider,
        reviewer_model: reviewer_model,
        title: fields[:title],
        brief: fields.brief,
        target: fields[:of],
        repository: fields.repository,
        files: Map.get(fields, :files, []),
        stay_out: Map.get(fields, :stay_out, []),
        accept: Map.get(fields, :accept, []),
        gates: Map.get(fields, :gates, []),
        tests: Map.get(fields, :tests, []),
        attempts: fields[:attempts] || 1,
        seconds: fields[:minutes] && fields[:minutes] * 60,
        batch_label: fields[:batch],
        batch_size: fields[:batch_size],
        after_dispatch: fields[:after],
        lessons: Map.get(fields, :lessons, []),
        tasks: fields[:tasks] || []
      }

      {:ok, Map.put(request, :request_id, fields[:request_id] || derived_request_id(request))}
    end
  end

  # `--agent` names an agent of the session's team (its slug, or its job:
  # explorer, implementer, reviewer): its model and effort are the worker's.
  defp named_agent(%{agent: name} = fields) when is_binary(name) do
    team =
      case Shoestring.Grants.active(fields.session_id) do
        %{team: team} -> team
        nil -> nil
      end

    cond do
      fields[:worker] ->
        {:error, "Name the agent or the worker, not both"}

      agent = Shoestring.Agents.find(team, name) ->
        {:ok,
         Map.merge(fields, %{
           worker: "#{agent["provider"]}:#{agent["model"]}",
           effort: fields[:effort] || agent["effort"]
         })}

      team == nil ->
        {:error,
         "This session has no team, so it has no agents to name; use --worker PROVIDER:MODEL"}

      true ->
        {:error,
         "No agent #{inspect(name)} in this session's team: " <>
           Enum.map_join(team["agents"], ", ", &"#{&1["slug"]} (#{&1["kind"]})")}
    end
  end

  defp named_agent(fields), do: {:ok, fields}

  defp model_pair(value, refusal) do
    case is_binary(value) && String.split(value, ":", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {:ok, {provider, model}}
      _ -> {:error, refusal}
    end
  end

  defp reviewer_pair(nil), do: {:ok, {nil, nil}}

  defp reviewer_pair(value),
    do: model_pair(value, "Use PROVIDER:MODEL for --reviewer, for example claude:opus")

  defp purpose_options(fields) do
    cond do
      fields[:purpose] == "review" and is_nil(fields[:of]) ->
        {:error, "A review needs --of DISPATCH, the completed IMPLEMENT to review"}

      fields[:purpose] != "review" and fields[:of] ->
        {:error, "--of is only for --purpose review"}

      fields[:purpose] in ["explore", "review"] and fields[:reviewer] ->
        {:error, "--reviewer is only for --purpose implement"}

      fields[:purpose] != "implement" and fields[:after] ->
        {:error, "--after is only for --purpose implement"}

      fields[:purpose] != "implement" and fields[:tasks] not in [nil, []] ->
        {:error, "--tasks is only for --purpose implement"}

      true ->
        :ok
    end
  end

  defp read_tasks!(path) do
    with {:ok, %{type: :regular, size: size}} when size <= 65_536 <- File.stat(path),
         {:ok, tasks} when is_list(tasks) <- Jason.decode(File.read!(path)),
         true <- Enum.all?(tasks, &is_map/1) do
      tasks
    else
      _ ->
        Refusal.refuse!(
          "--tasks needs a JSON list of tasks, each {\"title\", \"brief\", \"files\"}: #{path}"
        )
    end
  end

  defp read_brief!(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= 65_536 ->
        File.read!(path)

      {:ok, %{type: :regular}} ->
        Refusal.refuse!("The brief is over 64 KiB; keep it to the task.")

      _ ->
        Refusal.refuse!("Brief file not found: #{path}")
    end
  end

  defp derived_request_id(request) do
    "auto-" <>
      (:crypto.hash(
         :sha256,
         Enum.join(
           [
             request.session_id,
             request.purpose,
             request.provider,
             request.model,
             request.title,
             request.brief
           ] ++
             if(request.target, do: [request.target], else: []) ++
             if(request.after_dispatch, do: ["after", request.after_dispatch], else: []) ++
             if(request.lessons != [], do: ["lessons" | request.lessons], else: []) ++
             if(request.tasks != [], do: ["tasks", Jason.encode!(request.tasks)], else: []),
           <<0>>
         )
       )
       |> Base.encode16(case: :lower)
       |> binary_part(0, 24))
  end

  @doc """
  A new or replayed dispatch as its requester sees it: the summary, the
  outcome, and the uncommitted paths its copy left out (`left_out`).
  """
  def created(dispatch, outcome) do
    dispatch
    |> summary()
    |> Map.put("outcome", Atom.to_string(outcome))
    |> Map.put("left_out", Dispatches.left_out(dispatch.repository_root))
  end

  @doc "A dispatch as data, with its state derived from its execution."
  def summary(dispatch) do
    %{
      "dispatch_id" => dispatch.id,
      "session_id" => dispatch.session_id,
      "request_id" => dispatch.request_id,
      "purpose" => dispatch.purpose,
      "agent" => dispatch.agent,
      "worker" => "#{dispatch.provider}:#{dispatch.model}",
      "effort" => dispatch.effort,
      "reviewer" =>
        if(dispatch.reviewer_provider,
          do: "#{dispatch.reviewer_provider}:#{dispatch.reviewer_model}"
        ),
      "of" => if(dispatch.purpose == "review", do: dispatch.plan["target_dispatch_id"]),
      "after" => dispatch.after_dispatch_id,
      "lessons" => dispatch.lesson_codes || [],
      "tasks" => dispatch.task_count || 1,
      "title" => dispatch.title,
      "state" => Dispatches.state(dispatch),
      "goal_id" => dispatch.goal_id,
      "execution_id" => dispatch.execution_id,
      "repository_root" => dispatch.repository_root,
      "base_revision" => dispatch.base_revision,
      "reserved" => %{
        "attempts" => dispatch.max_attempts,
        "seconds" => dispatch.max_duration_seconds
      },
      "batch" =>
        if(dispatch.batch_label,
          do: %{"label" => dispatch.batch_label, "size" => dispatch.batch_size}
        ),
      "error" => dispatch.error,
      "created_at" => dispatch.inserted_at
    }
  end

  @doc false
  def message(:no_grant, request),
    do:
      "No grant for session #{request.session_id}. Ask the person to run, in a terminal: " <>
        "shoestring grant --models #{request.provider}:#{request.model} --session #{request.session_id}"

  def message({:over_agent_limit, agent, minutes}, _request),
    do:
      "The #{agent} agent may take at most #{minutes} minutes per dispatch. Ask for less, " <>
        "or ask the person to raise its limit (the Agents page, or shoestring agents). " <>
        "Nothing was queued."

  def message(:after_not_found, request),
    do: "No dispatch #{request.after_dispatch} in this session to follow. Nothing was queued."

  def message(:after_not_implement, _request),
    do: "Only an IMPLEMENT dispatch can be followed: it has a commit. Nothing was queued."

  def message(:after_other_repository, _request),
    do: "The dispatch to follow is in another repository. Nothing was queued."

  def message({:after_unusable, state}, _request),
    do:
      "The dispatch to follow is #{state}: it has no commit to start from. " <>
        "Dispatch without --after, or after another. Nothing was queued."

  def message({:lesson_not_approved, code}, _request),
    do:
      "#{code} is not an approved lesson of this repository (shoestring lessons list). " <>
        "Nothing was queued."

  def message({:too_many_lessons, max}, _request),
    do: "A dispatch cites at most #{max} lessons. Nothing was queued."

  def message(:after_implement_only, _request),
    do: "Only an IMPLEMENT can follow another dispatch. Nothing was queued."

  def message({:unknown_agent, name}, _request),
    do: "No agent #{inspect(name)} in this session's team. Nothing was queued."

  def message({:agent_purpose, agent, kind, purpose}, _request),
    do:
      "#{agent} is an #{kind} agent; it does not take #{String.upcase(purpose)} dispatches. " <>
        "Nothing was queued."

  def message({:outside_grant, limit}, _request),
    do: "Outside the grant: #{limit(limit)}. Nothing was queued."

  def message({:purpose_not_available, purpose}, _request),
    do: "#{String.upcase(purpose)} dispatches are not available yet; only IMPLEMENT is."

  def message({:model_not_enabled, model}, _request),
    do: "#{model} is not an enabled model. See shoestring models show."

  def message({:model_unavailable, model}, _request),
    do: "#{model} is no longer offered by its harness (shoestring models refresh)."

  def message({:effort_not_offered, effort}, request),
    do: "#{request.provider}:#{request.model} does not offer effort #{effort}."

  def message({:harness_cannot, provider, :implement}, _request),
    do: "#{provider} cannot run tasks."

  def message({:harness_cannot, provider, :review}, _request), do: "#{provider} cannot review."

  def message({:harness_cannot, provider, :explore}, _request),
    do: "#{provider} cannot explore; use Claude Code or Codex."

  def message(:review_target_not_found, _request),
    do: "No such dispatch in this session to review."

  def message({:batch_too_large, max}, _request),
    do: "A batch has at most #{max} tasks. Nothing was queued."

  def message({:batch_task_files, n}, _request),
    do:
      "Task #{n} of the batch needs `files`: the files or directories it changes (relative " <>
        "paths, at most 32). Nothing was queued."

  def message({:batch_scopes, blockers}, _request) do
    reasons =
      blockers
      |> Enum.take(5)
      |> Enum.map_join("; ", fn blocker ->
        what = blocker["path"] || Enum.join(blocker["paths"] || [], " and ")

        case blocker["reason"] do
          "scope_overlap" ->
            "tasks #{Enum.join(blocker["task_ids"], " and ")} both change #{what}"

          "shared_surface" ->
            "#{what} is shared (lockfiles, configuration, migrations)"

          "symlink_scope" ->
            "#{what} is or holds a symlink"

          reason ->
            "#{blocker["task_id"]}: #{reason}#{if what != "", do: " #{what}"}"
        end
      end)

    "These tasks cannot run side by side: #{reasons}. Dispatch them one after another " <>
      "(`after`), or split their files apart. Nothing was queued."
  end

  def message(:review_target_not_implement, _request),
    do: "Only an IMPLEMENT dispatch can be reviewed."

  def message({:review_target_not_completed, state}, _request),
    do: "That dispatch is #{state}; only a completed IMPLEMENT can be reviewed."

  def message(:review_target_other_repository, _request),
    do: "That dispatch is in another repository."

  def message(reason, _request)
      when reason in [:review_target_unavailable, :review_worktree_missing],
      do: "The reviewed dispatch's result can no longer be read (#{reason})."

  def message(:review_packet_too_large, _request),
    do: "The change is too large to review in one call (its diff is over 200 kB)."

  def message({:reviewer_same_vendor, reviewer}, request),
    do:
      "#{reviewer} is the same vendor as the worker #{request.provider}:#{request.model} " <>
        "(or its vendor cannot be told); choose a reviewer from another vendor."

  def message({:brief_too_large, max}, _request), do: "The brief is over #{max} characters."

  def message({:invalid_dispatch, field}, _request),
    do: "Invalid --#{field |> to_string() |> String.replace("_", "-")}."

  def message(:invalid_request_id, _request), do: "Invalid --request-id."

  def message(:request_id_conflict, _request),
    do: "That request id was used for a different dispatch; pass another --request-id."

  def message({:dispatch_failed, code}, _request),
    do: "That dispatch failed to start (#{code}); dispatch again with another --request-id."

  def message({:batch_full, label}, _request),
    do: "Batch #{label} already has all its declared dispatches."

  def message({:batch_size_changed, label}, _request),
    do: "Batch #{label} was declared with another size."

  def message({:invalid_plan, _changeset}, _request),
    do: "The task does not make a valid plan; check --file, --test and --accept."

  def message(reason, _request), do: Messages.message(reason)

  defp limit(:repository), do: "it covers another repository"
  defp limit(:purpose), do: "that purpose is not granted"
  defp limit(:model), do: "that model is not granted"
  defp limit(:dispatches), do: "not enough attempts left"
  defp limit(:parallel), do: "as many dispatches as it allows are already queued or running"
  defp limit(:dispatch_duration), do: "one dispatch may not take that long"
  defp limit(:total_duration), do: "not enough time left"
  defp limit(:revoked), do: "it was revoked"
end
