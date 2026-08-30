defmodule Shoestring.Trajectory.Writer do
  @moduledoc """
  A single serialized append worker for one goal.

  Only this process constructs the trusted event identity, relationship, and
  sequence fields. The public boundary supplies an `AppendInput` instead.
  """

  use GenServer

  import Ecto.Query

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{AppendInput, EventRegistry, TrajectoryEvent}

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
      attempt_fun: Keyword.get(opts, :attempt_fun, &default_attempt/2),
      publish_fun: Keyword.get(opts, :publish_fun, &default_publish/3),
      idle_timeout: idle_timeout(Keyword.get(opts, :idle_timeout)),
      idle_timer: nil,
      idle_token: nil
    }

    {:ok, arm_idle_timer(state)}
  end

  @impl true
  def handle_call({:append, %AppendInput{} = input}, _from, state) do
    reply =
      case validate_input(input) do
        :ok ->
          case append_with_retries(input, state, 0) do
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
  def handle_info(:idle_timeout, state), do: {:stop, :normal, state}

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

  defp append_with_retries(input, state, retries) do
    case invoke_attempt(input, state) do
      {:ok, :inserted, event} ->
        {:ok, :inserted, event}

      {:ok, :duplicate, event} ->
        {:ok, :duplicate, event}

      {:error, reason} ->
        if retryable?(reason) do
          if retries < state.max_retries do
            append_with_retries(input, state, retries + 1)
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

  defp invoke_attempt(input, state) do
    state.attempt_fun.(input, state)
  rescue
    error in [DBConnection.ConnectionError, Exqlite.Error] ->
      {:error, database_error(error)}
  end

  defp default_attempt(input, state) do
    case state.repo.transaction(fn -> transaction_attempt(input, state) end) do
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

  defp transaction_attempt(input, state) do
    existing_event(state, input.idempotency_key)
    |> case do
      %TrajectoryEvent{} = event -> {:ok, :duplicate, event}
      nil -> insert_new_event(input, state)
    end
  end

  defp existing_event(_state, nil), do: nil

  defp existing_event(state, idempotency_key) do
    state.repo.get_by(TrajectoryEvent,
      goal_id: state.goal_id,
      idempotency_key: idempotency_key
    )
  end

  defp insert_new_event(input, state) do
    sequence = next_sequence(state)

    event = %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: state.goal_id,
      task_id: nil,
      run_id: nil,
      sequence: sequence,
      parent_event_id: nil,
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
    case EventRegistry.validate_payload(input.type, input.schema_version, input.payload) do
      {:ok, _payload} -> :ok
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
