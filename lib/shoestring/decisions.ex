defmodule Shoestring.Decisions do
  @moduledoc """
  Decision points (iteration 19): a plan task produced N candidates and the
  plan waits, before the task's dependents, for a person to choose one.

  A decision is durable and process-free, unlike a permission ask
  (`Shoestring.PermissionAsks`), which lives only as long as the worker
  session waiting on it. No process waits here; the plan's execution job
  stops (`needs_user`) and is queued again when the answer is recorded. It
  keeps the ask's three rules:

  - **Only a person answers.** `answer/5` takes a `human:` identity; the
    coordinator may list and describe decisions, never answer them.
  - **The first answer wins.** The answer is a conditional update on
    `state = 'pending'` in the same immediate transaction as its
    `cobbler.plan.decision.answered` event; a second answer is refused with
    `:already_answered`.
  - **Nothing is decided by a timer.** A pending decision has no deadline.
    How long it has waited is shown, never acted on.

  The executor (`Shoestring.Cobbler.PlanExecutor`) records the request in
  the same transaction as the task's acceptance, and reads the
  `cobbler.plan.decision.*` events, not these rows, to decide what may run.
  `reject` ("none of these", when the plan allows it, with a mandatory
  note) fails the task for a person to resolve, like a gate failure that
  needs the user. Cancelling the goal withdraws pending decisions; their
  artifacts are kept.
  """

  import Ecto.Query
  require Logger

  alias Shoestring.Cobbler.ReservationWriter
  alias Shoestring.Decisions.{Decision, DecisionFile}
  alias Shoestring.{Repo, Trajectory}
  alias Shoestring.Trajectory.{ArtifactStore, TrajectoryEvent}

  @requested "cobbler.plan.decision.requested"
  @answered "cobbler.plan.decision.answered"
  @withdrawn "cobbler.plan.decision.withdrawn"
  @human ~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/
  @max_note 2_000

  @doc "The trajectory event types decisions write."
  def event_types, do: [@requested, @answered, @withdrawn]

  @doc "The reserved answer for \"none of these\"."
  def reject, do: "reject"

  # ----------------------------------------------------------------------------
  # Reading
  # ----------------------------------------------------------------------------

  @doc "One decision by id, or nil."
  @spec get(String.t()) :: Decision.t() | nil
  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Decision, id)
      :error -> nil
    end
  end

  @doc """
  Decisions, newest first. Options: `:goal_ids` (a list), `:states` (a
  list; default every state), `:limit` (default 100).
  """
  @spec list(keyword()) :: [Decision.t()]
  def list(opts \\ []) do
    Decision
    |> then(fn query ->
      case Keyword.get(opts, :goal_ids) do
        nil -> query
        ids -> where(query, [d], d.goal_id in ^ids)
      end
    end)
    |> then(fn query ->
      case Keyword.get(opts, :states) do
        nil -> query
        states -> where(query, [d], d.state in ^states)
      end
    end)
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc "The answers a person may give: each option key, then `reject` when allowed."
  @spec choices(Decision.t()) :: [String.t()]
  def choices(%Decision{} = decision) do
    Enum.map(decision.options, & &1["key"]) ++
      if(decision.allow_reject, do: [reject()], else: [])
  end

  # ----------------------------------------------------------------------------
  # Request (called by the executor)
  # ----------------------------------------------------------------------------

  @doc """
  Reads and validates the decision file in `worktree` and stores each
  candidate's `file` as an artifact of the goal. Runs before the
  acceptance transaction (it writes files); the artifacts are
  content-addressed, so a repeat stores the same bytes again harmlessly.
  Returns `{:ok, %{question, note, options}}` with each option's
  `"artifact_id"`, or `{:error, reason}`, a bounded text the executor
  records as the task's gate failure.
  """
  @spec prepare(Ecto.UUID.t(), Ecto.UUID.t() | nil, Path.t(), map(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def prepare(goal_id, trajectory_task_id, worktree, decision, opts \\ []) do
    with {:ok, parsed} <- DecisionFile.read(worktree, decision, opts) do
      max = ArtifactStore.max_size(opts)

      parsed.options
      |> Enum.reduce_while({:ok, []}, fn option, {:ok, acc} ->
        with {:ok, bytes} <- DecisionFile.read_file(worktree, option["file"], max),
             {:ok, artifact} <-
               ArtifactStore.put(
                 goal_id,
                 bytes,
                 %{media_type: option["media_type"], redacted: false},
                 Keyword.put(opts, :task_id, trajectory_task_id)
               ) do
          {:cont, {:ok, [Map.put(option, "artifact_id", artifact.id) | acc]}}
        else
          {:error, reason} when is_binary(reason) ->
            {:halt, {:error, reason}}

          {:error, reason} ->
            {:halt, {:error, "#{option["file"]} could not be stored (#{inspect(reason)})"}}
        end
      end)
      |> case do
        {:ok, options} -> {:ok, %{parsed | options: Enum.reverse(options)}}
        error -> error
      end
    end
  end

  @doc """
  Inserts the pending decision row inside the caller's transaction and
  returns the `cobbler.plan.decision.requested` payload for the caller to
  append in the same transaction. `attrs`: `:id`, `:goal_id`,
  `:execution_id`, `:revision_number`, `:plan_digest`, `:plan_task_id`,
  `:attempt`, `:run_id`, `:decision` (the plan's decision map) and
  `:prepared` (from `prepare/5`). The executor calls this only for an
  attempt not yet resolved, so an existing row is an error, never skipped.
  """
  @spec insert_request(module(), map()) :: {:ok, map()} | {:error, term()}
  def insert_request(repo, attrs) do
    prepared = attrs.prepared
    now = DateTime.utc_now()

    row = %Decision{
      id: attrs.id,
      goal_id: attrs.goal_id,
      execution_id: attrs.execution_id,
      plan_task_id: attrs.plan_task_id,
      attempt: attrs.attempt,
      run_id: attrs.run_id,
      key: attrs.decision["id"],
      question: prepared.question,
      note: prepared.note,
      options: prepared.options,
      allow_reject: attrs.decision["allow_reject"],
      state: "pending",
      inserted_at: now,
      updated_at: now
    }

    with {:ok, _} <- repo.insert(row) do
      {:ok,
       %{
         "decision_id" => attrs.id,
         "execution_id" => attrs.execution_id,
         "revision_number" => attrs.revision_number,
         "plan_digest" => attrs.plan_digest,
         "plan_task_id" => attrs.plan_task_id,
         "attempt" => attrs.attempt,
         "run_id" => attrs.run_id,
         "key" => attrs.decision["id"],
         "question" => prepared.question,
         "allow_reject" => attrs.decision["allow_reject"],
         "options" => prepared.options
       }}
    end
  end

  @doc """
  Copies each chosen candidate kept under `.shoestring/` into a dependent
  task's new worktree at the same path, from the verified artifact store.
  Any other path was committed by the deciding task, so it is already in
  the tree. A missing or corrupt artifact stops the dispatch.
  """
  @spec materialize(Path.t(), [map()], keyword()) :: :ok | {:error, term()}
  def materialize(worktree, inputs, opts \\ []) do
    Enum.reduce_while(inputs, :ok, fn input, :ok ->
      path = input["path"]

      if is_binary(path) and String.starts_with?(path, ".shoestring/") do
        target = Path.join(worktree, path)

        with :ok <- no_symlinks(worktree, Path.dirname(path)),
             {:ok, %{bytes: bytes}} <- ArtifactStore.read(input["artifact_id"], opts),
             :ok <- File.mkdir_p(Path.dirname(target)),
             :ok <- File.write(target, bytes) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, {:decision_input_unavailable, path, reason}}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  # A fresh worktree has no `.shoestring/`; a linked directory on the way
  # would send the copy outside it.
  defp no_symlinks(worktree, relative_dir) do
    relative_dir
    |> String.split("/")
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case File.lstat(Path.join(worktree, dir)) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink}}
        _ -> {:cont, :ok}
      end
    end)
  end

  # ----------------------------------------------------------------------------
  # Answer
  # ----------------------------------------------------------------------------

  @doc """
  Records a person's answer: `choice` is one option's key, or `"reject"`
  (only when the decision allows it, and then `note` is required). `by`
  must be a `human:` identity. The first answer wins; the plan's execution
  is queued again afterwards.

  Errors: `:non_human_identity`, `:decision_not_found`, `:already_answered`,
  `:decision_withdrawn`, `:unknown_option`, `:reject_not_allowed`,
  `:note_required`, `:note_too_long`.

  Options: `:resume_fun` (`fn goal_id, execution_id -> any end`; default
  `Shoestring.Cobbler.ExecutionControl.continue/2`), `:publish_fun`.
  """
  @spec answer(String.t(), String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, Decision.t()} | {:error, atom()}
  def answer(decision_id, choice, note, by, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with :ok <- human(by),
         %Decision{} = decision <- get(decision_id) || {:error, :decision_not_found},
         :ok <- open(decision),
         {:ok, note} <- note(note, choice),
         {:ok, state} <- validate_choice(decision, choice) do
      ReservationWriter.run(repo, fn ->
        repo.transaction(
          fn -> settle(repo, decision, state, choice, note, by) end,
          mode: :immediate
        )
      end)
      |> case do
        {:ok, {decision, event}} ->
          after_answer(decision, event, opts)
          {:ok, decision}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp settle(repo, decision, state, choice, note, by) do
    now = DateTime.utc_now()

    {count, _} =
      repo.update_all(
        from(d in Decision, where: d.id == ^decision.id and d.state == "pending"),
        set: [
          state: state,
          answer_key: choice,
          answer_note: note,
          decided_by: by,
          decided_at: now,
          updated_at: now
        ]
      )

    if count != 1 do
      repo.rollback(closed_reason(repo.get!(Decision, decision.id)))
    else
      payload =
        %{
          "decision_id" => decision.id,
          "execution_id" => decision.execution_id,
          "plan_task_id" => decision.plan_task_id,
          "attempt" => decision.attempt,
          "run_id" => decision.run_id,
          "answer" => if(state == "rejected", do: "reject", else: "choose"),
          "decided_by" => by
        }
        |> then(&if(state == "answered", do: Map.put(&1, "option_key", choice), else: &1))
        |> then(&if(note, do: Map.put(&1, "note", note), else: &1))

      case append(repo, decision, @answered, "human", payload, "plan-decision-answered") do
        {:ok, event} -> {repo.get!(Decision, decision.id), event}
        {:error, reason} -> repo.rollback(reason)
      end
    end
  end

  defp after_answer(decision, event, opts) do
    publish(event, opts)

    resume =
      Keyword.get(opts, :resume_fun, fn goal_id, execution_id ->
        Shoestring.Cobbler.ExecutionControl.continue(goal_id, execution_id)
      end)

    # The answer is recorded either way; a plan not queued again stays
    # answerable from `shoestring execution continue`, so the failure is
    # logged, never swallowed.
    try do
      resume.(decision.goal_id, decision.execution_id)
    rescue
      error ->
        Logger.warning("decision #{decision.id} answered; plan not queued: #{inspect(error)}")
    catch
      kind, reason ->
        Logger.warning(
          "decision #{decision.id} answered; plan not queued: #{inspect({kind, reason})}"
        )
    end
  end

  defp human(by) when is_binary(by) do
    if Regex.match?(@human, by), do: :ok, else: {:error, :non_human_identity}
  end

  defp human(_by), do: {:error, :non_human_identity}

  defp open(%Decision{state: "pending"}), do: :ok
  defp open(decision), do: {:error, closed_reason(decision)}

  defp closed_reason(%Decision{state: "withdrawn"}), do: :decision_withdrawn
  defp closed_reason(_decision), do: :already_answered

  defp note(nil, "reject"), do: {:error, :note_required}
  defp note(nil, _choice), do: {:ok, nil}

  defp note(note, choice) when is_binary(note) do
    note = String.trim(note)

    cond do
      note == "" and choice == "reject" -> {:error, :note_required}
      note == "" -> {:ok, nil}
      String.length(note) > @max_note -> {:error, :note_too_long}
      true -> {:ok, note}
    end
  end

  defp note(_note, _choice), do: {:error, :note_required}

  defp validate_choice(%Decision{allow_reject: true}, "reject"), do: {:ok, "rejected"}
  defp validate_choice(%Decision{}, "reject"), do: {:error, :reject_not_allowed}

  defp validate_choice(decision, choice) do
    if Enum.any?(decision.options, &(&1["key"] == choice)),
      do: {:ok, "answered"},
      else: {:error, :unknown_option}
  end

  # ----------------------------------------------------------------------------
  # Withdrawal (goal cancelled)
  # ----------------------------------------------------------------------------

  @doc """
  Withdraws every pending decision of one execution, inside the caller's
  transaction (the goal cancellation's). Artifacts are kept.
  """
  @spec withdraw_execution(module(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def withdraw_execution(repo, goal_id, execution_id, reason) do
    pending =
      repo.all(
        from d in Decision,
          where:
            d.goal_id == ^goal_id and d.execution_id == ^execution_id and d.state == "pending"
      )

    Enum.reduce_while(pending, {:ok, 0}, fn decision, {:ok, n} ->
      now = DateTime.utc_now()

      {1, _} =
        repo.update_all(
          from(d in Decision, where: d.id == ^decision.id and d.state == "pending"),
          set: [state: "withdrawn", updated_at: now]
        )

      payload = %{
        "decision_id" => decision.id,
        "execution_id" => decision.execution_id,
        "plan_task_id" => decision.plan_task_id,
        "attempt" => decision.attempt,
        "run_id" => decision.run_id,
        "reason" => String.slice(reason, 0, @max_note)
      }

      case append(repo, decision, @withdrawn, "cobbler", payload, "plan-decision-withdrawn") do
        {:ok, _event} -> {:cont, {:ok, n + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append(repo, decision, type, actor, payload, key_prefix) do
    Trajectory.append(
      decision.goal_id,
      %{
        "type" => type,
        "schema_version" => 1,
        "actor" => actor,
        "occurred_at" => DateTime.utc_now(),
        "idempotency_key" => "#{key_prefix}:#{decision.id}",
        "payload" => payload
      },
      trusted: [run_id: decision.run_id],
      writer_opts: [transaction_repo: repo]
    )
  end

  @doc false
  def publish(%TrajectoryEvent{} = event, opts) do
    publish =
      Keyword.get(opts, :publish_fun, fn event ->
        Phoenix.PubSub.broadcast(
          Shoestring.PubSub,
          Trajectory.topic(event.goal_id),
          {:trajectory_event_committed, event}
        )
      end)

    publish.(event)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
