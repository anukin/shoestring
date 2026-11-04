defmodule Shoestring.Cobbler.Parallelism do
  @moduledoc """
  How many IMPLEMENT tasks may run at once (iteration 16 C2): the person's
  Settings value, turned into iteration 7's reservation policy.

  At 1 (the default) nothing changes: no policy, no fan-out, every task
  sequential, and separate dispatches run one after another behind the single
  global task claim. At N >= 2 the global, provider-account and goal limits
  are N, each task weighs one unit of N, and fan-out is on, so a plan's
  independent tasks (a batch IMPLEMENT dispatch, or a `shoestring do` plan
  whose tasks declare separate files) may run together, each in its own
  worktree. At N >= 2 a separate single-task dispatch also claims through its
  own reservation instead of the global claim (iteration 18), so separate
  dispatches run side by side up to N, unless their files overlap.

  Trusted application configuration (`:plan_fanout`, `:plan_reservation_policy`)
  still takes precedence, as tests and iteration 7 use it. The value may not
  change while any work holds a reservation or claim, or while any execution
  has a task whose run ended but whose checks, review or retry have not been
  decided: the same policy must govern every held reservation.
  """
  import Ecto.Query

  alias Shoestring.AgentProfiles
  alias Shoestring.Cobbler.{Commands, PlanExecutor, PlanIndependence, Plans}
  alias Shoestring.Cobbler.{ReservationPolicy, Reservations}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  @max 8

  def max, do: @max

  @doc "The Settings value, 1 when it cannot be read."
  def tasks do
    AgentProfiles.settings().parallel_tasks || 1
  rescue
    _ -> 1
  end

  @doc "The reservation policy to use, or nil for the sequential path."
  def policy do
    case Application.get_env(:shoestring, :plan_reservation_policy) do
      nil -> policy(tasks())
      configured -> configured
    end
  end

  def policy(n) when is_integer(n) and n >= 2,
    do: %{
      "version" => 1,
      "global_limit" => n,
      "provider_account_limit" => n,
      "goal_limit" => n,
      "account_units" => n,
      "task_units" => 1
    }

  def policy(_n), do: nil

  @doc "Whether the fan-out driver may run."
  def fanout? do
    case Application.get_env(:shoestring, :plan_fanout) do
      nil -> tasks() >= 2
      config -> Keyword.get(config, :enabled, false) == true or tasks() >= 2
    end
  end

  @doc """
  Whether any work holds a reservation or the task claim now, or any
  execution has an unresolved task: a run that ended but whose checks,
  review or retry are still to come holds neither for a moment, and the
  setting must not change under it.
  """
  def busy? do
    Reservations.outstanding() != [] or Commands.active_claim() != nil or
      unresolved_execution?()
  end

  @doc """
  Whether a new task for `goal_id` on `provider`/`scope` must wait because
  the place it would run in is taken. `goal_id` nil counts every claim,
  as a planner's admission does.

  With no policy (parallel tasks 1) this is exactly the single-claim answer:
  another goal holds the global task claim. With a policy it is true when
  another goal holds the legacy claim, the global or provider-account
  reservation limit is full, or (given `task:` and `repository:`) another
  running goal in the same repository has files that overlap this task's,
  touches a shared file, or declared none.

  `legacy_claim: true` is for callers that will then take the global claim
  themselves (the planner): while any reservation is outstanding that claim
  is refused, so they wait for it too.
  """
  def occupied?(goal_id, provider, scope, opts \\ []),
    do: occupancy(goal_id, provider, scope, opts) != nil

  @doc """
  `occupied?/4` with its reason: nil, or a map with `"reason"`
  (`"claim"`, `"slots_full"` or `"files_overlap"`), `"running"` (the
  reservations outstanding) and `"limit"` (the global limit; nil at 1).
  """
  def occupancy(goal_id, provider, scope, opts \\ []) do
    claim = Commands.active_claim()
    foreign_claim? = claim != nil and (is_nil(goal_id) or claim.goal_id != goal_id)

    case current_policy() do
      nil ->
        if foreign_claim?, do: %{"reason" => "claim", "running" => 1, "limit" => nil}

      policy ->
        held = Reservations.outstanding()
        running = length(held)
        wait = &%{"reason" => &1, "running" => running, "limit" => policy.global_limit}

        account =
          Enum.count(held, &(&1.provider_id == to_string(provider) and &1.scope == scope))

        cond do
          foreign_claim? -> wait.("claim")
          Keyword.get(opts, :legacy_claim, false) and held != [] -> wait.("slots_full")
          running >= policy.global_limit -> wait.("slots_full")
          account >= policy.provider_account_limit -> wait.("slots_full")
          overlaps?(held, goal_id, opts) -> wait.("files_overlap")
          true -> nil
        end
    end
  end

  @doc """
  Whether every place is taken now (only with a policy): a held usage
  confirmation spent while no task can start would be spent for nothing.
  """
  def slots_full?(provider, scope) do
    case current_policy() do
      nil ->
        false

      policy ->
        held = Reservations.outstanding()

        length(held) >= policy.global_limit or
          Enum.count(held, &(&1.provider_id == to_string(provider) and &1.scope == scope)) >=
            policy.provider_account_limit
    end
  end

  # Only the person's Settings value lets separate dispatches share places:
  # trusted configuration at 1 (iteration 7's interlock) keeps the claim.
  defp current_policy do
    case tasks() >= 2 && policy() do
      falsy when falsy in [nil, false] ->
        nil

      %ReservationPolicy{} = policy ->
        policy

      values ->
        case ReservationPolicy.new(values) do
          {:ok, policy} -> policy
          _ -> nil
        end
    end
  end

  # Another goal's dispatch in the same repository must name files with
  # `--file`, and so must this one, and none may overlap or be shared:
  # otherwise this one waits rather than risk two workers changing the same
  # file. A goal whose repository cannot be read is not compared.
  defp overlaps?(held, goal_id, opts) do
    with %{} = task <- Keyword.get(opts, :task),
         repository when is_binary(repository) <- Keyword.get(opts, :repository) do
      mine = files(task)
      repository = Path.expand(repository)

      held
      |> Enum.reject(&(&1.goal_id == goal_id))
      |> Enum.any?(fn owner ->
        case running_task(owner) do
          {^repository, theirs} -> conflict?(mine, theirs)
          _ -> false
        end
      end)
    else
      _ -> false
    end
  end

  defp conflict?(mine, theirs) do
    mine == [] or theirs == [] or Enum.any?(mine ++ theirs, &PlanIndependence.shared?/1) or
      Enum.any?(mine, fn left -> Enum.any?(theirs, &PlanIndependence.overlap?(left, &1)) end)
  end

  defp files(task), do: get_in(task, ["hints", "files"]) || []

  defp running_task(owner) do
    tasks = fn revision -> revision.content["tasks"] || [] end

    with %{revision: revision} <- Plans.authority(owner.goal_id),
         %{} = task <- Enum.find(tasks.(revision), &(&1["id"] == owner.plan_task_id)),
         repository when is_binary(repository) <- repository(owner) do
      {Path.expand(repository), files(task)}
    else
      _ -> nil
    end
  end

  defp repository(owner) do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^owner.goal_id and e.type == "cobbler.plan.execution.requested",
        order_by: [desc: e.sequence],
        select: e.payload
    )
    |> Enum.find_value(fn payload ->
      if payload["execution_id"] == owner.execution_id, do: payload["repository_path"]
    end)
  end

  defp unresolved_execution? do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.type == "cobbler.plan.task.dispatched",
        distinct: true,
        select: e.goal_id
    )
    |> Enum.any?(fn goal_id ->
      case PlanExecutor.status(goal_id) do
        {:ok, %{planned?: true, completed?: false, cancelled?: false} = status} ->
          status.active_children != [] or retry_pending?(status)

        _ ->
          false
      end
    end)
  end

  # A failed attempt whose retry state is `retry` comes back as a new
  # attempt; until then its task is unresolved.
  defp retry_pending?(status) do
    status.children
    |> Enum.group_by(& &1.plan_task_id)
    |> Enum.any?(fn {task_id, children} ->
      latest = Enum.max_by(children, & &1.attempt)

      task_id not in status.accepted and latest.resolved? and latest.retry_state == "retry"
    end)
  end
end
