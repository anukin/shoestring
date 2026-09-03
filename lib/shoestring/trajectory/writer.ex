defmodule Shoestring.Trajectory.Writer do
  @moduledoc """
  A single serialized append worker for one goal.

  Only this process constructs the trusted event identity, relationship, and
  sequence fields. The public boundary supplies an `AppendInput` instead.
  """

  use GenServer

  import Ecto.Query

  alias Shoestring.Repo
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Trajectory

  alias Shoestring.Trajectory.{
    AppendInput,
    EventRegistry,
    TrajectoryEvent,
    TrustedEventReferences
  }

  alias Shoestring.Trajectory.Task, as: TrajectoryTask

  defstruct [
    :goal_id,
    :repo,
    :pubsub,
    :max_retries,
    :attempt_fun,
    :publish_fun,
    :idle_timeout,
    :idle_timer,
    :idle_token
  ]

  @default_max_retries 2

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: via(goal_id))
  end

  @doc false
  def via(goal_id), do: {:via, Registry, {Shoestring.Trajectory.WriterRegistry, goal_id}}

  def child_spec(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)

    %{
      id: {__MODULE__, goal_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      goal_id: Keyword.fetch!(opts, :goal_id),
      repo: Keyword.get(opts, :repo, Repo),
      pubsub: Keyword.get(opts, :pubsub, Shoestring.PubSub),
      max_retries: nonnegative_integer(Keyword.get(opts, :max_retries, @default_max_retries)),
      attempt_fun: Keyword.get(opts, :attempt_fun, &default_attempt/3),
      publish_fun: Keyword.get(opts, :publish_fun, &default_publish/3),
      idle_timeout: idle_timeout(Keyword.get(opts, :idle_timeout)),
      idle_timer: nil,
      idle_token: nil
    }

    {:ok, arm_idle_timer(state)}
  end

  @impl true
  def handle_call({:append, %AppendInput{} = input}, _from, state) do
    handle_append(input, %TrustedEventReferences{}, state)
  end

  @impl true
  def handle_call(
        {:append, %AppendInput{} = input, %TrustedEventReferences{} = references},
        _from,
        state
      ) do
    handle_append(input, references, state)
  end

  defp handle_append(input, references, state) do
    reply =
      case validate_input(input) do
        {:ok, validated_input} ->
          case append_with_retries(validated_input, references, state, 0) do
            {:ok, :inserted, event} -> publish(event, state)
            {:ok, :duplicate, event} -> {:ok, event}
            {:error, reason} -> {:error, reason}
          end

        error ->
          error
      end

    {:reply, reply, arm_idle_timer(state)}
  end

  @impl true
  def handle_info({:idle_timeout, token}, %{idle_token: token} = state),
    do: {:stop, :normal, state}

  @impl true
  def handle_info({:idle_timeout, _stale_token}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{idle_timer: nil}), do: :ok

  def terminate(_reason, %{idle_timer: timer}) do
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp append_with_retries(input, references, state, retries) do
    case invoke_attempt(input, references, state) do
      {:ok, :inserted, event} ->
        {:ok, :inserted, event}

      {:ok, :duplicate, event} ->
        {:ok, :duplicate, event}

      {:error, reason} ->
        if retryable?(reason) do
          if retries < state.max_retries do
            append_with_retries(input, references, state, retries + 1)
          else
            {:error, {:retry_exhausted, retry_reason(reason)}}
          end
        else
          {:error, reason}
        end

      other ->
        {:error, {:invalid_attempt_result, other}}
    end
  end

  defp invoke_attempt(input, references, state) do
    state.attempt_fun.(input, references, state)
  rescue
    error in [DBConnection.ConnectionError, Exqlite.Error] ->
      {:error, database_error(error)}
  end

  defp default_attempt(input, references, state) do
    case state.repo.transaction(fn -> transaction_attempt(input, references, state) end) do
      {:ok, result} ->
        result

      {:error, :idempotency_conflict} ->
        case existing_event(state, input.idempotency_key) do
          %TrajectoryEvent{} = event -> {:ok, :duplicate, event}
          nil -> {:error, :idempotency_conflict}
        end

      {:error, reason} ->
        {:error, transaction_error(reason)}
    end
  rescue
    error in [DBConnection.ConnectionError, Exqlite.Error, Ecto.ConstraintError] ->
      {:error, database_error(error)}
  end

  defp transaction_attempt(input, references, state) do
    existing_event(state, input.idempotency_key)
    |> case do
      %TrajectoryEvent{} = event -> {:ok, :duplicate, event}
      nil -> insert_new_event(input, references, state)
    end
  end

  defp existing_event(_state, nil), do: nil

  defp existing_event(state, idempotency_key) do
    state.repo.get_by(TrajectoryEvent,
      goal_id: state.goal_id,
      idempotency_key: idempotency_key
    )
  end

  defp insert_new_event(input, references, state) do
    case validate_trusted_references(references, state) do
      :ok ->
        sequence = next_sequence(state)

        event = %TrajectoryEvent{
          id: Ecto.UUID.generate(),
          goal_id: state.goal_id,
          task_id: references.task_id,
          run_id: references.run_id,
          sequence: sequence,
          parent_event_id: references.parent_event_id,
          type: input.type,
          actor: input.actor,
          occurred_at: input.occurred_at || DateTime.truncate(DateTime.utc_now(), :microsecond),
          schema_version: input.schema_version,
          payload: input.payload,
          idempotency_key: input.idempotency_key
        }

        changeset = TrajectoryEvent.changeset(event, %{})

        case state.repo.insert(changeset) do
          {:ok, event} ->
            {:ok, :inserted, event}

          {:error, changeset} ->
            state.repo.rollback(classify_insert_error(changeset))
        end

      {:error, reason} ->
        state.repo.rollback(reason)
    end
  end

  defp validate_trusted_references(%TrustedEventReferences{} = references, state) do
    with :ok <- validate_task_reference(references.task_id, state),
         :ok <- validate_run_reference(references.run_id, state),
         :ok <- validate_parent_reference(references.parent_event_id, state) do
      :ok
    end
  end

  defp validate_task_reference(nil, _state), do: :ok

  defp validate_task_reference(task_id, state) do
    exists? =
      state.repo.one(
        from task in TrajectoryTask,
          where: task.id == ^task_id and task.goal_id == ^state.goal_id,
          select: 1
      ) == 1

    if exists?, do: :ok, else: {:error, {:trusted_reference_not_owned, :task_id}}
  end

  defp validate_run_reference(nil, _state), do: :ok

  defp validate_run_reference(run_id, state) do
    exists? =
      state.repo.one(
        from run in RunRecord,
          where: run.id == ^run_id and run.goal_id == ^state.goal_id,
          select: 1
      ) == 1

    if exists?, do: :ok, else: {:error, {:trusted_reference_not_owned, :run_id}}
  end

  defp validate_parent_reference(nil, _state), do: :ok

  defp validate_parent_reference(parent_event_id, state) do
    exists? =
      state.repo.one(
        from event in TrajectoryEvent,
          where: event.id == ^parent_event_id and event.goal_id == ^state.goal_id,
          select: 1
      ) == 1

    if exists?, do: :ok, else: {:error, {:trusted_reference_not_owned, :parent_event_id}}
  end

  defp next_sequence(state) do
    last_sequence =
      state.repo.one(
        from event in TrajectoryEvent,
          where: event.goal_id == ^state.goal_id,
          select: max(event.sequence)
      ) || 0

    last_sequence + 1
  end

  defp classify_insert_error(changeset) do
    cond do
      unique_constraint?(changeset, :sequence) -> :sequence_conflict
      unique_constraint?(changeset, :idempotency_key) -> :idempotency_conflict
      true -> {:validation, changeset}
    end
  end

  defp validate_input(%AppendInput{} = input) do
    now = input.occurred_at || DateTime.utc_now()

    case EventRegistry.validate_payload(input.type, input.schema_version, input.payload, now: now) do
      {:ok, payload} -> {:ok, %{input | payload: payload}}
      error -> error
    end
  end

  defp transaction_error(error) when is_struct(error, DBConnection.ConnectionError),
    do: database_error(error)

  defp transaction_error(error) when is_struct(error, Exqlite.Error), do: database_error(error)
  defp transaction_error(error), do: error

  defp unique_constraint?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> opts[:constraint] == :unique
      _error -> false
    end)
  end

  defp publish(event, state) do
    message = {:trajectory_event_committed, event}

    try do
      case state.publish_fun.(state.pubsub, Trajectory.topic(state.goal_id), message) do
        :ok -> {:ok, event}
        {:error, reason} -> {:error, {:publish_failed, reason, event}}
        other -> {:error, {:publish_failed, other, event}}
      end
    rescue
      error -> {:error, {:publish_failed, Exception.message(error), event}}
    end
  end

  defp default_publish(pubsub, topic, message),
    do: Phoenix.PubSub.broadcast(pubsub, topic, message)

  defp retryable?(:busy), do: true
  defp retryable?(:sequence_conflict), do: true
  defp retryable?({:busy, _reason}), do: true
  defp retryable?({:sequence_conflict, _reason}), do: true
  defp retryable?(_reason), do: false

  defp retry_reason(:busy), do: :busy
  defp retry_reason(:sequence_conflict), do: :sequence_conflict
  defp retry_reason({reason, _details}) when reason in [:busy, :sequence_conflict], do: reason

  defp database_error(error) do
    message = Exception.message(error)

    if String.contains?(message, ["database is locked", "database table is locked", "SQLITE_BUSY"]) do
      :busy
    else
      {:database_error, message}
    end
  end

  defp arm_idle_timer(%{idle_timeout: :infinity} = state),
    do: %{state | idle_timer: nil, idle_token: nil}

  defp arm_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    token = make_ref()
    timer = Process.send_after(self(), {:idle_timeout, token}, state.idle_timeout)
    %{state | idle_timer: timer, idle_token: token}
  end

  defp idle_timeout(nil),
    do: Application.get_env(:shoestring, :trajectory_writer_idle_timeout, 60_000)

  defp idle_timeout(:infinity), do: :infinity
  defp idle_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout
  defp idle_timeout(_timeout), do: 60_000

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value), do: @default_max_retries
end
