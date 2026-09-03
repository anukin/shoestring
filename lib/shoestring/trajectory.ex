defmodule Shoestring.Trajectory do
  @moduledoc "Public append, replay, and ordered stream boundary for trajectories."

  import Ecto.Query

  alias Shoestring.Repo

  alias Shoestring.Trajectory.{
    AppendInput,
    EventRegistry,
    TrajectoryEvent,
    TrustedEventReferences,
    WriterSupervisor
  }

  @default_call_timeout 15_000

  @doc "Validates and appends one untrusted event input to the selected goal."
  @spec append(Ecto.UUID.t(), map(), Keyword.t()) ::
          {:ok, TrajectoryEvent.t()}
          | {:error, term()}
  def append(goal_id, attrs, opts \\ []) do
    with {:ok, normalized_goal_id} <- cast_goal_id(goal_id),
         {:ok, input} <- AppendInput.cast(attrs),
         {:ok, references} <- TrustedEventReferences.cast(Keyword.get(opts, :trusted)),
         :ok <- validate_registered_input(input),
         {:ok, pid} <- WriterSupervisor.ensure_started(normalized_goal_id, writer_opts(opts)) do
      dispatch_append(normalized_goal_id, input, references, pid, opts, 0)
    end
  end

  @doc "Replays all compatible events for a goal in canonical sequence order."
  @spec replay(Ecto.UUID.t(), Keyword.t()) ::
          {:ok, [TrajectoryEvent.t()]}
          | {:error, term()}
  def replay(goal_id, _opts \\ []) do
    with {:ok, normalized_goal_id} <- cast_goal_id(goal_id),
         events <- fetch_events(normalized_goal_id),
         :ok <- validate_history(events) do
      {:ok, events}
    end
  end

  @doc "Returns an ordered, already-compatible event stream for a goal."
  @spec stream(Ecto.UUID.t(), Keyword.t()) ::
          {:ok, Enumerable.t()}
          | {:error, term()}
  def stream(goal_id, opts \\ []) do
    case replay(goal_id, opts) do
      {:ok, events} -> {:ok, Stream.map(events, & &1)}
      error -> error
    end
  end

  @doc "The PubSub topic carrying committed events for one goal."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(goal_id), do: "trajectory:goal:#{goal_id}"

  defp cast_goal_id(goal_id) do
    case Ecto.UUID.cast(goal_id) do
      {:ok, normalized_goal_id} -> {:ok, normalized_goal_id}
      :error -> {:error, {:invalid_goal_id, goal_id}}
    end
  end

  defp validate_registered_input(%AppendInput{} = input) do
    now = input.occurred_at || DateTime.utc_now()

    case EventRegistry.validate_payload(input.type, input.schema_version, input.payload, now: now) do
      {:ok, _payload} -> :ok
      error -> error
    end
  end

  defp writer_opts(opts), do: Keyword.get(opts, :writer_opts, [])

  defp dispatch_append(goal_id, input, references, pid, opts, attempt) do
    try do
      dispatch_fun(opts).(pid, {:append, input, references}, call_timeout(opts))
    catch
      :exit, reason ->
        recover_writer_exit(goal_id, input, references, pid, opts, attempt, reason)
    end
  end

  defp recover_writer_exit(goal_id, input, references, pid, opts, 0, reason) do
    cond do
      writer_disappeared?(reason, pid) ->
        case WriterSupervisor.ensure_started(goal_id, writer_opts(opts)) do
          {:ok, replacement_pid} ->
            dispatch_append(goal_id, input, references, replacement_pid, opts, 1)

          {:error, _start_reason} ->
            {:error, {:writer_unavailable, :disappeared}}
        end

      ambiguous_writer_exit?(reason, pid) ->
        {:error, {:writer_unavailable, :ambiguous}}

      true ->
        exit(reason)
    end
  end

  defp recover_writer_exit(_goal_id, _input, _references, pid, _opts, 1, reason) do
    cond do
      writer_disappeared?(reason, pid) ->
        {:error, {:writer_unavailable, :disappeared}}

      ambiguous_writer_exit?(reason, pid) ->
        {:error, {:writer_unavailable, :ambiguous}}

      true ->
        exit(reason)
    end
  end

  # :noproc and the writer's token-protected :normal idle exit happen before a call can reply.
  # A :shutdown exit is ambiguous because an application stop may follow delivery.
  defp writer_disappeared?({kind, {GenServer, :call, [called_pid | _rest]}}, pid)
       when kind in [:noproc, :normal] do
    called_pid == pid
  end

  defp writer_disappeared?(_reason, _pid), do: false

  defp ambiguous_writer_exit?({:shutdown, {GenServer, :call, [called_pid | _rest]}}, pid) do
    called_pid == pid
  end

  defp ambiguous_writer_exit?(_reason, _pid), do: false

  defp dispatch_fun(opts), do: Keyword.get(opts, :dispatch_fun, &GenServer.call/3)

  defp call_timeout(opts), do: Keyword.get(opts, :call_timeout, @default_call_timeout)

  defp fetch_events(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id,
        order_by: [asc: event.sequence]
    )
  end

  defp validate_history(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case EventRegistry.validate(event_attributes(event)) do
        {:ok, _validated} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp event_attributes(event) do
    %{
      id: event.id,
      goal_id: event.goal_id,
      task_id: event.task_id,
      run_id: event.run_id,
      sequence: event.sequence,
      parent_event_id: event.parent_event_id,
      type: event.type,
      actor: event.actor,
      occurred_at: event.occurred_at,
      schema_version: event.schema_version,
      payload: event.payload,
      idempotency_key: event.idempotency_key
    }
  end
end
