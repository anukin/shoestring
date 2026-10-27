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

  alias Shoestring.{AgentProfiles, Authority, Grants, Harnesses, ModelCatalog, Repo}
  alias Shoestring.Cobbler.{ExecutionControl, ExecutionProfile, Intake, PlanContract, Plans}
  alias Shoestring.Dispatches.{Call, Calls, Dispatch}
  alias Shoestring.Grants.Grant
  alias Shoestring.Harness.Security
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
         "plan_digest" => prepared.contract.digest
       }}
    end
  end

  # What past runs of this worker on this kind of task looked like.
  defp advice(prepared) do
    request = prepared.request
    [task] = prepared.contract.content["tasks"]

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
      {:ok, %Dispatch{state: "started"} = dispatch} -> {:ok, dispatch, :replayed}
      {:ok, %Dispatch{state: "creating"} = dispatch} -> start(dispatch, opts, :replayed)
      {:ok, %Dispatch{state: "failed"} = dispatch} -> {:error, {:dispatch_failed, dispatch.error}}
      {:error, _} = error -> error
      nil -> with {:ok, prepared} <- prepare(request), do: reserve(prepared, opts)
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
             dispatch.provider == request.provider and dispatch.purpose == request.purpose,
           do: {:ok, dispatch},
           else: {:error, :request_id_conflict}
    end
  end

  defp existing(_request), do: {:error, :invalid_request_id}

  # -- Validation --------------------------------------------------------

  defp prepare(request) do
    with :ok <- request_id(request.request_id),
         :ok <- purpose(request.purpose),
         {:ok, title} <- text(redact(request.title), :title, 200),
         {:ok, brief} <- brief(redact(request.brief)),
         :ok <- worker(request),
         :ok <- batch(request),
         {:ok, facts} <- Intake.repository(request.repository) do
      prepared = %{
        request: request,
        title: title,
        brief: brief,
        root: facts.root,
        head: facts.head
      }

      prepare(request.purpose, prepared, facts)
    end
  end

  defp prepare("implement", %{request: request} = prepared, facts) do
    with :ok <- reviewer(request),
         {:ok, attempts} <- int(Map.get(request, :attempts, 1), :attempts, 1..20),
         {:ok, seconds} <- int(Map.get(request, :seconds, 1800), :seconds, 60..14_400),
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
           PlanContract.new(plan(goal, prepared.title, request, gates, attempts, seconds)) do
      {:ok, Map.merge(prepared, %{contract: contract, attempts: attempts, seconds: seconds})}
    end
  end

  # EXPLORE and REVIEW are one model call each (`Shoestring.Dispatches.Calls`):
  # the dispatch records the call's contract instead of a plan.
  defp prepare("explore", %{request: request} = prepared, _facts) do
    input = Calls.explore_input(request, prepared.title, prepared.brief, prepared.head)
    {:ok, call(prepared, input)}
  end

  defp prepare("review", %{request: request} = prepared, _facts) do
    with {:ok, target} <- review_target(request, prepared),
         {:ok, input} <- Calls.review_input(request, target) do
      {:ok, call(prepared, input)}
    end
  end

  defp call(prepared, input) do
    Map.merge(prepared, %{
      contract: %{content: Calls.contract(input), digest: PlanContract.digest(input)},
      attempts: 1,
      seconds: Calls.seconds(input["purpose"])
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

  defp plan(goal, title, request, gates, attempts, seconds) do
    accept =
      case Map.get(request, :accept, []) do
        [] -> ["The task's checks pass at its final commit."]
        accept -> accept
      end

    %{
      "version" => 1,
      "goal" => goal,
      "budget" => %{"max_total_attempts" => attempts, "max_total_duration_seconds" => seconds},
      "tasks" => [
        %{
          "id" => @task_id,
          "title" => title,
          "outcome" => title,
          "depends_on" => [],
          "inputs" => ["The coordinator's brief, given with this task."],
          "expected_artifacts" => [],
          "hints" => %{"files" => Map.get(request, :files, []), "symbols" => []},
          "acceptance_criteria" => accept,
          "gates" => gates,
          "checkpoint" => %{
            "condition" => "The task's checks have run and their results are recorded.",
            "evidence" => ["The checks' results at the task's final commit."]
          },
          "risks" => [],
          "execution" => %{"max_attempts" => attempts, "max_duration_seconds" => seconds}
        }
      ]
    }
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
            brief_digest: digest(prepared.brief),
            repository_root: prepared.root,
            base_revision: prepared.head,
            max_attempts: prepared.attempts,
            max_duration_seconds: prepared.seconds,
            batch_label: Map.get(request, :batch_label),
            batch_size: Map.get(request, :batch_size),
            goal_id: if(request.purpose == "implement", do: Ecto.UUID.generate()),
            plan: prepared.contract.content,
            plan_digest: prepared.contract.digest,
            state: "creating",
            inserted_at: now,
            updated_at: now
          })
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, dispatch} -> start(dispatch, opts, :recorded)
      error -> error
    end
  end

  # A call's input is rebuilt from the recorded dispatch and must match the
  # digest recorded with it, so a dispatch interrupted part-way resumes with
  # exactly what was granted.
  defp start(%Dispatch{purpose: purpose} = dispatch, opts, outcome) when purpose in @calls do
    request = %{provider: dispatch.provider, model: dispatch.model, effort: dispatch.effort}

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
               agent_profile: %{"dispatch_id" => dispatch.id, "role" => "Worker"}
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
      attempts: prepared.attempts,
      seconds: prepared.seconds
    }
  end

  @doc """
  What `grant`'s dispatches already reserve: attempts and seconds (every
  dispatch not failed to start) and how many are starting, queued, running,
  waiting or held.
  """
  def usage(%Grant{} = grant) do
    dispatches =
      Repo.all(from d in Dispatch, where: d.grant_id == ^grant.id and d.state != "failed")

    %{
      attempts: Enum.sum_by(dispatches, & &1.max_attempts),
      seconds: Enum.sum_by(dispatches, & &1.max_duration_seconds),
      running: Enum.count(dispatches, &(state(&1) in ~w(starting queued running waiting held)))
    }
  end

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
  `completed`, `cancelled` or `failed_to_start`.
  """
  def state(dispatch, status \\ &ExecutionControl.status/1)
  def state(%Dispatch{state: "creating"}, _status), do: "starting"
  def state(%Dispatch{state: "failed"}, _status), do: "failed_to_start"

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

      {:ok, %{active_run_id: run_id}} when is_binary(run_id) ->
        "running"

      {:ok, %{last_admission: %{"result" => "require_confirmation"}}} ->
        "held"

      {:ok, status} when is_map(status) ->
        if waiting_until(status), do: "waiting", else: queued_or_held(status)

      _ ->
        "queued"
    end
  end

  defp queued_or_held(%{reviews: [_ | _] = reviews}),
    do: if(Enum.any?(reviews, &(&1.state == "held")), do: "held", else: "queued")

  defp queued_or_held(_status), do: "queued"

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
         {:ok, hold} <- hold(current),
         %Grant{revoked_at: nil} = grant <- Grants.get(dispatch.grant_id) do
      spend(dispatch, grant, hold)
    else
      _ -> :none
    end
  end

  def advance(%Dispatch{}, _status), do: :none

  defp hold(%{completed?: false, needs_user?: false, cancelled?: false} = status) do
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

      match?(%{"result" => "require_confirmation"}, decision) and is_nil(status[:active_run_id]) ->
        {:ok,
         %{
           kind: :task,
           key: "task:#{decision["decision_id"]}",
           execution_id: status.execution.execution_id,
           attempt: Map.get(status.attempts, @task_id, 0) + 1
         }}

      true ->
        :none
    end
  end

  defp hold(_status), do: :none

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
      case confirm(dispatch, hold) do
        {:ok, _} ->
          :confirmed

        {:error, reason} ->
          if spent == :now, do: Grants.refund_unread(grant, detail)
          {:error, reason}
      end
    end
  end

  defp confirm(dispatch, %{kind: :task} = hold) do
    ExecutionControl.confirm_capacity(
      dispatch.goal_id,
      %{
        execution_id: hold.execution_id,
        task_id: @task_id,
        attempt: hold.attempt,
        scope: Application.get_env(:shoestring, :run_submission_scope, "subscription"),
        command_id: uuid_for(hold.key),
        requested_by: Authority.grant_identity(dispatch.grant_id)
      },
      dispatch: dispatch
    )
  end

  defp confirm(dispatch, %{kind: :call, call: call}),
    do: Calls.confirm(call, Authority.grant_identity(dispatch.grant_id))

  defp confirm(dispatch, %{kind: :review} = hold) do
    Shoestring.Cobbler.PlanReview.confirm(
      dispatch.goal_id,
      %{
        review_id: hold.review_id,
        confirmation_id: uuid_for(hold.key),
        confirmed_by: Authority.grant_identity(dispatch.grant_id)
      },
      dispatch: dispatch
    )
  end

  # A version-4-shaped UUID derived from the hold, so a repeated confirmation
  # carries the same id and replays instead of recording a second one.
  defp uuid_for(key) do
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

      {:ok, if(dispatch.effort, do: Map.put(binding, "effort", dispatch.effort), else: binding)}
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
  groups through the ordinary cancellation path. Options: `:oban`.
  """
  def cancel(dispatch, reason, opts \\ [])

  def cancel(%Dispatch{state: "started", purpose: purpose} = dispatch, _reason, _opts)
      when purpose in @calls do
    case Calls.get(dispatch.id) do
      %Call{} = call -> Calls.cancel(call)
      nil -> {:error, :not_started}
    end
  end

  def cancel(%Dispatch{state: "started"} = dispatch, reason, opts) do
    ExecutionControl.cancel(
      dispatch.goal_id,
      %{
        command_id: Ecto.UUID.generate(),
        execution_id: dispatch.execution_id,
        requested_by: Authority.grant_identity(dispatch.grant_id),
        reason: redact(reason)
      },
      Keyword.take(opts, [:oban]) ++ [dispatch: dispatch]
    )
  end

  def cancel(%Dispatch{}, _reason, _opts), do: {:error, :not_started}

  defp digest(text), do: :crypto.hash(:sha256, to_string(text)) |> Base.encode16(case: :lower)

  # Secret-looking values in the coordinator's text, removed; the rest kept.
  defp redact(text) when is_binary(text), do: Security.redact_retained(text)
  defp redact(other), do: other

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "start_failed"
end
