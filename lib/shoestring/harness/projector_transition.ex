defmodule Shoestring.Harness.ProjectorTransition do
  @moduledoc "Pure projection of normalized harness lifecycle events."

  alias Shoestring.Harness.{LeaseStateMachine, RunStateMachine}
  alias Shoestring.Trajectory.TrajectoryEvent

  @type state :: %{
          runs: %{optional(String.t()) => map()},
          leases: %{optional(String.t()) => map()},
          checkpoints: %{optional(String.t()) => map()},
          capacity_snapshots: %{optional(String.t()) => map()}
        }

  @spec initial_state() :: state()
  def initial_state, do: %{runs: %{}, leases: %{}, checkpoints: %{}, capacity_snapshots: %{}}

  @spec apply(state(), TrajectoryEvent.t()) :: {:ok, state()} | {:error, term()}
  def apply(state, %TrajectoryEvent{type: type} = event) do
    case action(type) do
      {:run, run_action} -> project_run(state, event, run_action)
      {:lease, lease_action} -> project_lease(state, event, lease_action)
      :checkpoint -> project_checkpoint(state, event)
      :capacity_snapshot -> project_capacity_snapshot(state, event)
      :ignore -> {:ok, state}
    end
  end

  @spec action(String.t()) ::
          {:run, atom()} | {:lease, atom()} | :checkpoint | :capacity_snapshot | :ignore
  def action("run.requested"), do: {:run, :request}
  def action("run.starting"), do: {:run, :begin}
  def action("run.running"), do: {:run, :started}
  def action("run.pausing"), do: {:run, :pause}
  def action("run.suspended"), do: {:run, :suspend}
  def action("run.completed"), do: {:run, :complete}
  def action("run.failed"), do: {:run, :fail}
  def action("run.cancelling"), do: {:run, :cancel}
  def action("run.cancelled"), do: {:run, :cancelled}
  def action("lease.proposed"), do: {:lease, :propose}
  def action("lease.granted"), do: {:lease, :grant}
  def action("lease.active"), do: {:lease, :activate}
  def action("lease.renewal_due"), do: {:lease, :renewal_due}
  def action("lease.renewed"), do: {:lease, :renew}
  def action("lease.expired"), do: {:lease, :expire}
  def action("lease.revoked"), do: {:lease, :revoke}
  def action("lease.checkpoint_required"), do: {:lease, :require_checkpoint}
  def action("checkpoint.created"), do: :checkpoint
  def action("capacity.snapshot_observed"), do: :capacity_snapshot
  def action(_type), do: :ignore

  defp project_run(state, event, :request) do
    run_id = Map.fetch!(event.payload, "run_id")

    with :ok <- matching_run_id(event, run_id),
         {:ok, transition} <- RunStateMachine.transition(:requested, :request) do
      {:ok,
       put_in(state, [:runs, run_id], %{
         status: transition.state,
         provider_session_id: Map.get(event.payload, "provider_session_id")
       })}
    end
  end

  defp project_run(state, event, action) do
    run_id = Map.fetch!(event.payload, "run_id")

    with :ok <- matching_run_id(event, run_id),
         {:ok, run} <- fetch(state.runs, run_id, :run_not_found),
         {:ok, transition} <- RunStateMachine.transition(run.status, action) do
      session_id = Map.get(event.payload, "provider_session_id") || run.provider_session_id

      {:ok,
       put_in(state, [:runs, run_id], %{
         run
         | status: transition.state,
           provider_session_id: session_id
       })}
    end
  end

  defp project_lease(state, event, :propose) do
    grant_id = Map.fetch!(event.payload, "grant_id")
    run_id = Map.fetch!(event.payload, "run_id")

    with :ok <- matching_run_id(event, run_id),
         {:ok, _run} <- fetch(state.runs, run_id, :run_not_found),
         {:ok, transition} <- LeaseStateMachine.transition(:proposed, :propose) do
      {:ok, put_in(state, [:leases, grant_id], %{status: transition.state, run_id: run_id})}
    end
  end

  defp project_lease(state, event, action) do
    grant_id = Map.fetch!(event.payload, "grant_id")

    with {:ok, lease} <- fetch(state.leases, grant_id, :lease_not_found),
         {:ok, transition} <- LeaseStateMachine.transition(lease.status, action) do
      {:ok, put_in(state, [:leases, grant_id], %{lease | status: transition.state})}
    end
  end

  defp project_checkpoint(state, event) do
    run_id = Map.fetch!(event.payload, "run_id")
    checkpoint_id = Map.fetch!(event.payload, "checkpoint_id")

    with :ok <- matching_run_id(event, run_id),
         {:ok, _run} <- fetch(state.runs, run_id, :run_not_found) do
      {:ok,
       put_in(state, [:checkpoints, checkpoint_id], %{
         run_id: run_id,
         stop_reason: Map.fetch!(event.payload, "stop_reason")
       })}
    end
  end

  defp project_capacity_snapshot(state, event) do
    snapshot_id = Map.fetch!(event.payload, "snapshot_id")
    run_id = Map.get(event.payload, "run_id")

    with :ok <- optional_matching_run_id(event, run_id),
         :ok <- optional_run_exists(state, run_id) do
      {:ok,
       put_in(state, [:capacity_snapshots, snapshot_id], %{
         run_id: run_id,
         capacity_state: Map.fetch!(event.payload, "capacity_state")
       })}
    end
  end

  defp matching_run_id(%TrajectoryEvent{run_id: nil}, _payload_run_id), do: :ok
  defp matching_run_id(%TrajectoryEvent{run_id: run_id}, run_id), do: :ok
  defp matching_run_id(%TrajectoryEvent{}, _payload_run_id), do: {:error, {:run_id_mismatch}}

  defp optional_matching_run_id(_event, nil), do: :ok
  defp optional_matching_run_id(event, run_id), do: matching_run_id(event, run_id)

  defp optional_run_exists(_state, nil), do: :ok

  defp optional_run_exists(state, run_id),
    do: fetch(state.runs, run_id, :run_not_found) |> then(&match_result/1)

  defp match_result({:ok, _value}), do: :ok
  defp match_result(error), do: error

  defp fetch(map, key, error) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {error, key}}
    end
  end
end
