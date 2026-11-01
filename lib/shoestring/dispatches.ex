defmodule Shoestring.Dispatches do
  @moduledoc """
  A coordinator hands Shoestring one task under its grant (iteration 14
  package D).

  An IMPLEMENT dispatch becomes ordinary Shoestring work: a goal, a one-task
  plan authored and approved under the grant (`grant:ID`), and an execution
  the service runs as a sandboxed Elf in a private copy of the repository.
  The checks decide acceptance and the result is a verified commit to fetch
  and merge; the user's checkout is never changed. The worker, model, effort
  and the coordinator's brief come from this dispatch record, which is what
  the execution binding resolves (`Shoestring.Cobbler.ExecutionProfile`).
  With a reviewer (`:reviewer_provider`, `:reviewer_model`) from another
  vendor than the worker, iteration 8's cross-review runs before the task is
  accepted: blocking findings send it back to the worker once, then it waits
  for a person. Without one, dispatched work is not cross-reviewed.

  The grant's limits are checked in the same immediate transaction that
  records the dispatch, so two concurrent dispatches cannot both take room
  only one fits. `(session, request id)` makes a dispatch idempotent: the
  same request returns the same dispatch, and one interrupted part-way
  resumes from its recorded plan. A dry run validates and checks the grant
  without recording anything.

  The coordinator's free text (the title, the brief and a cancellation
  reason) is redacted with `Shoestring.Harness.Security.redact_retained/1`
  before anything is checked or recorded: secret-looking values become
  `[REDACTED]` and the rest of the text stays, so it can be stored in the
  plan and the run's events, which refuse secrets. The worker gets the
  redacted brief.
  """
  import Ecto.Query

  alias Shoestring.{
    AgentProfiles,
    Agents,
    Authority,
    Grants,
    Harnesses,
    Lessons,
    ModelCatalog,
    Repo
  }

  alias Shoestring.Cobbler.{ExecutionControl, ExecutionProfile, Intake, PlanContract, Plans}
  alias Shoestring.Cobbler.{Parallelism, PlanIndependence}
  alias Shoestring.CLI.Result
  alias Shoestring.Dispatches.{Call, Calls, ChainWorker, Dispatch}
  alias Shoestring.Grants.Grant
  alias Shoestring.Harness.{RunRecord, Security}
  alias Shoestring.Trajectory.Goal

  @task_id "dispatch"
  @max_brief 16_000
  @request_id ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,99}\z/
  @available ~w(implement explore review)
  @calls ~w(explore review)
  @capability %{"implement" => :implement, "explore" => :explore, "review" => :review}

  @type request :: %{
          required(:session_id) => String.t(),
          required(:request_id) => String.t(),
          required(:purpose) => String.t(),
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:title) => String.t(),
          required(:brief) => String.t(),
          required(:repository) => String.t(),
          optional(atom()) => term()
        }

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Dispatch, id)
      :error -> nil
    end
  end

  @doc "Latest durable harness run for a dispatch's goal, including completed runs."
  def latest_run(%{goal_id: nil}), do: nil

  def latest_run(%{goal_id: goal_id}) do
    Repo.one(
      from r in Shoestring.Harness.RunRecord,
        where: r.goal_id == ^goal_id,
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 1
    )
  end

  def list(session_id \\ nil) do
    Dispatch
    |> then(&if(session_id, do: where(&1, [d], d.session_id == ^session_id), else: &1))
    |> order_by([d], [d.inserted_at, d.id])
    |> Repo.all()
  end

  @doc """
  Validates `request` and checks it against the session's grant without
  recording anything. Returns the plan it would run (an EXPLORE or REVIEW
  call's contract) and the grant's room.
  """
  def dry_run(request) do
    with {:ok, prepared} <- prepare(request),
         %Grant{} = grant <- Grants.active(request.session_id) || {:error, :no_grant} do
      usage = usage(grant)

      {:ok,
       %{
         "advice" => if(request.purpose == "implement", do: advice(prepared)),
         "would_dispatch" => Grants.check(grant, check_request(prepared), usage) == :ok,
         "grant_check" => check_result(Grants.check(grant, check_request(prepared), usage)),
         "grant" => room(grant, usage),
         "plan" => prepared.contract.content,
         "plan_digest" => prepared.contract.digest,
         "left_out" => left_out(prepared.root)
       }}
    end
  end

  # What past runs of this worker on this kind of task looked like.
  defp advice(prepared) do
    request = prepared.request
    [task | _] = prepared.contract.content["tasks"]

    kind = %{
      "harness" => request.provider,
      "model" => request.model,
      "effort" => Map.get(request, :effort),
      "purpose" => request.purpose,
      "task_class" =>
        "gates:" <>
          (task["gates"]
           |> Enum.map(& &1["gate"])
           |> Enum.uniq()
           |> Enum.sort()
           |> Enum.join(","))
    }

    Shoestring.Advice.for_kind(kind) ||
      %{
        "kind" => kind,
        "runs" => 0,
        "estimate" => nil,
        "note" => "no estimate yet (0 of #{Shoestring.Advice.min_runs()} runs)"
      }
  end

  @doc """
  Records and starts a dispatch. `{:ok, dispatch, :recorded | :replayed}` or
  `{:error, reason}`. Options: `:oban` (the job client) and `:now`.
  """
  def create(request, opts \\ []) do
    case existing(request) do
      {:ok, %Dispatch{state: state} = dispatch} when state in ~w(started chained cancelled) ->
        {:ok, dispatch, :replayed}

      {:ok, %Dispatch{state: "creating"} = dispatch} ->
        start(dispatch, opts, :replayed)

      {:ok, %Dispatch{state: "failed"} = dispatch} ->
        {:error, {:dispatch_failed, dispatch.error}}

      {:error, _} = error ->
        error

      nil ->
        with {:ok, prepared} <- prepare(request), do: reserve(prepared, opts)
    end
  end

  defp existing(%{session_id: session_id, request_id: request_id} = request)
       when is_binary(session_id) and is_binary(request_id) do
    case Repo.get_by(Dispatch, session_id: session_id, request_id: request_id) do
      nil ->
        nil

      dispatch ->
        if dispatch.brief_digest == digest(redact(request.brief)) and
             dispatch.model == request.model and
             dispatch.provider == request.provider and dispatch.purpose == request.purpose and
             dispatch.after_dispatch_id == cast_id(Map.get(request, :after_dispatch)) and
             (dispatch.lesson_codes || []) == lesson_codes(request),
           do: {:ok, dispatch},
           else: {:error, :request_id_conflict}
    end
  end

  defp existing(_request), do: {:error, :invalid_request_id}

  @worker_role %{"implement" => "implementer", "explore" => "explorer", "review" => "reviewer"}

  defp proposes_lessons?(request) do
    case Grants.active(request.session_id) do
      %Grant{} = grant ->
        Lessons.may_propose?(grant, @worker_role[request.purpose], Map.get(request, :agent))

      nil ->
        false
    end
  end

  @doc "The job of the agent that does a dispatch of `purpose`."
  def worker_role(purpose), do: Map.fetch!(@worker_role, purpose)

  defp lesson_codes(request),
    do:
      request
      |> Map.get(:lessons, [])
      |> Enum.map(&(&1 |> String.trim() |> String.upcase()))
      |> Enum.uniq()

  defp cast_id(nil), do: nil

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> id
      :error -> id
    end
  end

  # -- Validation --------------------------------------------------------

  defp prepare(request) do
    with :ok <- request_id(request.request_id),
         :ok <- purpose(request.purpose),
         {:ok, title} <- text(redact(request.title), :title, 200),
         {:ok, brief} <- brief(redact(request.brief)),
         :ok <- worker(request),
         {:ok, request} <- session_agent(request),
         :ok <- batch(request),
         {:ok, facts} <-
           Intake.repository(request.repository, uncommitted: uncommitted(request.purpose)),
         {:ok, lessons} <- Lessons.for_brief(facts.root, lesson_codes(request)) do
      # The worker gets the cited lessons with the coordinator's brief, and
      # how to propose one when its agent may; the dispatch keeps the
      # coordinator's own brief's digest for retries.
      proposes? = proposes_lessons?(request)
      request = Map.put(request, :lessons_allowed, proposes?)

      prepared = %{
        request: request,
        title: title,
        brief:
          brief <>
            Lessons.brief_block(lessons) <> Lessons.proposal_hint(proposes?, request.purpose),
        own_brief: brief,
        lesson_codes: Enum.map(lessons, & &1.code),
        root: facts.root,
        head: facts.head,
        left_out: facts.uncommitted
      }

      prepare(request.purpose, prepared, facts)
    end
  end

  # Every dispatch works on a private copy at `HEAD`, so uncommitted paths
  # are left out of it. An IMPLEMENT refuses changed tracked files, whose
  # committed version would differ from the checkout the person sees;
  # untracked files never reach a copy. EXPLORE and REVIEW only read, and
  # name what they left out.
  defp uncommitted("implement"), do: :untracked
  defp uncommitted(_purpose), do: :allow

  @doc """
  What a dispatch's requester is told about `root`'s uncommitted paths,
  which no dispatch's copy (the repository at `HEAD`) contains: at most 10,
  with the count of the rest; nil when there are none.
  """
  def left_out(root) do
    case Intake.repository(root, uncommitted: :allow) do
      {:ok, %{uncommitted: [_ | _] = paths}} ->
        %{
          "paths" => Enum.take(paths, 10),
          "more" => max(length(paths) - 10, 0),
          "note" =>
            "Not in the dispatch's copy, which is the repository at HEAD. Tell the person " <>
              "if any of these uncommitted paths matter to the task."
        }

      _ ->
        nil
    end
  end

  defp prepare("implement", %{request: request} = prepared, facts) do
    with :ok <- reviewer(request),
         {:ok, after_id} <- after_dispatch(request, prepared),
         {:ok, batch} <- batch_tasks(request, after_id, facts),
         {:ok, attempts} <- int(Map.get(request, :attempts, 1), :attempts, 1..20),
         {:ok, seconds} <- implement_seconds(request),
         {:ok, gates} <-
           Intake.gates(facts,
             gates: Map.get(request, :gates, []),
             tests: Map.get(request, :tests, [])
           ),
         {:ok, goal} <-
           Intake.goal_contract(prepared.title, facts, gates,
             constraints: Enum.map(Map.get(request, :stay_out, []), &"Do not change #{&1}.")
           ),
         {:ok, contract} <-
           PlanContract.new(plan(goal, prepared.title, request, gates, attempts, seconds, batch)) do
      {:ok,
       Map.merge(prepared, %{
         contract: contract,
         attempts: attempts,
         seconds: seconds,
         total_seconds: contract.content["budget"]["max_total_duration_seconds"],
         after: after_id,
         task_count: max(length(batch), 1)
       })}
    end
  end

  # EXPLORE and REVIEW are one model call each (`Shoestring.Dispatches.Calls`):
  # the dispatch records the call's contract instead of a plan.
  # Its time is what the coordinator asked for, else the grant's per-dispatch
  # limit: no fixed time of its own.
  defp prepare("explore", %{request: request} = prepared, _facts) do
    with :ok <- no_after(request),
         {:ok, seconds} <- call_seconds(request) do
      input =
        Calls.explore_input(
          Map.put(request, :seconds, seconds),
          prepared.title,
          prepared.brief,
          prepared.head
        )

      {:ok, call(prepared, input, seconds)}
    end
  end

  defp prepare("review", %{request: request} = prepared, _facts) do
    with :ok <- no_after(request),
         {:ok, seconds} <- call_seconds(request),
         {:ok, target} <- review_target(request, prepared),
         {:ok, input} <-
           Calls.review_input(
             Map.merge(request, %{brief: prepared.brief, seconds: seconds}),
             target
           ) do
      {:ok, call(prepared, input, seconds)}
    end
  end

  # An IMPLEMENT may follow another IMPLEMENT of its session and repository
  # (C1): it starts from that one's verified commit once it completes. One
  # already cancelled, or that never started, has no commit to follow.
  defp after_dispatch(%{after_dispatch: id} = request, prepared) when is_binary(id) do
    with %Dispatch{} = before <- get(id) || {:error, :after_not_found},
         true <- before.session_id == request.session_id || {:error, :after_not_found},
         true <- before.purpose == "implement" || {:error, :after_not_implement},
         true <- before.repository_root == prepared.root || {:error, :after_other_repository},
         state when state not in ~w(cancelled failed_to_start) <- state(before) do
      {:ok, before.id}
    else
      state when is_binary(state) -> {:error, {:after_unusable, state}}
      {:error, _} = error -> error
    end
  end

  defp after_dispatch(_request, _prepared), do: {:ok, nil}

  defp no_after(%{after_dispatch: id}) when is_binary(id), do: {:error, :after_implement_only}
  defp no_after(_request), do: :ok

  defp call_seconds(request) do
    default =
      case Grants.active(request.session_id) do
        %Grant{max_dispatch_seconds: seconds} -> seconds
        nil -> 1800
      end

    within_agent(request, default)
  end

  defp implement_seconds(request), do: within_agent(request, 1800)

  # The seconds asked for, else `default`; an agent with a limit of its own
  # bounds both. Asking for more than the agent's limit is refused: only the
  # person raises it.
  defp within_agent(request, default) do
    limit =
      case Map.get(request, :agent_entry) do
        %{"max_minutes" => minutes} when is_integer(minutes) -> minutes * 60
        _ -> nil
      end

    case {Map.get(request, :seconds), limit} do
      {nil, nil} -> {:ok, default}
      {nil, limit} -> {:ok, min(default, limit)}
      {seconds, nil} -> int(seconds, :seconds, 60..14_400)
      {seconds, limit} when is_integer(seconds) and seconds > limit -> over_limit(request)
      {seconds, _limit} -> int(seconds, :seconds, 60..14_400)
    end
  end

  defp over_limit(%{agent_entry: agent}),
    do: {:error, {:over_agent_limit, agent["slug"], agent["max_minutes"]}}

  # The session agent this dispatch is for: the one it names (`agent`), else
  # the one of its job on its model. Its limit then bounds the dispatch,
  # however it was named.
  defp session_agent(request) do
    team =
      case Grants.active(request.session_id) do
        %Grant{team: team} -> team
        nil -> nil
      end

    case Map.get(request, :agent) do
      nil ->
        entry = Agents.for_dispatch(team, request.purpose, request.provider, request.model)
        {:ok, Map.merge(request, %{agent: entry && entry["slug"], agent_entry: entry})}

      name ->
        case Agents.find(team, name) do
          nil ->
            {:error, {:unknown_agent, name}}

          %{"kind" => kind} = entry ->
            if kind == Agents.purpose_kind(request.purpose),
              do: {:ok, Map.merge(request, %{agent: entry["slug"], agent_entry: entry})},
              else: {:error, {:agent_purpose, entry["slug"], kind, request.purpose}}
        end
    end
  end

  defp call(prepared, input, seconds) do
    Map.merge(prepared, %{
      contract: %{content: Calls.contract(input), digest: PlanContract.digest(input)},
      attempts: 1,
      seconds: seconds
    })
  end

  # A REVIEW reviews a completed IMPLEMENT dispatch of the same session and
  # repository, with a model of another vendor than the one that wrote it.
  defp review_target(request, prepared) do
    with id when is_binary(id) <-
           Map.get(request, :target) || {:error, {:invalid_dispatch, :target}},
         %Dispatch{} = target <- get(id) || {:error, :review_target_not_found},
         true <- target.session_id == request.session_id || {:error, :review_target_not_found},
         true <- target.purpose == "implement" || {:error, :review_target_not_implement},
         :ok <- review_vendor(request, target),
         "completed" <- state(target),
         true <-
           target.repository_root == prepared.root || {:error, :review_target_other_repository},
         true do
      {:ok, target}
    else
      state when is_binary(state) -> {:error, {:review_target_not_completed, state}}
      {:error, _} = error -> error
    end
  end

  defp review_vendor(request, target) do
    reviewer = Harnesses.vendor(request.provider, request.model)

    if reviewer == nil or reviewer == Harnesses.vendor(target.provider, target.model),
      do: {:error, {:reviewer_same_vendor, "#{request.provider}:#{request.model}"}},
      else: :ok
  end

  defp request_id(id) when is_binary(id),
    do: if(Regex.match?(@request_id, id), do: :ok, else: {:error, :invalid_request_id})

  defp request_id(_id), do: {:error, :invalid_request_id}

  defp purpose(purpose) when purpose in @available, do: :ok

  defp purpose(purpose) do
    if purpose in Grants.purposes(),
      do: {:error, {:purpose_not_available, purpose}},
      else: {:error, {:invalid_dispatch, :purpose}}
  end

  defp text(value, field, max) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" or not String.valid?(value) -> {:error, {:invalid_dispatch, field}}
      String.length(value) > max -> {:error, {:invalid_dispatch, field}}
      String.contains?(value, ["\n", "\r"]) -> {:error, {:invalid_dispatch, field}}
      true -> {:ok, value}
    end
  end

  defp text(_value, field, _max), do: {:error, {:invalid_dispatch, field}}

  defp brief(value) when is_binary(value) do
    cond do
      not String.valid?(value) or String.trim(value) == "" ->
        {:error, {:invalid_dispatch, :brief}}

      String.length(value) > @max_brief ->
        {:error, {:brief_too_large, @max_brief}}

      true ->
        {:ok, value}
    end
  end

  defp brief(_value), do: {:error, {:invalid_dispatch, :brief}}

  # The worker must be an enabled model the harness still offers, on a
  # harness that can do the purpose, with an effort the model accepts.
  defp worker(%{provider: provider, model: model} = request) do
    effort = Map.get(request, :effort)

    cond do
      provider not in Harnesses.ids() ->
        {:error, {:invalid_dispatch, :worker}}

      not Harnesses.supports?(provider, @capability[request.purpose]) ->
        {:error, {:harness_cannot, provider, @capability[request.purpose]}}

      model not in ModelCatalog.enabled(provider) ->
        {:error, {:model_not_enabled, "#{provider}:#{model}"}}

      match?(%{available: false}, ModelCatalog.entry(provider, model)) ->
        {:error, {:model_unavailable, "#{provider}:#{model}"}}

      effort && effort not in AgentProfiles.efforts(provider, model) ->
        {:error, {:effort_not_offered, effort}}

      true ->
        :ok
    end
  end

  # A reviewer must be an enabled model on a harness that can review, from
  # another vendor than the worker (decision 4).
  defp reviewer(request) do
    case {Map.get(request, :reviewer_provider), Map.get(request, :reviewer_model)} do
      {nil, nil} ->
        :ok

      {provider, model} when is_binary(provider) and is_binary(model) ->
        cond do
          not Harnesses.supports?(provider, :review) ->
            {:error, {:harness_cannot, provider, :review}}

          model not in ModelCatalog.enabled(provider) ->
            {:error, {:model_not_enabled, "#{provider}:#{model}"}}

          Harnesses.vendor(provider, model) == nil or
              Harnesses.vendor(provider, model) ==
                Harnesses.vendor(request.provider, request.model) ->
            {:error, {:reviewer_same_vendor, "#{provider}:#{model}"}}

          true ->
            :ok
        end

      _ ->
        {:error, {:invalid_dispatch, :reviewer}}
    end
  end

  defp int(value, field, range) do
    if is_integer(value) and value in range,
      do: {:ok, value},
      else: {:error, {:invalid_dispatch, field}}
  end

  defp batch(request) do
    case {Map.get(request, :batch_label), Map.get(request, :batch_size)} do
      {nil, nil} ->
        :ok

      {label, size} when is_binary(label) and is_integer(size) and size in 1..32 ->
        batch_label(label)

      _ ->
        {:error, {:invalid_dispatch, :batch}}
    end
  end

  defp batch_label(label),
    do:
      if(Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,62}\z/, label),
        do: :ok,
        else: {:error, {:invalid_dispatch, :batch}}
      )

  defp plan(goal, title, request, gates, attempts, seconds, batch) do
    accept =
      case Map.get(request, :accept, []) do
        [] -> ["The task's checks pass at its final commit."]
        accept -> accept
      end

    task = fn id, title, outcome, files, input ->
      %{
        "id" => id,
        "title" => title,
        "outcome" => outcome,
        "depends_on" => [],
        "inputs" => [input],
        "expected_artifacts" => [],
        "hints" => %{"files" => files, "symbols" => []},
        "acceptance_criteria" => accept,
        "gates" => gates,
        "checkpoint" => %{
          "condition" => "The task's checks have run and their results are recorded.",
          "evidence" => ["The checks' results at the task's final commit."]
        },
        "risks" => [],
        "execution" => %{"max_attempts" => attempts, "max_duration_seconds" => seconds}
      }
    end

    tasks =
      case batch do
        [] ->
          [
            task.(
              @task_id,
              title,
              title,
              Map.get(request, :files, []),
              "The coordinator's brief, given with this task."
            )
          ]

        batch ->
          for {item, n} <- Enum.with_index(batch, 1) do
            task.(
              "#{@task_id}-#{n}",
              item.title,
              item.brief,
              item.files,
              "The coordinator's brief, given with every task of this batch; change only " <>
                "this task's files."
            )
          end
      end

    n = length(tasks)

    %{
      "version" => 1,
      "goal" => goal,
      "budget" => %{
        "max_total_attempts" => attempts * n,
        "max_total_duration_seconds" => batch_seconds(n, attempts, seconds, goal)
      },
      "tasks" => tasks
    }
  end

  # A batch's time: its tasks' own, plus the verification a fan-out reserves
  # for them at worst (every goal check at its command timeout, and a bounded
  # final-scope check per task; `PlanFanout`). A single task needs neither.
  # Only the time actually taken counts against the grant afterwards.
  defp batch_seconds(1, _attempts, seconds, _goal), do: seconds

  defp batch_seconds(n, attempts, seconds, goal) do
    timeout =
      :shoestring
      |> Application.get_env(:plan_execution_opts, [])
      |> Keyword.get(:gate_runner_opts, [])
      |> Keyword.get(:timeout_ms, 120_000)

    verification_ms =
      length(get_in(goal, ["acceptance", "gates"]) || []) * timeout +
        n * Shoestring.Cobbler.ScopeEvidence.final_scope_bound_ms(n * attempts)

    seconds * n + div(verification_ms + 999, 1000)
  end

  # A batch IMPLEMENT (C2): two or more tasks, each declaring the files or
  # directories it changes. They may run at once only when those scopes are
  # separate and touch nothing shared (lockfiles, configuration, migrations,
  # symlinks: `PlanIndependence`), so a batch that could not is refused here,
  # before anything is recorded. Whether they do run at once is the person's
  # setting (`Parallelism`).
  defp batch_tasks(%{tasks: [_ | _] = tasks}, _after_id, facts) do
    max = Parallelism.max()

    cond do
      length(tasks) < 2 ->
        {:error, {:invalid_dispatch, :tasks}}

      length(tasks) > max ->
        {:error, {:batch_too_large, max}}

      true ->
        with {:ok, items} <- batch_items(tasks),
             :ok <- batch_scopes(items, facts),
             do: {:ok, items}
    end
  end

  defp batch_tasks(_request, _after_id, _facts), do: {:ok, []}

  defp batch_items(tasks) do
    Enum.reduce_while(Enum.with_index(tasks, 1), {:ok, []}, fn {task, n}, {:ok, acc} ->
      with %{} <- task,
           {:ok, title} <- text(redact(field(task, :title)), :task_title, 200),
           {:ok, brief} <- optional_task_text(field(task, :brief), title),
           files when is_list(files) and files != [] and length(files) <= 32 <-
             field(task, :files),
           true <- Enum.all?(files, &PlanIndependence.valid_path?/1) do
        {:cont, {:ok, acc ++ [%{title: title, brief: brief, files: files}]}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, {:batch_task_files, n}}}
      end
    end)
  end

  defp field(task, key), do: Map.get(task, key, Map.get(task, Atom.to_string(key)))

  defp optional_task_text(nil, title), do: {:ok, title}
  defp optional_task_text("", title), do: {:ok, title}
  defp optional_task_text(text, _title), do: text(redact(text), :task_brief, 1000)

  defp batch_scopes(items, facts) do
    tasks =
      for {item, n} <- Enum.with_index(items, 1),
          do: %{"id" => "#{@task_id}-#{n}", "hints" => %{"files" => item.files}}

    case PlanIndependence.declared(tasks, tree(facts)) do
      %{"disposition" => "eligible"} -> :ok
      %{"blockers" => blockers} -> {:error, {:batch_scopes, blockers}}
    end
  end

  # The repository's committed files and symlinks at HEAD, read-only.
  defp tree(facts) do
    case System.cmd(
           "git",
           ["-C", facts.root, "ls-tree", "-r", "-z", "--full-tree", facts.head],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        entries =
          for entry <- String.split(output, <<0>>, trim: true),
              [meta, path] <- [String.split(entry, "\t", parts: 2)],
              do: {hd(String.split(meta, " ")), path}

        %{
          verified?: true,
          files: Enum.map(entries, &elem(&1, 1)),
          symlinks: for({"120000", path} <- entries, do: path)
        }

      _ ->
        %{verified?: false}
    end
  end

  # -- Recording and starting --------------------------------------------

  defp reserve(prepared, opts) do
    request = prepared.request
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    Repo.transaction(
      fn ->
        with %Grant{} = grant <- Grants.active(request.session_id) || {:error, :no_grant},
             :ok <- Grants.check(grant, check_request(prepared), usage(grant)),
             :ok <- batch_room(grant, request) do
          dispatch =
            Repo.insert!(%Dispatch{
              grant_id: grant.id,
              session_id: request.session_id,
              request_id: request.request_id,
              purpose: request.purpose,
              provider: request.provider,
              model: request.model,
              effort: Map.get(request, :effort),
              reviewer_provider: Map.get(request, :reviewer_provider),
              reviewer_model: Map.get(request, :reviewer_model),
              title: prepared.title,
              brief: prepared.brief,
              brief_digest: digest(prepared.own_brief),
              lesson_codes: prepared.lesson_codes,
              repository_root: prepared.root,
              base_revision: prepared.head,
              max_attempts: prepared.attempts * Map.get(prepared, :task_count, 1),
              max_duration_seconds: Map.get(prepared, :total_seconds, prepared.seconds),
              task_count: Map.get(prepared, :task_count, 1),
              agent: Map.get(request, :agent),
              permissions:
                if(request.purpose == "implement",
                  do: get_in(request, [:agent_entry, "permissions"])
                ),
              batch_label: Map.get(request, :batch_label),
              batch_size: Map.get(request, :batch_size),
              goal_id: if(request.purpose == "implement", do: Ecto.UUID.generate()),
              plan: prepared.contract.content,
              plan_digest: prepared.contract.digest,
              after_dispatch_id: prepared[:after],
              state: if(prepared[:after], do: "chained", else: "creating"),
              inserted_at: now,
              updated_at: now
            })

          :ok = Lessons.cite(prepared.lesson_codes, now)

          # A dispatch that follows another has its job recorded with it, so
          # it is followed after a restart as well.
          if dispatch.state == "chained" do
            case Oban.insert(
                   Keyword.get(opts, :oban, Oban),
                   ChainWorker.new(%{"dispatch_id" => dispatch.id})
                 ) do
              {:ok, _job} -> dispatch
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            dispatch
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, %Dispatch{state: "chained"} = dispatch} ->
        case follow(dispatch, opts) do
          {:ok, _dispatch, _outcome} = started -> started
          {:error, _} = error -> error
          _waiting_or_called_off -> {:ok, Repo.get!(Dispatch, dispatch.id), :recorded}
        end

      {:ok, dispatch} ->
        start(dispatch, opts, :recorded)

      error ->
        error
    end
  end

  @doc """
  One step of a dispatch that follows another (C1), as its job
  (`Shoestring.Dispatches.ChainWorker`) and its creation take it. Once the
  dispatch it follows has completed, it starts from that one's verified
  commit, copied from Shoestring's own worktree, never the person's
  checkout: `{:ok, dispatch, :recorded}` or `{:error, reason}`. While that
  one is unfinished, or the grant's parallel room is taken, `:waiting`. It
  is called off, its reservation released, when the dispatch it follows
  was cancelled or never started, or its grant is revoked:
  `{:called_off, code}`. Anything else: `:none`. Options: `:oban`.
  """
  def follow(dispatch, opts \\ [])

  def follow(%Dispatch{state: "chained"} = dispatch, opts) do
    before = get(dispatch.after_dispatch_id)

    case Grants.get(dispatch.grant_id) do
      %Grant{revoked_at: nil} = grant ->
        case before && state(before) do
          nil ->
            call_off(dispatch, "after_not_found")

          "completed" ->
            if usage(grant).running + (dispatch.task_count || 1) > grant.max_parallel,
              do: :waiting,
              else: start_after(dispatch, before, opts)

          state when state in ~w(cancelled failed_to_start) ->
            call_off(dispatch, "after_" <> state)

          _unfinished ->
            :waiting
        end

      _revoked ->
        call_off(dispatch, "grant_revoked")
    end
  end

  def follow(_dispatch, _opts), do: :none

  # The plan granted with the dispatch, based on the commit it follows. A
  # compare-and-set from `chained`, so two steps never both start it.
  defp start_after(dispatch, before, opts) do
    case Result.fetch(before.goal_id) do
      {:ok, %{commit: commit}} ->
        with {:ok, contract} <-
               PlanContract.new(
                 put_in(dispatch.plan, ["goal", "repository", "base_revision"], commit)
               ) do
          {count, _} =
            from(d in Dispatch, where: d.id == ^dispatch.id and d.state == "chained")
            |> Repo.update_all(
              set: [
                state: "creating",
                plan: contract.content,
                plan_digest: contract.digest,
                base_revision: commit,
                updated_at: DateTime.utc_now()
              ]
            )

          if count == 1, do: start(Repo.get!(Dispatch, dispatch.id), opts, :recorded), else: :none
        end

      {:error, :not_completed} ->
        :waiting

      {:error, _} ->
        call_off(dispatch, "after_result_unavailable")
    end
  end

  defp call_off(dispatch, code) do
    {count, _} =
      from(d in Dispatch, where: d.id == ^dispatch.id and d.state == "chained")
      |> Repo.update_all(set: [state: "cancelled", error: code, updated_at: DateTime.utc_now()])

    if count == 1, do: {:called_off, code}, else: :none
  end

  # Where a dispatch that follows another gets its base commit: the worktree
  # holding the verified commit it follows. Nil for every other dispatch.
  defp base_source(%Dispatch{after_dispatch_id: nil}), do: {:ok, nil}

  defp base_source(dispatch) do
    with %Dispatch{} = before <- get(dispatch.after_dispatch_id) || {:error, :after_not_found},
         {:ok, %{commit: commit, worktree: worktree}} <- Result.fetch(before.goal_id),
         true <- commit == dispatch.base_revision || {:error, :after_commit_changed} do
      {:ok, worktree}
    end
  end

  # A call's input is rebuilt from the recorded dispatch and must match the
  # digest recorded with it, so a dispatch interrupted part-way resumes with
  # exactly what was granted.
  defp start(%Dispatch{purpose: purpose} = dispatch, opts, outcome) when purpose in @calls do
    request = %{
      provider: dispatch.provider,
      model: dispatch.model,
      effort: dispatch.effort,
      brief: dispatch.brief,
      seconds: dispatch.max_duration_seconds,
      version: dispatch.plan["version"],
      lessons_allowed: dispatch.plan["lessons"] == true
    }

    input =
      case purpose do
        "explore" ->
          {:ok,
           Calls.explore_input(request, dispatch.title, dispatch.brief, dispatch.base_revision)}

        "review" ->
          case get(dispatch.plan["target_dispatch_id"]) do
            %Dispatch{} = target -> Calls.review_input(request, target)
            nil -> {:error, :review_target_not_found}
          end
      end

    with {:ok, input} <- input,
         true <-
           PlanContract.digest(input) == dispatch.plan_digest || {:error, :call_input_changed},
         :ok <- Calls.start(dispatch, input, Keyword.take(opts, [:oban])) do
      dispatch = dispatch |> Ecto.Changeset.change(state: "started") |> Repo.update!()
      {:ok, dispatch, outcome}
    else
      {:error, reason} ->
        dispatch
        |> Ecto.Changeset.change(state: "failed", error: error_code(reason))
        |> Repo.update!()

        {:error, reason}
    end
  end

  defp start(dispatch, opts, outcome) do
    identity = Authority.grant_identity(dispatch.grant_id)
    authority = [dispatch: dispatch]

    with {:ok, contract} <- PlanContract.new(dispatch.plan),
         {:ok, base_source} <- base_source(dispatch),
         :ok <- ensure_goal(dispatch),
         {:ok, %{revision: revision}} <-
           Plans.propose(
             dispatch.goal_id,
             %{proposal_id: "dispatch", plan: contract.content, authored_by: identity},
             authority
           ),
         {:ok, _} <-
           Plans.approve(
             dispatch.goal_id,
             %{
               decision_id: "dispatch",
               revision_number: revision.revision_number,
               digest: revision.digest,
               decided_by: identity
             },
             authority
           ),
         {:ok, %{execution: execution}} <-
           ExecutionControl.start(
             dispatch.goal_id,
             %{
               revision_number: revision.revision_number,
               digest: revision.digest,
               repository_path: dispatch.repository_root,
               requested_by: identity,
               agent_profile: %{"dispatch_id" => dispatch.id, "role" => "Worker"},
               base_source: base_source
             },
             Keyword.take(opts, [:oban]) ++ authority
           ) do
      dispatch =
        dispatch
        |> Ecto.Changeset.change(state: "started", execution_id: execution.execution_id)
        |> Repo.update!()

      {:ok, dispatch, outcome}
    else
      {:error, reason} ->
        dispatch
        |> Ecto.Changeset.change(state: "failed", error: error_code(reason))
        |> Repo.update!()

        {:error, reason}
    end
  end

  defp ensure_goal(dispatch) do
    if Repo.get(Goal, dispatch.goal_id) do
      :ok
    else
      %Goal{id: dispatch.goal_id}
      |> Goal.create_changeset(Ecto.UUID.generate(), %{
        title: dispatch.title,
        description: "Dispatched by coordinator session #{dispatch.session_id}."
      })
      |> Repo.insert()
      |> case do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :goal_not_created}
      end
    end
  end

  # -- Grant accounting ---------------------------------------------------

  defp check_request(prepared) do
    %{
      repository_root: prepared.root,
      provider: prepared.request.provider,
      model: prepared.request.model,
      purpose: prepared.request.purpose,
      reviewer:
        case Map.get(prepared.request, :reviewer_provider) do
          nil -> nil
          provider -> "#{provider}:#{prepared.request.reviewer_model}"
        end,
      attempts: prepared.attempts * Map.get(prepared, :task_count, 1),
      seconds: prepared.seconds,
      total_seconds: Map.get(prepared, :total_seconds, prepared.seconds),
      width: Map.get(prepared, :task_count, 1),
      chained: prepared[:after] != nil
    }
  end

  @doc """
  What `grant`'s dispatches use: attempts (every dispatch not failed to
  start), seconds and how many are starting, queued, running, waiting or
  held. A finished dispatch counts the seconds it took (at most what it
  reserved); one not finished counts every second it may still take.
  """
  def usage(%Grant{} = grant) do
    dispatches =
      Repo.all(
        from d in Dispatch,
          where: d.grant_id == ^grant.id and d.state not in ["failed", "cancelled"]
      )
      |> Enum.map(&{&1, state(&1)})

    %{
      attempts: Enum.sum_by(dispatches, fn {dispatch, _} -> dispatch.max_attempts end),
      seconds: Enum.sum_by(dispatches, fn {dispatch, state} -> used_seconds(dispatch, state) end),
      # A batch takes one parallel place per task.
      running:
        Enum.sum_by(dispatches, fn {dispatch, state} ->
          if state in ~w(starting queued running waiting held),
            do: dispatch.task_count || 1,
            else: 0
        end)
    }
  end

  defp used_seconds(dispatch, state) when state in ~w(completed cancelled failed) do
    case took(dispatch) do
      seconds when is_integer(seconds) -> min(seconds, dispatch.max_duration_seconds)
      nil -> dispatch.max_duration_seconds
    end
  end

  defp used_seconds(dispatch, _state), do: dispatch.max_duration_seconds

  @doc "Seconds a finished dispatch took, rounded up; nil when not known."
  def took(%Dispatch{purpose: purpose} = dispatch) when purpose in @calls do
    case Calls.get(dispatch.id) do
      %Call{started_at: nil} ->
        0

      %Call{started_at: started, finished_at: %DateTime{} = finished} ->
        seconds(started, finished)

      _ ->
        nil
    end
  end

  def took(%Dispatch{goal_id: goal_id}) when is_binary(goal_id) do
    case ExecutionControl.status(goal_id) do
      {:ok, %{total_duration_ms: ms}} when is_integer(ms) and ms >= 0 -> div(ms + 999, 1000)
      _ -> nil
    end
  end

  def took(_dispatch), do: nil

  defp seconds(from, to), do: div(max(DateTime.diff(to, from, :millisecond), 0) + 999, 1000)

  @doc "A grant's limits next to what its dispatches use."
  def room(%Grant{} = grant, usage \\ nil) do
    usage = usage || usage(grant)

    %{
      "grant_id" => grant.id,
      "session_id" => grant.session_id,
      "attempts" => %{"used" => usage.attempts, "limit" => grant.max_dispatches},
      "seconds" => %{"used" => usage.seconds, "limit" => grant.max_total_seconds},
      "running" => %{"now" => usage.running, "limit" => grant.max_parallel},
      "unread_usage" => %{"used" => grant.unread_usage_used, "limit" => grant.unread_usage},
      "revoked" => not is_nil(grant.revoked_at)
    }
  end

  defp batch_room(_grant, %{batch_label: nil}), do: :ok

  defp batch_room(grant, %{batch_label: label, batch_size: size}) when is_binary(label) do
    declared =
      Repo.all(
        from d in Dispatch,
          where: d.grant_id == ^grant.id and d.batch_label == ^label and d.state != "failed"
      )

    cond do
      Enum.any?(declared, &(&1.batch_size != size)) -> {:error, {:batch_size_changed, label}}
      length(declared) >= size -> {:error, {:batch_full, label}}
      true -> :ok
    end
  end

  defp batch_room(_grant, _request), do: :ok

  defp check_result(:ok), do: "ok"
  defp check_result({:error, {:outside_grant, limit}}), do: "outside_grant:#{limit}"

  # -- Status and binding ---------------------------------------------------

  @doc """
  The dispatch's state, derived from its execution: `starting`, `queued`,
  `running`, `waiting` (deferred until its provider's usage resets; it
  starts by itself then), `held` (its provider's remaining usage could not
  be confirmed; a person confirms it), `needs_you` (waits for a person),
  `chained` (follows another dispatch and starts once that one completes),
  `completed`, `cancelled` or `failed_to_start`.
  """
  def state(dispatch, status \\ &ExecutionControl.status/1)
  def state(%Dispatch{state: "creating"}, _status), do: "starting"
  def state(%Dispatch{state: "failed"}, _status), do: "failed_to_start"
  def state(%Dispatch{state: "chained"}, _status), do: "chained"
  def state(%Dispatch{state: "cancelled"}, _status), do: "cancelled"

  def state(%Dispatch{state: "started", purpose: purpose} = dispatch, _status)
      when purpose in @calls do
    case Calls.get(dispatch.id) do
      %Call{} = call -> Calls.state(call)
      nil -> "starting"
    end
  end

  def state(%Dispatch{state: "started"} = dispatch, status) do
    case status.(dispatch.goal_id) do
      {:ok, %{cancelled?: true}} ->
        "cancelled"

      {:ok, %{completed?: true}} ->
        "completed"

      {:ok, %{needs_user?: true}} ->
        "needs_you"

      # A batch whose tasks are all accepted is merged by Shoestring (C3,
      # `Shoestring.Cobbler.PlanMerge`); it waits for the person only when
      # that merge stopped on a conflict or failure.
      {:ok, %{dispatch_mode: :fanout_v1, active_run_ids: [], integration: nil} = current}
      when current.accepted_count == current.total_tasks and current.total_tasks > 0 ->
        if Shoestring.Cobbler.PlanMerge.blocked(dispatch.goal_id, current),
          do: "needs_you",
          else: "running"

      {:ok, %{active_run_id: run_id} = current} when is_binary(run_id) ->
        # The execution retains its task's run while its completed change is
        # reviewed. A terminal worker is no longer doing useful work: show
        # the review's hold/wait instead of hiding it behind "running".
        case Repo.get(RunRecord, run_id) do
          %RunRecord{status: status} when status in ~w(completed failed cancelled interrupted) ->
            execution_state(current)

          _ ->
            "running"
        end

      {:ok, status} when is_map(status) ->
        execution_state(status)

      _ ->
        "queued"
    end
  end

  defp execution_state(%{
         last_admission: %{"result" => "require_confirmation"},
         hold_confirmed?: true
       }),
       do: "queued"

  defp execution_state(%{last_admission: %{"result" => "require_confirmation"}}), do: "held"

  defp execution_state(status),
    do: if(waiting_until(status), do: "waiting", else: queued_or_held(status))

  defp queued_or_held(%{reviews: [_ | _] = reviews}),
    do:
      if(Enum.any?(reviews, &(&1.state == "held" and not Map.get(&1, :confirmed?, false))),
        do: "held",
        else: "queued"
      )

  defp queued_or_held(_status), do: "queued"

  @doc "A dispatch's state and stable identity of the decision or review it waits on."
  def inbox_state(%Dispatch{state: state} = dispatch) when state != "started",
    do: {state(dispatch), "0:#{state}"}

  def inbox_state(%Dispatch{purpose: purpose} = dispatch) when purpose in @calls do
    case Calls.get(dispatch.id) do
      %Call{} = call ->
        identity = %{"call" => call.id, "admission" => call.admission}
        {Calls.state(call), settlement_ref(identity, call.updated_at)}

      nil ->
        {state(dispatch), "starting"}
    end
  end

  def inbox_state(%Dispatch{} = dispatch) do
    current = ExecutionControl.status(dispatch.goal_id)
    settled = state(dispatch, fn _ -> current end)

    identity =
      case current do
        {:ok, status} ->
          %{
            "decision" => get_in(status, [:last_admission, "decision_id"]),
            "reviews" =>
              Enum.map(status[:reviews] || [], fn review ->
                Map.take(review, [:review_id, :calls, :state])
                |> Map.new(fn {key, value} -> {to_string(key), value} end)
              end)
          }

        _ ->
          %{}
      end

    admission_at =
      Repo.one(
        from e in Shoestring.Trajectory.TrajectoryEvent,
          where: e.goal_id == ^dispatch.goal_id and e.type == "admission.decided",
          order_by: [desc: e.sequence],
          limit: 1,
          select: e.occurred_at
      )

    review_at =
      Repo.aggregate(
        from(r in Shoestring.Cobbler.Review.Record,
          where: r.goal_id == ^dispatch.goal_id
        ),
        :max,
        :updated_at
      )

    changed_at =
      [admission_at, review_at]
      |> Enum.reject(&is_nil/1)
      |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)

    {settled, settlement_ref(identity, changed_at)}
  end

  # The time lets an old inbox entry (which has no reference) identify an
  # already-observed cause without inventing a new notification on upgrade.
  defp settlement_ref(identity, changed_at) do
    since = if changed_at, do: DateTime.to_unix(changed_at, :microsecond), else: 0
    "#{since}:#{digest(PlanContract.canonical_json(identity))}"
  end

  @doc """
  When an execution `status` (`ExecutionControl.status/1`) waits for its
  provider's usage to reset: `{until, reason_code}` from its latest admission
  decision while that time is ahead, otherwise nil.
  """
  def waiting_until(status, now \\ DateTime.utc_now()) do
    with %{"result" => "defer_until", "defer_until" => text} = admission <-
           status[:last_admission],
         {:ok, until, _} <- DateTime.from_iso8601(text),
         :gt <- DateTime.compare(until, now) do
      {until, admission["reason_code"]}
    else
      _ -> nil
    end
  end

  @doc """
  Spends one of the grant's pre-approved unread-usage dispatches on a
  dispatch held because its provider's remaining usage could not be read
  (`:require_confirmation`, never a reserve breach), or on a review call held
  the same way. Returns `:confirmed`, `:none` (nothing held, the grant is
  revoked or has none left — the hold then waits for a person) or
  `{:error, reason}`, with the spent dispatch refunded. Each hold is spent
  at most once and its confirmation id is derived from it, so a retry
  repeats the same confirmation.
  """
  def advance(dispatch, status \\ &ExecutionControl.status/1)

  def advance(%Dispatch{state: "started", purpose: purpose} = dispatch, _status)
      when purpose in @calls do
    with %Call{state: "held", confirmed_by: nil} = call <- Calls.get(dispatch.id),
         %Grant{revoked_at: nil} = grant <- Grants.get(dispatch.grant_id) do
      spend(dispatch, grant, %{
        kind: :call,
        key: "call:#{call.id}:#{call.admission["decision_id"]}",
        call: call
      })
    else
      _ -> :none
    end
  end

  def advance(%Dispatch{state: "started"} = dispatch, status) do
    with {:ok, current} <- status.(dispatch.goal_id),
         {:ok, hold} <- hold(current, dispatch.goal_id),
         %Grant{revoked_at: nil} = grant <- Grants.get(dispatch.grant_id) do
      spend(dispatch, grant, hold)
    else
      _ -> :none
    end
  end

  def advance(%Dispatch{}, _status), do: :none

  @doc """
  A person confirms `dispatch`'s hold themselves (the chat screen's attention
  popup): the same confirmation a grant's pre-approval makes, recorded under
  `by` and spending none of the grant's. `:confirmed`, `:none` (nothing held)
  or `{:error, reason}`.
  """
  def confirm_hold(dispatch, by, status \\ &ExecutionControl.status/1)

  def confirm_hold(%Dispatch{state: "started", purpose: purpose} = dispatch, by, _status)
      when purpose in @calls do
    with true <- Authority.human?(by) || {:error, :non_human_identity},
         %Call{state: "held", confirmed_by: nil} = call <- Calls.get(dispatch.id) do
      confirmed(confirm(dispatch, %{kind: :call, call: call}, by))
    else
      {:error, _} = error -> error
      _ -> :none
    end
  end

  def confirm_hold(%Dispatch{state: "started"} = dispatch, by, status) do
    with true <- Authority.human?(by) || {:error, :non_human_identity},
         {:ok, current} <- status.(dispatch.goal_id),
         {:ok, hold} <- hold(current, dispatch.goal_id) do
      confirmed(confirm(dispatch, hold, by))
    else
      {:error, :non_human_identity} = error -> error
      _ -> :none
    end
  end

  def confirm_hold(%Dispatch{}, _by, _status), do: :none

  # A grant's confirmation keeps the id it always had, so a retry repeats
  # it; a person's is its own.
  defp confirmation_id(dispatch, hold, by) do
    if by == Authority.grant_identity(dispatch.grant_id),
      do: uuid_for(hold.key),
      else: uuid_for("#{hold.key}:#{by}")
  end

  defp confirmed({:ok, _}), do: :confirmed
  defp confirmed({:error, _} = error), do: error

  defp hold(%{completed?: false, needs_user?: false, cancelled?: false} = status, goal_id) do
    review = Enum.find(status[:reviews] || [], &(&1.state == "held"))
    decision = status[:last_admission]

    cond do
      review ->
        {:ok,
         %{
           kind: :review,
           key: "review:#{review.review_id}:#{review.calls}",
           review_id: review.review_id
         }}

      # A batch (C2): the first held task without a confirmation yet; each
      # task's hold is its own and spends its own pre-approval.
      match?(%{"result" => "require_confirmation"}, decision) and
          length(status.execution.ordered_task_ids) > 1 ->
        batch_hold(status, decision, goal_id)

      match?(%{"result" => "require_confirmation"}, decision) and is_nil(status[:active_run_id]) ->
        {:ok,
         %{
           kind: :task,
           key: "task:#{decision["decision_id"]}",
           task_id: @task_id,
           execution_id: status.execution.execution_id,
           attempt: Map.get(status.attempts, @task_id, 0) + 1
         }}

      true ->
        :none
    end
  end

  defp hold(_status, _goal_id), do: :none

  defp batch_hold(status, decision, goal_id) do
    scope = Application.get_env(:shoestring, :run_submission_scope, "subscription")
    accepted = MapSet.new(status.accepted)
    active = MapSet.new(status.active_children, & &1.plan_task_id)

    # Only while the batch has a free place: a confirmation an admission
    # consumes for a task that then cannot start would be spent for nothing.
    room? = MapSet.size(active) < Parallelism.tasks()

    status.execution.ordered_task_ids
    |> Enum.reject(&(not room? or MapSet.member?(accepted, &1) or MapSet.member?(active, &1)))
    |> Enum.find_value(:none, fn task_id ->
      attempt = Map.get(status.attempts, task_id, 0) + 1

      if Shoestring.Cobbler.PlanCapacityConfirmation.available(
           goal_id,
           status.execution,
           %{"id" => task_id},
           attempt,
           scope
         ),
         do: nil,
         else:
           {:ok,
            %{
              kind: :task,
              key: "task:#{decision["decision_id"]}:#{task_id}",
              task_id: task_id,
              execution_id: status.execution.execution_id,
              attempt: attempt
            }}
    end)
  end

  defp spend(dispatch, grant, hold) do
    detail = %{"hold" => hold.key, "dispatch_id" => dispatch.id}

    spent =
      cond do
        Grants.spent?(grant.id, hold.key) -> :earlier
        match?({:ok, _}, Grants.use_unread(grant, detail)) -> :now
        true -> :exhausted
      end

    if spent == :exhausted do
      :none
    else
      case confirm(dispatch, hold, Authority.grant_identity(dispatch.grant_id)) do
        {:ok, _} ->
          :confirmed

        {:error, reason} ->
          if spent == :now, do: Grants.refund_unread(grant, detail)
          {:error, reason}
      end
    end
  end

  defp confirm(dispatch, %{kind: :task} = hold, by) do
    ExecutionControl.confirm_capacity(
      dispatch.goal_id,
      %{
        execution_id: hold.execution_id,
        task_id: hold.task_id,
        attempt: hold.attempt,
        scope: Application.get_env(:shoestring, :run_submission_scope, "subscription"),
        command_id: confirmation_id(dispatch, hold, by),
        requested_by: by
      },
      dispatch: dispatch
    )
  end

  defp confirm(_dispatch, %{kind: :call, call: call}, by), do: Calls.confirm(call, by)

  defp confirm(dispatch, %{kind: :review} = hold, by) do
    Shoestring.Cobbler.PlanReview.confirm(
      dispatch.goal_id,
      %{
        review_id: hold.review_id,
        confirmation_id: confirmation_id(dispatch, hold, by),
        confirmed_by: by
      },
      dispatch: dispatch
    )
  end

  # A version-4-shaped UUID derived from the hold, so a repeated confirmation
  # carries the same id and replays instead of recording a second one.
  @doc false
  def uuid_for(key) do
    <<head::bitstring-size(48), _::4, mid::bitstring-size(12), _::2, tail::bitstring-size(62),
      _::bitstring>> =
      :crypto.hash(:sha256, "shoestring-dispatch-hold:" <> key)

    Ecto.UUID.load!(<<head::bitstring, 4::4, mid::bitstring, 2::2, tail::bitstring>>)
  end

  @doc "Whether `state` ends what a coordinator waits for."
  def settled?(state), do: state in ~w(completed cancelled needs_you held failed failed_to_start)

  @doc """
  The execution binding a dispatch fixes for `role` (only the `Worker`): the
  harness, adapter, model, effort and the coordinator's brief.
  """
  def binding(dispatch_id, "Worker", repo) do
    with {:ok, id} <- Ecto.UUID.cast(dispatch_id),
         %Dispatch{} = dispatch <- repo.get(Dispatch, id),
         {:ok, adapter} <- ExecutionProfile.adapter_for(dispatch.provider) do
      binding = %{
        "dispatch_id" => dispatch.id,
        "grant_id" => dispatch.grant_id,
        "role" => "Worker",
        "provider" => dispatch.provider,
        "adapter_id" => adapter.identity().adapter_id,
        "model" => dispatch.model,
        "instructions" => dispatch.brief
      }

      # Bindings recorded before effort or permissions existed have no key;
      # keep them equal.
      binding = if dispatch.effort, do: Map.put(binding, "effort", dispatch.effort), else: binding

      {:ok,
       if(dispatch.permissions in [nil, %{}],
         do: binding,
         else: Map.put(binding, "permissions", dispatch.permissions)
       )}
    else
      _ -> {:error, :invalid_execution_profile}
    end
  end

  def binding(dispatch_id, "Reviewer", repo) do
    with {:ok, id} <- Ecto.UUID.cast(dispatch_id),
         %Dispatch{reviewer_provider: provider, reviewer_model: model} = dispatch
         when is_binary(provider) <- repo.get(Dispatch, id) do
      {:ok,
       %{
         "dispatch_id" => dispatch.id,
         "grant_id" => dispatch.grant_id,
         "role" => "Reviewer",
         "provider" => provider,
         "model" => model
       }}
    else
      _ -> {:error, :invalid_execution_profile}
    end
  end

  def binding(_dispatch_id, _role, _repo), do: {:error, :invalid_execution_profile}

  @doc """
  Cancels a dispatch's execution under its grant, reaping its process
  groups through the ordinary cancellation path. Options: `:oban`, and
  `:requested_by`, a `human:` identity when a person asked (the chat screen;
  anything else is refused), else the grant's.
  """
  def cancel(dispatch, reason, opts \\ [])

  def cancel(%Dispatch{} = dispatch, reason, opts) do
    case Keyword.fetch(opts, :requested_by) do
      {:ok, identity} ->
        if Authority.human?(identity),
          do: do_cancel(dispatch, reason, opts),
          else: {:error, :non_human_identity}

      :error ->
        do_cancel(dispatch, reason, opts)
    end
  end

  defp do_cancel(%Dispatch{state: "started", purpose: purpose} = dispatch, _reason, _opts)
       when purpose in @calls do
    case Calls.get(dispatch.id) do
      %Call{} = call -> Calls.cancel(call)
      nil -> {:error, :not_started}
    end
  end

  defp do_cancel(%Dispatch{state: "started"} = dispatch, reason, opts) do
    ExecutionControl.cancel(
      dispatch.goal_id,
      %{
        command_id: Ecto.UUID.generate(),
        execution_id: dispatch.execution_id,
        requested_by:
          Keyword.get_lazy(opts, :requested_by, fn ->
            Authority.grant_identity(dispatch.grant_id)
          end),
        reason: redact(reason)
      },
      Keyword.take(opts, [:oban]) ++ [dispatch: dispatch]
    )
  end

  # One that follows another and has not started is called off: nothing ran,
  # and its reservation is released.
  defp do_cancel(%Dispatch{state: "chained"} = dispatch, reason, opts) do
    case call_off(dispatch, "cancelled") do
      {:called_off, _} -> {:ok, Repo.get!(Dispatch, dispatch.id)}
      # It started meanwhile: cancel it as any started dispatch.
      :none -> do_cancel(Repo.get!(Dispatch, dispatch.id), reason, opts)
    end
  end

  defp do_cancel(%Dispatch{}, _reason, _opts), do: {:error, :not_started}

  defp digest(text), do: :crypto.hash(:sha256, to_string(text)) |> Base.encode16(case: :lower)

  # Secret-looking values in the coordinator's text, removed; the rest kept.
  defp redact(text) when is_binary(text), do: Security.redact_retained(text)
  defp redact(other), do: other

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "start_failed"
end
