defmodule ShoestringWeb.CobblerDashboardLive do
  @moduledoc """
  Read-only Cobbler dashboard: one row per quota-aware goal with its
  presentational lifecycle state.

  All data comes from read-only calls (`Repo` reads,
  `Cobbler.list_commands/2`, `Cobbler.active_claim/1`,
  `Trajectory.replay/1`). The only event is `refresh`, which re-reads.
  Nothing here writes, spawns, or enqueues.
  """

  use ShoestringWeb, :live_view

  import Ecto.Query

  alias Shoestring.Cobbler
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.Goal
  alias ShoestringWeb.CobblerPresentation
  alias ShoestringWeb.RunPresentation

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_scope, fn -> nil end)
    {:ok, load_goals(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_goals(socket)}
  end

  defp load_goals(socket) do
    goals = list_goals(socket.assigns.current_scope)
    claim = safe_active_claim()

    summaries =
      goals
      |> Enum.map(&goal_summary(&1, claim))
      |> Enum.sort_by(& &1.title)

    socket
    |> assign(:page_title, "Cobbler Goals")
    |> assign(:goals_empty?, summaries == [])
    |> stream(:goals, summaries, reset: true, dom_id: &goal_dom_id/1)
  end

  defp goal_dom_id(%{id: id}), do: "cobbler-goal-#{id}"

  # Local mode (nil scope) lists every non-observatory goal. A present
  # scope lists only goals owned by the scope owner; a scope without an
  # owner sees nothing. The protected observatory goal is never listed.
  defp list_goals(nil) do
    Repo.all(from goal in Goal.user_goals(), order_by: [desc: goal.inserted_at])
  rescue
    _error -> []
  end

  defp list_goals(scope) do
    case scope_owner_id(scope) do
      {:ok, owner_id} ->
        Repo.all(
          from goal in Goal.user_goals(),
            where: goal.owner_id == ^owner_id,
            order_by: [desc: goal.inserted_at]
        )

      :error ->
        []
    end
  rescue
    _error -> []
  end

  defp scope_owner_id(scope) when is_map(scope) do
    scope_user = Map.get(scope, :user) || Map.get(scope, "user")

    owner_id =
      case scope_user do
        user when is_map(user) -> Map.get(user, :id) || Map.get(user, "id")
        _other -> Map.get(scope, :user_id) || Map.get(scope, "user_id")
      end

    case Ecto.UUID.cast(owner_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp scope_owner_id(_scope), do: :error

  defp goal_summary(%Goal{} = goal, claim) do
    events = replay_events(goal.id)
    decision_results = admission_results(events)
    commands = safe_list_commands(goal.id)

    state = CobblerPresentation.derive_goal_state(events)

    %{
      id: goal.id,
      title: RunPresentation.redact_text(goal.title || "Untitled goal"),
      owner_id: goal.owner_id,
      lifecycle_state: state,
      presentation: CobblerPresentation.lifecycle_presentation(state),
      latest_result: List.last(decision_results),
      commands_count: length(commands),
      pending_count: Enum.count(commands, &(&1.status == "needs_user")),
      claim_held?: is_map(claim) and claim.goal_id == goal.id
    }
  end

  defp admission_results(events) when is_list(events) do
    events
    |> Enum.filter(&(&1.type == "admission.decided"))
    |> Enum.map(&decision_result/1)
  end

  defp replay_events(goal_id) do
    case Trajectory.replay(goal_id) do
      {:ok, events} -> events
      {:error, _reason} -> []
    end
  rescue
    _error -> []
  end

  defp decision_result(%{payload: %{"result" => result}}), do: result
  defp decision_result(_event), do: :unknown_result

  defp safe_list_commands(goal_id) do
    Cobbler.list_commands(goal_id)
  rescue
    _error -> []
  end

  defp safe_active_claim do
    Cobbler.active_claim()
  rescue
    _error -> nil
  end
end
