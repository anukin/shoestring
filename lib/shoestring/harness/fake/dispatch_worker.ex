defmodule Shoestring.Harness.Fake.DispatchWorker do
  @moduledoc """
  Oban worker for fake harness dispatch.

  Drives the fake adapter through the durable delivery boundary so that retry,
  cancellation, and duplicate-delivery behavior can be exercised in deterministic
  test mode via `Oban.Testing.perform_job/2`.

  ## Job args

    - `dispatch_id` (required) — durable, unique dispatch identifier
    - `goal_id`      (required) — goal owning this run
    - `run_id`       (required) — pre-allocated run ID
    - `adapter`      (required) — module atom for the harness adapter, e.g. `"Elixir.Shoestring.Harness.Fake"`
    - `is_resume`    (optional) — boolean, defaults to false
    - `scenario_name` (optional) — atom name of a pre-built Fake scenario

  ## Idempotency

  Before starting or resuming the adapter, the worker checks whether the
  `dispatch_id` already has a matching `run.running` or terminal event. If
  so it returns `:ok` without repeating the external effect. This implements
  the plan's requirement: "a worker reconciles that identifier and current
  trajectory state before repeating an external side effect."
  """

  use Oban.Worker, queue: :fake_dispatch, max_attempts: 3

  import Ecto.Query

  alias Shoestring.Harness.{Clock, Error, RunRecord}
  alias Shoestring.Harness.Fake
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Trajectory

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    dispatch_id = Map.fetch!(args, "dispatch_id")
    goal_id = Map.fetch!(args, "goal_id")
    run_id = Map.fetch!(args, "run_id")

    case reconcile(dispatch_id, goal_id) do
      :already_dispatched ->
        :ok

      :not_yet_dispatched ->
        do_dispatch(args, dispatch_id, goal_id, run_id)
    end
  end

  # -- Private helpers --

  defp reconcile(dispatch_id, goal_id) do
    run =
      Repo.one(
        from r in RunRecord,
          where: r.dispatch_id == ^dispatch_id and r.goal_id == ^goal_id
      )

    case run do
      nil ->
        :not_yet_dispatched

      %RunRecord{status: status} when status in ["running", "completed", "failed", "cancelled"] ->
        :already_dispatched

      %RunRecord{} ->
        :not_yet_dispatched
    end
  end

  defp do_dispatch(args, dispatch_id, goal_id, run_id) do
    adapter = resolve_adapter(args)
    is_resume = Map.get(args, "is_resume", false)
    clock = Map.get(args, "clock_module") |> resolve_clock()
    scenario = build_scenario(args, clock)
    opts = %{scenario: scenario, clock: clock}

    result =
      if is_resume do
        prior = build_run_identity(run_id, adapter)
        request = build_run_request(args, dispatch_id, goal_id)
        adapter.resume(prior, request, opts)
      else
        request = build_run_request(args, dispatch_id, goal_id)
        adapter.start(request, opts)
      end

    case result do
      {:ok, run_identity} ->
        append_running_event(goal_id, run_id, run_identity, clock)
        :ok

      {:error, %Error{} = error} ->
        append_failed_event(goal_id, run_id, error, clock)
        {:discard, "adapter #{inspect(error.category)}: #{error.code}"}
    end
  end

  defp resolve_adapter(%{"adapter" => module_string}) do
    String.to_existing_atom(module_string)
  rescue
    ArgumentError -> Fake
  end

  defp resolve_adapter(_args), do: Fake

  defp resolve_clock(nil), do: Shoestring.Harness.SystemClock
  defp resolve_clock(module) when is_binary(module), do: String.to_existing_atom(module)
  defp resolve_clock(module) when is_atom(module), do: module

  defp build_scenario(%{"scenario_name" => name}, now_dt) when is_binary(name) do
    scenario_name = String.to_existing_atom(name)
    apply(Scenario, scenario_name, [[now: Clock.now(now_dt)]])
  rescue
    _ -> Scenario.normal_completion()
  end

  defp build_scenario(_args, now_dt) do
    Scenario.normal_completion(now: Clock.now(now_dt))
  end

  defp build_run_identity(run_id, adapter) do
    %Shoestring.Harness.RunIdentity{
      run_id: run_id,
      harness_id: adapter.identity().adapter_id,
      process_id: nil,
      provider_session_id: nil
    }
  end

  defp build_run_request(args, dispatch_id, goal_id) do
    task_id = Map.get(args, "task_id", goal_id)
    workspace_ref = Map.get(args, "workspace_ref", "workspace/fake")
    prompt = Map.get(args, "prompt", "Fake dispatch task")

    {:ok, request} =
      Shoestring.Harness.RunRequest.new(%{
        version: 1,
        goal_id: goal_id,
        task_id: task_id,
        workspace_ref: workspace_ref,
        prompt: prompt,
        continuation: nil,
        policy: %{mode: "supervised"},
        requested_capabilities: [],
        dispatch_id: dispatch_id,
        extensions: %{}
      })

    request
  end

  defp append_running_event(goal_id, run_id, run_identity, clock) do
    now = Clock.now(clock)

    Trajectory.append(
      goal_id,
      %{
        "type" => "run.starting",
        "schema_version" => 1,
        "actor" => "fake_dispatch_worker",
        "occurred_at" => now,
        "payload" => %{"run_id" => run_id}
      },
      trusted: [run_id: run_id]
    )

    Trajectory.append(
      goal_id,
      %{
        "type" => "run.running",
        "schema_version" => 1,
        "actor" => "fake_dispatch_worker",
        "occurred_at" => now,
        "payload" => %{
          "run_id" => run_id,
          "provider_session_id" => run_identity.provider_session_id,
          "process_id" => run_identity.process_id
        }
      },
      trusted: [run_id: run_id]
    )
  end

  defp append_failed_event(goal_id, run_id, error, clock) do
    now = Clock.now(clock)

    Trajectory.append(
      goal_id,
      %{
        "type" => "run.failed",
        "schema_version" => 1,
        "actor" => "fake_dispatch_worker",
        "occurred_at" => now,
        "payload" => %{
          "run_id" => run_id,
          "error_category" => Atom.to_string(error.category),
          "error_code" => error.code
        }
      },
      trusted: [run_id: run_id]
    )
  end
end
