defmodule ShoestringWeb.RunShowLive do
  use ShoestringWeb, :live_view

  alias Shoestring.Elves
  alias Shoestring.Elves.PortRunner
  alias Shoestring.Harness.{CapacityObservatory, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{ArtifactStore, Goal, Task, TrajectoryEvent}
  alias Shoestring.Worktrees
  alias ShoestringWeb.RunPresentation
  require Logger

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    socket = assign_new(socket, :current_scope, fn -> nil end)

    case Ecto.UUID.cast(run_id) do
      {:ok, _uuid} ->
        case Repo.get(RunRecord, run_id) do
          nil ->
            {:ok,
             socket
             |> assign(:page_title, "Run Not Found")
             |> assign(:run_not_found?, true)
             |> assign(:run_id, run_id)}

          %RunRecord{} = run ->
            goal = Repo.get(Goal, run.goal_id)
            task = Repo.get(Task, run.task_id)

            socket =
              if connected?(socket) and goal do
                Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(goal.id))
                socket
              else
                socket
              end

            {:ok,
             socket
             |> assign(:page_title, "Manual Run #{String.slice(run.id, 0, 8)}")
             |> assign(:run_not_found?, false)
             |> assign(:run, run)
             |> assign(:goal, goal)
             |> assign(:task, task)
             |> load_run_details(run, goal)}
        end

      :error ->
        {:ok,
         socket
         |> assign(:page_title, "Run Not Found")
         |> assign(:run_not_found?, true)
         |> assign(:run_id, run_id)}
    end
  end

  @impl true
  def handle_event("cancel_run", _params, socket) do
    run = socket.assigns.run

    case Elves.cancel_run(run.id) do
      {:ok, :cancelled} ->
        {:noreply,
         socket
         |> put_flash(:info, "Run cancellation requested.")
         |> reload_run_state()}

      {:ok, :already_terminal} ->
        {:noreply,
         socket
         |> put_flash(:info, "Run is already terminal.")
         |> reload_run_state()}

      {:error, reason} ->
        Logger.warning("Failed to cancel run: #{inspect(reason)}")

        {:noreply, put_flash(socket, :error, "Failed to cancel run. Please retry.")}
    end
  end

  @impl true
  def handle_event("request_stop", _params, socket) do
    run = socket.assigns.run

    case Elves.request_stop(run.id) do
      {:ok, :stop_requested} ->
        {:noreply,
         socket
         |> put_flash(:info, "Safe stop requested at next boundary.")
         |> reload_run_state()}

      {:ok, :already_terminal} ->
        {:noreply,
         socket
         |> put_flash(:info, "Run is already terminal.")
         |> reload_run_state()}

      {:error, :session_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "No active session found to receive safe stop.")}

      {:error, reason} ->
        Logger.warning("Failed to request safe stop: #{inspect(reason)}")

        {:noreply, put_flash(socket, :error, "Failed to request safe stop. Please retry.")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, reload_run_state(socket)}
  end

  @impl true
  def handle_info({:trajectory_event_committed, %TrajectoryEvent{} = event}, socket) do
    case {socket.assigns[:goal], socket.assigns[:run]} do
      {%{id: goal_id}, %{id: run_id}}
      when is_binary(goal_id) and is_binary(run_id) ->
        if event.goal_id == goal_id and (event.run_id == run_id or is_nil(event.run_id)) do
          sanitized = RunPresentation.sanitize_event(event)
          total = (socket.assigns[:events_total] || 0) + 1
          showing = (socket.assigns[:events_showing] || 0) + 1

          socket =
            socket
            |> stream_insert(:events, sanitized)
            |> assign(:events_total, total)
            |> assign(:events_showing, showing)
            |> maybe_refresh_on_event(event)

          {:noreply, socket}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  defp reload_run_state(socket) do
    case socket.assigns[:run] do
      %{id: run_id} when is_binary(run_id) ->
        case Repo.get(RunRecord, run_id) do
          nil ->
            socket
            |> assign(:run_not_found?, true)
            |> assign(:run_id, run_id)
            |> assign(:page_title, "Run Not Found")

          run ->
            goal = Repo.get(Goal, run.goal_id)

            socket
            |> assign(:run_not_found?, false)
            |> assign(:run, run)
            |> assign(:goal, goal)
            |> load_run_details(run, goal)
        end

      _ ->
        assign(socket, :run_not_found?, true)
    end
  end

  defp maybe_refresh_on_event(socket, %TrajectoryEvent{type: type})
       when type in [
              "run.completed",
              "run.failed",
              "run.cancelled",
              "run.running",
              "run.cancelling"
            ] do
    reload_run_state(socket)
  end

  defp maybe_refresh_on_event(socket, %TrajectoryEvent{
         type: "harness.event_recorded",
         payload: %{"kind" => "artifact"}
       }) do
    reload_run_state(socket)
  end

  defp maybe_refresh_on_event(socket, _event), do: socket

  defp load_run_details(socket, run, goal) do
    events =
      if goal do
        case Trajectory.replay(goal.id) do
          {:ok, list} ->
            list
            |> Enum.filter(&(&1.run_id == run.id or is_nil(&1.run_id)))

          _ ->
            []
        end
      else
        []
      end

    sanitized_events = Enum.map(events, &RunPresentation.sanitize_event/1)
    terminal_event = find_terminal_event(events)
    sanitized_terminal = terminal_event && RunPresentation.sanitize_event(terminal_event)
    status_label = determine_status(run, terminal_event)
    pgid = extract_pgid(events)
    elf_pid = Elves.whereis(run.id)

    alive? =
      (pgid != nil and PortRunner.alive_id?(pgid)) or (elf_pid != nil and Process.alive?(elf_pid))

    worktree =
      case Worktrees.get(run.id) do
        {:ok, wt} -> wt
        _ -> nil
      end

    {worktree_diff, diff_omitted, diff_truncated?} =
      if worktree do
        diff_text =
          case Worktrees.diff(worktree) do
            {:ok, %{diff: patch}} when is_binary(patch) and patch != "" ->
              patch

            _ ->
              "No diff recorded."
          end

        # Cap AFTER redaction so truncation can never bisect a raw secret.
        RunPresentation.cap_text(diff_text)
      else
        RunPresentation.cap_text("Worktree not available.")
      end

    changed_files =
      if worktree do
        case Worktrees.changed_files(worktree) do
          {:ok, list} -> list
          _ -> []
        end
      else
        []
      end

    {logs, logs_omitted, logs_truncated?} = extract_logs(events, goal)
    capacity = load_capacity_snapshot(run.provider_id)

    {visible_events, events_total, events_showing, events_truncated?} =
      RunPresentation.window_events(sanitized_events)

    socket
    |> assign(:status, status_label)
    |> assign(:terminal_event, sanitized_terminal)
    |> assign(:pgid, pgid)
    |> assign(:elf_alive?, alive?)
    |> assign(:worktree, worktree)
    |> assign(:worktree_diff, worktree_diff)
    |> assign(:worktree_diff_omitted, diff_omitted)
    |> assign(:worktree_diff_truncated?, diff_truncated?)
    |> assign(:changed_files, changed_files)
    |> assign(:logs, logs)
    |> assign(:logs_omitted, logs_omitted)
    |> assign(:logs_truncated?, logs_truncated?)
    |> assign(:capacity, capacity)
    |> assign(:events_total, events_total)
    |> assign(:events_showing, events_showing)
    |> assign(:events_truncated?, events_truncated?)
    |> stream(:events, visible_events, reset: true, dom_id: &event_dom_id/1)
  end

  defp find_terminal_event(events) do
    events
    |> Enum.reverse()
    |> Enum.find(&(&1.type in ["run.completed", "run.failed", "run.cancelled"]))
  end

  defp determine_status(_run, %TrajectoryEvent{type: "run.completed"}), do: "completed"
  defp determine_status(_run, %TrajectoryEvent{type: "run.cancelled"}), do: "cancelled"
  defp determine_status(_run, %TrajectoryEvent{type: "run.failed"}), do: "failed"
  defp determine_status(run, _), do: run.status || "requested"

  defp extract_pgid(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(nil, fn
      %TrajectoryEvent{type: "run.running", payload: %{"process_id" => "pgid:" <> rest}} ->
        case Integer.parse(rest) do
          {n, _} -> n
          _ -> nil
        end

      %TrajectoryEvent{type: "run.running", payload: %{"process_id" => id}} when is_binary(id) ->
        case Integer.parse(id) do
          {n, _} -> n
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp extract_logs(events, goal) do
    log_artifact_id =
      events
      |> Enum.reverse()
      |> Enum.find_value(nil, fn
        %TrajectoryEvent{
          type: "harness.event_recorded",
          payload: %{
            "kind" => "artifact",
            "artifact_id" => artifact_id,
            "source_event_id" => "elf-log:" <> _
          }
        }
        when is_binary(artifact_id) ->
          artifact_id

        _ ->
          nil
      end)

    if log_artifact_id && goal do
      case ArtifactStore.read(log_artifact_id) do
        {:ok, %{bytes: bytes}} ->
          # Cap AFTER redaction so truncation can never bisect a raw secret.
          RunPresentation.cap_text(bytes)

        _ ->
          RunPresentation.cap_text("Log artifact #{log_artifact_id} could not be loaded.")
      end
    else
      RunPresentation.cap_text("No log artifact recorded for this run.")
    end
  end

  defp load_capacity_snapshot(provider_id) when is_binary(provider_id) do
    case CapacityObservatory.latest_observation(provider_id, "app_server_stdio", "account") do
      {:ok, snapshot} -> snapshot
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp load_capacity_snapshot(_), do: nil

  defp event_dom_id(%TrajectoryEvent{id: id}), do: "run-event-#{id}"

  defp format_occurred_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_occurred_at(other), do: to_string(other)
end
