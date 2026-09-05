defmodule Shoestring.Test.ElvesHelpers do
  @moduledoc """
  Hermetic builders for Elf lifecycle tests: goals, tasks, run requests, and
  polling helpers for real OS process groups. No provider CLI, no network.
  """

  import Ecto.Query

  alias Shoestring.Harness.{Fake, Identity, RunRequest}
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, Task, TrajectoryEvent}

  @doc "Inserts a goal + task pair with fresh UUIDs."
  @spec insert_goal_task() :: %{goal: Goal.t(), task: Task.t()}
  def insert_goal_task do
    goal =
      %Goal{id: Ecto.UUID.generate()}
      |> Goal.changeset(%{"title" => "Elf goal"})
      |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
      |> Repo.insert!()

    task =
      %Task{id: Ecto.UUID.generate()}
      |> Task.changeset(%{"title" => "Elf task"})
      |> Ecto.Changeset.put_change(:goal_id, goal.id)
      |> Repo.insert!()

    %{goal: goal, task: task}
  end

  @doc "Builds a run request for the given goal/task with a fresh dispatch id."
  @spec run_request(Goal.t(), Task.t(), keyword()) :: RunRequest.t()
  def run_request(goal, task, overrides \\ []) do
    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: goal.id,
        task_id: task.id,
        workspace_ref: Keyword.get(overrides, :workspace_ref, "workspace/elf"),
        prompt: Keyword.get(overrides, :prompt, "Do the deterministic thing."),
        continuation: nil,
        policy: %{mode: "supervised"},
        requested_capabilities: [],
        dispatch_id: Keyword.get(overrides, :dispatch_id, Ecto.UUID.generate()),
        extensions: %{}
      })

    request
  end

  @doc "The Fake adapter identity (schema-compatible with run requests)."
  @spec fake_identity() :: Identity.t()
  def fake_identity, do: Fake.identity()

  @doc "Counts trajectory events of the given types for a run."
  @spec count_events(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: non_neg_integer()
  def count_events(goal_id, run_id, types) do
    Repo.aggregate(
      from(event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.run_id == ^run_id and
            event.type in ^types
      ),
      :count
    )
  end

  @doc "Fetches the latest terminal event for a run, if any."
  @spec terminal_event(Ecto.UUID.t(), Ecto.UUID.t()) :: TrajectoryEvent.t() | nil
  def terminal_event(goal_id, run_id) do
    Repo.one(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.run_id == ^run_id and
            event.type in ["run.completed", "run.failed", "run.cancelled"],
        order_by: [desc: event.sequence],
        limit: 1
    )
  end

  @doc "Polls until `fun` returns a truthy value or the timeout lapses."
  @spec wait_until((-> term()), pos_integer()) :: {:ok, term()} | {:error, :timeout}
  def wait_until(fun, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        {:ok, result}

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(20)
          poll_until(fun, deadline)
        end
    end
  end

  @doc "Pids currently in the process group (via pgrep; `[]` when none)."
  @spec group_members(pos_integer()) :: [pos_integer()]
  def group_members(pgid) do
    case System.cmd("pgrep", ["-g", to_string(pgid)], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Integer.parse(String.trim(line)) do
            {pid, _rest} -> [pid]
            :error -> []
          end
        end)

      {_output, _status} ->
        []
    end
  end

  @doc "Best-effort cleanup of a process group (test teardown safety net)."
  @spec cleanup_group(pos_integer() | nil) :: :ok
  def cleanup_group(nil), do: :ok

  def cleanup_group(pgid) when is_integer(pgid) and pgid > 1 do
    _ = System.cmd("kill", ["-KILL", "-#{pgid}"], stderr_to_stdout: true)
    :ok
  end

  @doc "Reads the recorded pgid from the run.running event, if any."
  @spec recorded_pgid(Ecto.UUID.t(), Ecto.UUID.t()) :: pos_integer() | nil
  def recorded_pgid(goal_id, run_id) do
    query =
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.run_id == ^run_id and
            event.type == "run.running",
        order_by: [desc: event.sequence],
        limit: 1,
        select: event.payload

    case Repo.one(query) do
      %{"process_id" => "pgid:" <> rest} ->
        case Integer.parse(rest) do
          {pgid, _rest} when pgid > 1 -> pgid
          _other -> nil
        end

      _other ->
        nil
    end
  end

  @doc "Looks up the run id for a dispatch id."
  @spec run_id_for_dispatch(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def run_id_for_dispatch(dispatch_id) do
    case Repo.get_by(Shoestring.Harness.RunRecord, dispatch_id: dispatch_id) do
      %Shoestring.Harness.RunRecord{id: run_id} -> run_id
      nil -> nil
    end
  end

  @doc "Builds a custom scenario struct with explicit event specs."
  @spec custom_scenario(atom(), [map()], keyword()) :: Scenario.t()
  def custom_scenario(name, events, opts \\ []) do
    %Scenario{
      name: name,
      capacity: nil,
      start_error: Keyword.get(opts, :start_error),
      resume_error: nil,
      provider_session_id: Keyword.get(opts, :provider_session_id, "fake-session-#{name}"),
      events: events,
      delivery_modifier: :none
    }
  end
end
