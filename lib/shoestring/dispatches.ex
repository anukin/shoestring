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
  Dispatched work is not cross-reviewed automatically: the coordinator
  dispatches a REVIEW from another vendor.

  The grant's limits are checked in the same immediate transaction that
  records the dispatch, so two concurrent dispatches cannot both take room
  only one fits. `(session, request id)` makes a dispatch idempotent: the
  same request returns the same dispatch, and one interrupted part-way
  resumes from its recorded plan. A dry run validates and checks the grant
  without recording anything.
  """
  import Ecto.Query

  alias Shoestring.{AgentProfiles, Authority, Grants, Harnesses, ModelCatalog, Repo}
  alias Shoestring.Cobbler.{ExecutionControl, ExecutionProfile, Intake, PlanContract, Plans}
  alias Shoestring.Dispatches.Dispatch
  alias Shoestring.Grants.Grant
  alias Shoestring.Trajectory.Goal

  @task_id "dispatch"
  @max_brief 16_000
  @request_id ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,99}\z/
  @available ~w(implement)

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
  recording anything. Returns the plan it would run and the grant's room.
  """
  def dry_run(request) do
    with {:ok, prepared} <- prepare(request),
         %Grant{} = grant <- Grants.active(request.session_id) || {:error, :no_grant} do
      usage = usage(grant)

      {:ok,
       %{
         "would_dispatch" => Grants.check(grant, check_request(prepared), usage) == :ok,
         "grant_check" => check_result(Grants.check(grant, check_request(prepared), usage)),
         "grant" => room(grant, usage),
         "plan" => prepared.contract.content,
         "plan_digest" => prepared.contract.digest
       }}
    end
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
        if dispatch.brief_digest == digest(request.brief) and dispatch.model == request.model and
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
         {:ok, title} <- text(request.title, :title, 200),
         {:ok, brief} <- brief(request.brief),
         :ok <- worker(request),
         {:ok, attempts} <- int(Map.get(request, :attempts, 1), :attempts, 1..20),
         {:ok, seconds} <- int(Map.get(request, :seconds, 1800), :seconds, 60..14_400),
         :ok <- batch(request),
         {:ok, facts} <- Intake.repository(request.repository),
         {:ok, gates} <-
           Intake.gates(facts,
             gates: Map.get(request, :gates, []),
             tests: Map.get(request, :tests, [])
           ),
         {:ok, goal} <-
           Intake.goal_contract(title, facts, gates,
             constraints: Enum.map(Map.get(request, :stay_out, []), &"Do not change #{&1}.")
           ),
         {:ok, contract} <- PlanContract.new(plan(goal, title, request, gates, attempts, seconds)) do
      {:ok,
       %{
         request: request,
         title: title,
         brief: brief,
         root: facts.root,
         head: facts.head,
         contract: contract,
         attempts: attempts,
         seconds: seconds
       }}
    end
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

      not Harnesses.supports?(provider, :implement) ->
        {:error, {:harness_cannot, provider, :implement}}

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
            title: prepared.title,
            brief: prepared.brief,
            brief_digest: digest(prepared.brief),
            repository_root: prepared.root,
            base_revision: prepared.head,
            max_attempts: prepared.attempts,
            max_duration_seconds: prepared.seconds,
            batch_label: Map.get(request, :batch_label),
            batch_size: Map.get(request, :batch_size),
            goal_id: Ecto.UUID.generate(),
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
      attempts: prepared.attempts,
      seconds: prepared.seconds
    }
  end

  @doc """
  What `grant`'s dispatches already reserve: attempts and seconds (every
  dispatch not failed to start) and how many are starting, queued, running or
  held.
  """
  def usage(%Grant{} = grant) do
    dispatches =
      Repo.all(from d in Dispatch, where: d.grant_id == ^grant.id and d.state != "failed")

    %{
      attempts: Enum.sum_by(dispatches, & &1.max_attempts),
      seconds: Enum.sum_by(dispatches, & &1.max_duration_seconds),
      running: Enum.count(dispatches, &(state(&1) in ~w(starting queued running held)))
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
  `running`, `held` (its provider's remaining usage could not be confirmed;
  a person confirms it), `needs_you` (waits for a person), `completed`,
  `cancelled` or `failed_to_start`.
  """
  def state(dispatch, status \\ &ExecutionControl.status/1)
  def state(%Dispatch{state: "creating"}, _status), do: "starting"
  def state(%Dispatch{state: "failed"}, _status), do: "failed_to_start"

  def state(%Dispatch{state: "started"} = dispatch, status) do
    case status.(dispatch.goal_id) do
      {:ok, %{cancelled?: true}} -> "cancelled"
      {:ok, %{completed?: true}} -> "completed"
      {:ok, %{needs_user?: true}} -> "needs_you"
      {:ok, %{active_run_id: run_id}} when is_binary(run_id) -> "running"
      {:ok, %{last_admission: %{"result" => "require_confirmation"}}} -> "held"
      _ -> "queued"
    end
  end

  @doc "Whether `state` ends what a coordinator waits for."
  def settled?(state), do: state in ~w(completed cancelled needs_you held failed_to_start)

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

  def binding(_dispatch_id, _role, _repo), do: {:error, :invalid_execution_profile}

  @doc """
  Cancels a dispatch's execution under its grant, reaping its process
  groups through the ordinary cancellation path. Options: `:oban`.
  """
  def cancel(dispatch, reason, opts \\ [])

  def cancel(%Dispatch{state: "started"} = dispatch, reason, opts) do
    ExecutionControl.cancel(
      dispatch.goal_id,
      %{
        command_id: Ecto.UUID.generate(),
        execution_id: dispatch.execution_id,
        requested_by: Authority.grant_identity(dispatch.grant_id),
        reason: reason
      },
      Keyword.take(opts, [:oban]) ++ [dispatch: dispatch]
    )
  end

  def cancel(%Dispatch{}, _reason, _opts), do: {:error, :not_started}

  defp digest(text), do: :crypto.hash(:sha256, to_string(text)) |> Base.encode16(case: :lower)

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "start_failed"
end
