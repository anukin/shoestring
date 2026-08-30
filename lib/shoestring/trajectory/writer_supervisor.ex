defmodule Shoestring.Trajectory.WriterSupervisor do
  @moduledoc "Dynamic supervisor for one registered trajectory writer per goal."

  use DynamicSupervisor

  alias Shoestring.Trajectory.Writer

  @registry Shoestring.Trajectory.WriterRegistry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Looks up or atomically starts the writer registered for a goal."
  @spec ensure_started(Ecto.UUID.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(goal_id, opts \\ []) do
    lookup_or_start(goal_id, opts, 0)
  end

  @doc false
  @spec start_writer(Ecto.UUID.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_writer(goal_id, opts \\ []) do
    child_opts = Keyword.put(opts, :goal_id, goal_id)
    DynamicSupervisor.start_child(__MODULE__, {Writer, child_opts})
  end

  defp lookup_or_start(goal_id, opts, attempt) do
    case Registry.lookup(@registry, goal_id) do
      [{pid, _value}] ->
        if GenServer.whereis(Writer.via(goal_id)) == pid do
          {:ok, pid}
        else
          start_or_retry(goal_id, opts, attempt)
        end

      [] ->
        start_or_retry(goal_id, opts, attempt)
    end
  end

  defp start_or_retry(goal_id, opts, attempt) do
    case start_writer(goal_id, opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, {:already_registered, pid}} ->
        {:ok, pid}

      {:error, {:already_present, _child_id}} when attempt == 0 ->
        lookup_or_start(goal_id, opts, 1)

      {:error, reason} ->
        {:error, {:writer_start_failed, reason}}
    end
  end
end
