defmodule Shoestring.Harness.Runs do
  @moduledoc "Durable run-intent creation and recovery before any harness side effect."

  import Ecto.Query

  alias Shoestring.Harness.{
    Clock,
    Error,
    EventPayload,
    Identifier,
    Identity,
    RunRecord,
    RunRequest
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, Task, TrajectoryEvent}

  @spec request(RunRequest.t(), Identity.t(), keyword()) ::
          {:ok, RunRecord.t()} | {:error, Error.t() | term()}
  def request(%RunRequest{} = request, %Identity{} = identity, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, changeset} <- build_intent_changeset(request, identity, opts),
         {:ok, run} <- insert_or_recover(repo, changeset),
         :ok <- append_requested(run, request, identity, opts) do
      {:ok, run}
    else
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  @spec build_intent_changeset(RunRequest.t(), Identity.t(), keyword()) ::
          {:ok, Ecto.Changeset.t()} | {:error, Error.t() | term()}
  def build_intent_changeset(%RunRequest{} = request, %Identity{} = identity, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    identifier = Keyword.get(opts, :identifier, Shoestring.Harness.SystemIdentifier)
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
    now = Clock.now(clock)

    with :ok <- compatible?(identity, request),
         :ok <- validate_goal_and_task(repo, request) do
      run = %RunRecord{id: Identifier.generate(identifier)}
      {:ok, RunRecord.intent_changeset(run, request, identity.adapter_id, now)}
    end
  end

  @doc false
  @spec insert_or_recover(module(), Ecto.Changeset.t()) ::
          {:ok, RunRecord.t()} | {:error, term()}
  def insert_or_recover(repo, changeset) do
    case repo.insert(changeset) do
      {:ok, run} -> {:ok, run}
      {:error, changeset} -> recover_existing_run(repo, changeset)
    end
  end

  @doc false
  @spec recover_existing_run(module(), Ecto.Changeset.t()) ::
          {:ok, RunRecord.t()} | {:error, term()}
  def recover_existing_run(repo, changeset) do
    if dispatch_id_conflict?(changeset) do
      dispatch_id = Ecto.Changeset.get_field(changeset, :dispatch_id)

      case repo.get_by(RunRecord, dispatch_id: dispatch_id) do
        %RunRecord{} = run -> {:ok, run}
        nil -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  @doc false
  @spec ensure_requested_event(RunRecord.t(), RunRequest.t(), Identity.t(), keyword()) ::
          :ok | {:error, term()}
  def ensure_requested_event(run, request, identity, opts),
    do: append_requested(run, request, identity, opts)

  @doc "Repairs a persisted intent that has no canonical run.requested event yet."
  @spec reconcile(Ecto.UUID.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    runs =
      repo.all(
        from run in RunRecord, where: run.goal_id == ^goal_id, order_by: [asc: run.inserted_at]
      )

    Enum.reduce_while(runs, {:ok, 0}, fn run, {:ok, count} ->
      if requested_event?(run, repo) do
        {:cont, {:ok, count}}
      else
        case append_requested_record(run, opts) do
          :ok -> {:cont, {:ok, count + 1}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end
    end)
  end

  @spec owned?(Ecto.UUID.t(), Ecto.UUID.t(), module()) :: boolean()
  def owned?(goal_id, run_id, repo \\ Repo) do
    repo.exists?(from run in RunRecord, where: run.id == ^run_id and run.goal_id == ^goal_id)
  end

  defp compatible?(%Identity{schema_version: version}, %RunRequest{version: version}), do: :ok

  defp compatible?(%Identity{schema_version: actual}, %RunRequest{version: expected}) do
    {:error,
     Error.new(
       :schema_incompatible,
       "run_request_version_incompatible",
       "adapter schema version #{actual} cannot consume run request v#{expected}",
       details: %{
         "shoestring.harness:adapter_schema_version" => actual,
         "shoestring.harness:request_version" => expected
       }
     )}
  end

  defp dispatch_id_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:dispatch_id, {_message, opts}} -> opts[:constraint] == :unique
      _error -> false
    end)
  end

  defp requested_event?(run, repo) do
    repo.exists?(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^run.goal_id and
            event.run_id == ^run.id and
            event.type == "run.requested" and
            event.idempotency_key == ^"run-requested:#{run.dispatch_id}"
    )
  end

  defp validate_goal_and_task(repo, request) do
    cond do
      is_nil(repo.get(Goal, request.goal_id)) ->
        {:error, Error.new(:task_failed, "goal_not_found", "goal does not exist")}

      not repo.exists?(
        from task in Task, where: task.id == ^request.task_id and task.goal_id == ^request.goal_id
      ) ->
        {:error, Error.new(:task_failed, "task_not_owned", "task does not belong to the goal")}

      true ->
        :ok
    end
  end

  defp append_requested(run, request, identity, opts) do
    attrs =
      requested_event_attributes(
        run,
        request,
        identity,
        Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
      )

    case Trajectory.append(run.goal_id, attrs,
           trusted: [task_id: run.task_id, run_id: run.id],
           writer_opts: Keyword.get(opts, :writer_opts, [])
         ) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, {:intent_persisted_without_event, run.id, reason}}
    end
  end

  defp append_requested_record(run, opts) do
    now = Clock.now(Keyword.get(opts, :clock, Shoestring.Harness.SystemClock))

    attrs = %{
      "type" => "run.requested",
      "schema_version" => 1,
      "actor" => "harness",
      "occurred_at" => now,
      "idempotency_key" => "run-requested:#{run.dispatch_id}",
      "payload" => %{
        "run_id" => run.id,
        "dispatch_id" => run.dispatch_id,
        "provider_id" => run.provider_id,
        "workspace_ref" => run.workspace_ref,
        "request_version" => run.request_version,
        "prompt" => run.prompt,
        "continuation" => run.continuation || %{},
        "policy" => run.policy,
        "requested_capabilities" => run.requested_capabilities,
        "extensions" => %{}
      }
    }

    case Trajectory.append(run.goal_id, attrs,
           trusted: [task_id: run.task_id, run_id: run.id],
           writer_opts: Keyword.get(opts, :writer_opts, [])
         ) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp requested_event_attributes(run, request, identity, clock) do
    %{
      "type" => "run.requested",
      "schema_version" => 1,
      "actor" => "harness",
      "occurred_at" => Clock.now(clock),
      "idempotency_key" => "run-requested:#{request.dispatch_id}",
      "payload" => EventPayload.run_requested(request, run.id, identity.adapter_id)
    }
  end
end
