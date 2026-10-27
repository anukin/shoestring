defmodule Shoestring.CLI.Commands.Dispatch do
  @moduledoc "`shoestring dispatch`: a coordinator hands Shoestring one task under its grant."

  alias Shoestring.Dispatches
  alias Shoestring.CLI.{Command, Jobs, Messages, Refusal}

  @help """
  shoestring dispatch --purpose implement --worker PROVIDER:MODEL --title TEXT
      --brief FILE [--effort LEVEL] [--reviewer PROVIDER:MODEL]
      [--file PATH]... [--stay-out PATH]...
      [--accept TEXT]... [--gate NAME]... [--test PATH]... [--attempts N]
      [--minutes M] [--batch LABEL --batch-size N] [--session ID]
      [--request-id ID] [--repo PATH] [--dry-run] [--json]
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

  TITLE is one line; FILE is the brief the worker reads (up to 16000
  characters). Secret-looking values in either are recorded, and given to
  the worker, as `[REDACTED]`. `--file` hints at files to change, `--stay-out` names paths
  the task must not change, and `--accept` adds acceptance criteria.
  `--reviewer` names a model from another vendor that reviews the change
  before it is accepted (the grant must allow REVIEW and that model):
  blocking findings send the task back to the worker once, then it waits
  for a person. `--attempts` (default 1) and `--minutes` (default 30) are what the
  dispatch reserves from the grant. `--batch` declares a strategy of
  `--batch-size` dispatches; one more is refused.

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
    reviewer: :string,
    of: :string,
    file: :keep,
    stay_out: :keep,
    accept: :keep,
    gate: :keep,
    test: :keep,
    attempts: :integer,
    minutes: :integer,
    batch: :string,
    batch_size: :integer,
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
        request = request!(opts, context)

        if opts[:dry_run] do
          context.with_repo.(fn _repo ->
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

            create(request, context)
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
        if dispatch.title != request.title or dispatch.brief != request.brief do
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

        Command.json(context, Map.put(summary(dispatch), "outcome", Atom.to_string(outcome)))

      {:error, reason} ->
        Refusal.refuse!(message(reason, request))
    end
  end

  defp request!(opts, context) do
    for key <- [:purpose, :worker, :title, :brief],
        is_nil(opts[key]),
        do: Refusal.refuse!("dispatch needs --#{key}")

    session =
      opts[:session] || Map.get(context, :env, &System.get_env/1).("SHOESTRING_SESSION") ||
        Refusal.refuse!(
          "No coordinator session: pass --session ID or set SHOESTRING_SESSION (shoestring grant prints it)"
        )

    {provider, model} =
      case String.split(opts[:worker], ":", parts: 2) do
        [provider, model] when provider != "" and model != "" -> {provider, model}
        _ -> Refusal.refuse!("Use PROVIDER:MODEL for --worker, for example codex:gpt-6-luna")
      end

    brief = read_brief!(Command.expand(opts[:brief], context))

    cond do
      opts[:purpose] == "review" and is_nil(opts[:of]) ->
        Refusal.refuse!("A review needs --of DISPATCH, the completed IMPLEMENT to review")

      opts[:purpose] != "review" and opts[:of] ->
        Refusal.refuse!("--of is only for --purpose review")

      opts[:purpose] in ["explore", "review"] and opts[:reviewer] ->
        Refusal.refuse!("--reviewer is only for --purpose implement")

      true ->
        :ok
    end

    {reviewer_provider, reviewer_model} =
      case opts[:reviewer] && String.split(opts[:reviewer], ":", parts: 2) do
        nil -> {nil, nil}
        [provider, model] when provider != "" and model != "" -> {provider, model}
        _ -> Refusal.refuse!("Use PROVIDER:MODEL for --reviewer, for example claude:opus")
      end

    request = %{
      session_id: session,
      purpose: opts[:purpose],
      provider: provider,
      model: model,
      effort: opts[:effort],
      reviewer_provider: reviewer_provider,
      reviewer_model: reviewer_model,
      title: opts[:title],
      brief: brief,
      target: opts[:of],
      repository: Command.expand(opts[:repo], context) || context.cwd,
      files: Keyword.get_values(opts, :file),
      stay_out: Keyword.get_values(opts, :stay_out),
      accept: Keyword.get_values(opts, :accept),
      gates: Keyword.get_values(opts, :gate),
      tests: Keyword.get_values(opts, :test),
      attempts: Keyword.get(opts, :attempts, 1),
      seconds: Keyword.get(opts, :minutes, 30) * 60,
      batch_label: opts[:batch],
      batch_size: opts[:batch_size]
    }

    Map.put(request, :request_id, opts[:request_id] || derived_request_id(request))
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
           ] ++ if(request.target, do: [request.target], else: []),
           <<0>>
         )
       )
       |> Base.encode16(case: :lower)
       |> binary_part(0, 24))
  end

  @doc "A dispatch as data, with its state derived from its execution."
  def summary(dispatch) do
    %{
      "dispatch_id" => dispatch.id,
      "session_id" => dispatch.session_id,
      "request_id" => dispatch.request_id,
      "purpose" => dispatch.purpose,
      "worker" => "#{dispatch.provider}:#{dispatch.model}",
      "effort" => dispatch.effort,
      "reviewer" =>
        if(dispatch.reviewer_provider,
          do: "#{dispatch.reviewer_provider}:#{dispatch.reviewer_model}"
        ),
      "of" => if(dispatch.purpose == "review", do: dispatch.plan["target_dispatch_id"]),
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
