defmodule ShoestringWeb.CobblerGoalLive do
  @moduledoc """
  Per-goal Cobbler explanation page: admission decision, lease, checkpoint,
  claim, sleep honesty, commands, and events.

  Every event is read-only (`refresh`, `rebuild`) except `respond`, the
  single operator confirm/respond form, which delegates to
  `Cobbler.respond_command/4` after enforcing an attributable
  `confirmed_by` identity and a matching intent confirmation at the UI
  boundary. Unattributed or mismatched confirmations are rejected with an
  error flash and change nothing.
  """

  use ShoestringWeb, :live_view

  import Ecto.Query

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.AdmissionDecision
  alias Shoestring.Harness.{CheckpointRecord, ExecutionLeaseRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, ProjectorPosition, TrajectoryEvent}
  alias ShoestringWeb.CobblerPresentation
  alias ShoestringWeb.RunPresentation

  require Logger

  @projector "goal_task"

  @impl true
  def mount(%{"goal_id" => raw_goal_id}, _session, socket) do
    socket = assign_new(socket, :current_scope, fn -> nil end)
    socket = subscribe_when_connected(socket, raw_goal_id)
    {:ok, load_goal(socket, raw_goal_id)}
  end

  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_scope, fn -> nil end)
    {:ok, error_state(socket, nil, "Goal unavailable.")}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, reload(socket)}
  end

  @impl true
  def handle_event("rebuild", _params, socket) do
    {:noreply, reload(socket)}
  end

  @impl true
  def handle_event("validate", %{"response" => response_params}, socket) do
    command_id = response_params["command_id"]

    {:noreply,
     assign(
       socket,
       :respond_forms,
       Map.put(socket.assigns.respond_forms, command_id, to_form(response_params, as: :response))
     )}
  end

  @impl true
  def handle_event("respond", %{"response" => response_params}, socket) do
    {:noreply, do_respond(socket, response_params)}
  end

  @impl true
  def handle_info({:trajectory_event_committed, %TrajectoryEvent{goal_id: goal_id}}, socket) do
    if socket.assigns.goal_id == goal_id do
      {:noreply, reload(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:trajectory_projection_updated, goal_id, _sequence}, socket) do
    if socket.assigns.goal_id == goal_id do
      {:noreply, reload(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @doc "Authorizes local mode or an explicit scope owner for a goal (mirrors the timeline owner check)."
  @spec authorized_goal?(Goal.t(), nil | map() | term()) :: boolean()
  def authorized_goal?(%Goal{} = goal, nil) do
    not Goal.observatory?(goal)
  end

  def authorized_goal?(%Goal{} = goal, scope) when is_map(scope) do
    if Goal.observatory?(goal) do
      false
    else
      case scope_owner_id(scope) do
        owner_id when is_binary(owner_id) ->
          with {:ok, scope_owner_id} <- Ecto.UUID.cast(owner_id),
               {:ok, goal_owner_id} <- Ecto.UUID.cast(goal.owner_id) do
            scope_owner_id == goal_owner_id
          else
            _error -> false
          end

        _missing_owner ->
          false
      end
    end
  end

  def authorized_goal?(_goal, _scope), do: false

  defp scope_owner_id(scope) do
    scope_user = Map.get(scope, :user) || Map.get(scope, "user")

    case scope_user do
      user when is_map(user) -> Map.get(user, :id) || Map.get(user, "id")
      _other -> Map.get(scope, :user_id) || Map.get(scope, "user_id")
    end
  end

  defp reload(socket) do
    case socket.assigns[:goal_id] do
      goal_id when is_binary(goal_id) -> load_goal(socket, goal_id)
      _other -> socket
    end
  end

  defp load_goal(socket, raw_goal_id) do
    socket = assign(socket, :goal_id, raw_goal_id)

    case Ecto.UUID.cast(raw_goal_id) do
      {:ok, goal_id} ->
        case Repo.get(Goal, goal_id) do
          nil ->
            error_state(socket, nil, "Goal unavailable.")

          %Goal{} = goal ->
            if authorized_goal?(goal, socket.assigns.current_scope) do
              load_detail(socket, goal)
            else
              error_state(socket, nil, "Goal unavailable.")
            end
        end

      :error ->
        error_state(socket, nil, "Goal unavailable.")
    end
  end

  defp error_state(socket, goal, message) do
    socket
    |> assign(:goal, goal)
    |> assign(:page_title, "Cobbler Goal")
    |> assign(:goal_error, message)
    |> assign(:lifecycle_state, :unknown)
    |> assign(:lifecycle_presentation, CobblerPresentation.lifecycle_presentation(:unknown))
    |> assign(:decisions, [])
    |> assign(:latest_decision, nil)
    |> assign(:handoffs, [])
    |> assign(:latest_handoff, nil)
    |> assign(:lease, nil)
    |> assign(:checkpoint, nil)
    |> assign(:checkpoint_text, "")
    |> assign(:claim, nil)
    |> assign(:claim_mine?, false)
    |> assign(:projection, %{status: "not_projected", error_detail: nil})
    |> assign(:rebuild, %{consistent?: true, divergences: [], error: nil})
    |> assign(:warnings, [])
    |> assign(:commands_empty?, true)
    |> assign(:respond_forms, %{})
    |> stream(:commands, [], reset: true, dom_id: &command_dom_id/1)
    |> stream(:events, [], reset: true, dom_id: &event_dom_id/1)
  end

  defp load_detail(socket, %Goal{} = goal) do
    events = safe_replay(goal.id)
    decisions = admission_decisions(events)
    latest_decision = List.last(decisions)
    commands = safe_list_commands(goal.id)
    handoffs = handoff_displays(events)

    state = CobblerPresentation.derive_goal_state(events)
    claim = safe_active_claim()
    lease = latest_lease(goal.id)
    checkpoint = latest_checkpoint(goal.id)
    position = Repo.get_by(ProjectorPosition, goal_id: goal.id, projector: @projector)
    projection = projection_state(position)
    rebuild = safe_rebuild(goal.id)
    warnings = build_warnings(latest_decision, projection, rebuild)
    sanitized_events = Enum.map(events, &RunPresentation.sanitize_event/1)

    socket
    |> assign(:goal, goal)
    |> assign(:page_title, "Cobbler Goal #{String.slice(goal.id, 0, 8)}")
    |> assign(:goal_error, nil)
    |> assign(:lifecycle_state, state)
    |> assign(:lifecycle_presentation, CobblerPresentation.lifecycle_presentation(state))
    |> assign(:decisions, decisions)
    |> assign(:latest_decision, latest_decision)
    |> assign(:handoffs, handoffs)
    |> assign(:latest_handoff, List.last(handoffs))
    |> assign(:lease, lease_display(lease))
    |> assign(:checkpoint, checkpoint_display(checkpoint))
    |> assign(:claim, claim)
    |> assign(:claim_mine?, is_map(claim) and claim.goal_id == goal.id)
    |> assign(:projection, projection)
    |> assign(:rebuild, rebuild)
    |> assign(:warnings, warnings)
    |> assign(:commands_empty?, commands == [])
    |> assign(:respond_forms, respond_forms(commands))
    |> stream(:commands, commands, reset: true, dom_id: &command_dom_id/1)
    |> stream(:events, sanitized_events, reset: true, dom_id: &event_dom_id/1)
  end

  defp do_respond(socket, response_params) do
    command_id = response_params["command_id"]
    resolution = response_params["resolution"]
    confirmed_by = response_params["confirmed_by"] |> to_string() |> String.trim()
    intent_confirm = response_params["intent"] |> to_string() |> String.trim()

    with %Goal{} = goal <- socket.assigns[:goal],
         command when not is_nil(command) <- Cobbler.command(goal.id, command_id),
         :needs_user <- command_status(command),
         :ok <- require_attribution(confirmed_by),
         :ok <- require_intent_match(command, intent_confirm) do
      case Cobbler.respond_command(goal.id, command_id, %{
             "resolution" => resolution,
             "confirmed_by" => confirmed_by,
             "intent" => intent_confirm
           }) do
        {:ok, _result} ->
          socket
          |> put_flash(
            :info,
            "Recorded operator response by '#{confirmed_by}' for command '#{command_id}'."
          )
          |> reload()

        {:error, {:invalid_response, _options}} ->
          put_flash(
            socket,
            :error,
            "That response is not offered for this command. Nothing changed."
          )

        {:error, {:response_conflict, _detail}} ->
          put_flash(socket, :error, "A different response was already recorded. Nothing changed.")

        {:error, {:illegal_respond, _detail}} ->
          put_flash(socket, :error, "This command can no longer be answered. Nothing changed.")

        {:error, {:confirmation_invalid_responder, _detail}} ->
          # Defense in depth: the boundary above already rejects blank
          # identities, but the domain is authoritative — an unattributed
          # response must never persist even if the boundary is bypassed.
          put_flash(
            socket,
            :error,
            "Confirmation requires an attributable operator identity (confirmed_by)."
          )

        {:error, reason} ->
          Logger.warning("Cobbler respond failed: #{inspect(reason)}")
          put_flash(socket, :error, "Could not record the response. Nothing changed.")
      end
    else
      nil ->
        put_flash(socket, :error, "Goal is no longer available. Please refresh the page.")

      :resolved_or_rejected ->
        put_flash(socket, :error, "This command can no longer be answered. Nothing changed.")

      {:error, :unattributed} ->
        put_flash(
          socket,
          :error,
          "Confirmation requires an attributable operator identity (confirmed_by)."
        )

      {:error, :intent_mismatch} ->
        put_flash(
          socket,
          :error,
          "Intent confirmation does not match the command intent. Nothing changed."
        )
    end
  end

  defp command_status(%{status: "needs_user"}), do: :needs_user
  defp command_status(_command), do: :resolved_or_rejected

  defp require_attribution(""), do: {:error, :unattributed}
  defp require_attribution(_confirmed_by), do: :ok

  defp require_intent_match(%{payload: %{"intent" => intent}}, intent_confirm)
       when is_binary(intent) and intent != "" do
    if intent_confirm == intent, do: :ok, else: {:error, :intent_mismatch}
  end

  defp require_intent_match(_command, _intent_confirm), do: :ok

  defp respond_forms(commands) do
    commands
    |> Enum.filter(&(&1.status == "needs_user"))
    |> Map.new(fn command ->
      options = offered_options(command)

      {command.command_id,
       to_form(
         %{
           "command_id" => command.command_id,
           "resolution" => List.first(options) || "",
           "confirmed_by" => "",
           "intent" => ""
         },
         as: :response
       )}
    end)
  end

  defp offered_options(%{result: %{"options" => options}}) when is_list(options),
    do: Enum.filter(options, &is_binary/1)

  defp offered_options(_command), do: []

  defp safe_replay(goal_id) do
    case Trajectory.replay(goal_id) do
      {:ok, events} -> events
      {:error, _reason} -> []
    end
  rescue
    _error -> []
  end

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

  defp safe_rebuild(goal_id) do
    case Cobbler.rebuild_commands(goal_id) do
      {:ok, %{consistent?: consistent?, divergences: divergences}} ->
        %{consistent?: consistent?, divergences: divergences || [], error: nil}

      {:error, reason} ->
        %{consistent?: false, divergences: [], error: inspect(reason)}
    end
  rescue
    error -> %{consistent?: false, divergences: [], error: inspect(error)}
  end

  defp admission_decisions(events) do
    events
    |> Enum.filter(&(&1.type == "admission.decided"))
    |> Enum.map(&decision_display/1)
  end

  defp decision_display(%TrajectoryEvent{} = event) do
    payload = if is_map(event.payload), do: event.payload, else: %{}
    result = Map.get(payload, "result", :unknown_result)

    decision =
      case AdmissionDecision.from_payload(payload) do
        {:ok, parsed} -> parsed
        {:error, _changeset} -> nil
      end

    %{
      event_id: event.id,
      sequence: event.sequence,
      occurred_at: event.occurred_at,
      result: result,
      presentation: CobblerPresentation.decision_presentation(result),
      decision: decision,
      reason_code: Map.get(payload, "reason_code"),
      explanation: RunPresentation.redact_text(Map.get(payload, "explanation") || ""),
      reserves: Map.get(payload, "proposed_bounds") || %{},
      defer_until: Map.get(payload, "defer_until"),
      observation: Map.get(payload, "observation") || %{},
      raw_summary:
        payload |> RunPresentation.format_payload() |> RunPresentation.cap_text() |> elem(0)
    }
  end

  # Handoff cards derive faithfully from persisted `handoff.created`
  # trajectory events (read-only). A handoff targets a NEW run of the SAME
  # goal (I5 contract): the card names the source and receiver providers,
  # the recorded reason, and the continuation pointers, all redacted for
  # display. Raw provider output is never canonical state and is not
  # shown here beyond the recorded pointers.
  defp handoff_displays(events) do
    events
    |> Enum.filter(&(&1.type == "handoff.created"))
    |> Enum.map(&handoff_display/1)
  end

  defp handoff_display(%TrajectoryEvent{} = event) do
    payload = if is_map(event.payload), do: event.payload, else: %{}

    %{
      event_id: event.id,
      sequence: event.sequence,
      occurred_at: event.occurred_at,
      source: to_string_value(Map.get(payload, "from_provider_id")),
      receiver: to_string_value(Map.get(payload, "to_provider_id")),
      reason: RunPresentation.redact_text(to_string_value(Map.get(payload, "reason"))),
      next_action: RunPresentation.redact_text(to_string_value(Map.get(payload, "next_action"))),
      prior_run_id: to_string_value(Map.get(payload, "prior_run_id")),
      run_id: to_string_value(Map.get(payload, "run_id")),
      checkpoint_id: to_string_value(Map.get(payload, "checkpoint_id")),
      decision_refs: List.wrap(Map.get(payload, "decision_refs", [])) |> Enum.filter(&is_binary/1)
    }
  end

  defp latest_lease(goal_id) do
    Repo.one(
      from lease in ExecutionLeaseRecord,
        where: lease.goal_id == ^goal_id,
        order_by: [desc: lease.inserted_at],
        limit: 1
    )
  rescue
    _error -> nil
  end

  defp lease_display(nil), do: nil

  defp lease_display(%ExecutionLeaseRecord{} = lease) do
    %{
      id: lease.id,
      status_presentation: CobblerPresentation.lease_presentation(lease.status || :unknown),
      renewal_presentation:
        CobblerPresentation.renewal_presentation(lease.renewal_state || :unknown),
      response_budget: lease.response_budget,
      tool_budget: lease.tool_budget,
      response_reserve: lease.response_reserve,
      tool_reserve: lease.tool_reserve,
      deadline: lease.deadline,
      checkpoint_cadence: lease.checkpoint_cadence
    }
  end

  defp latest_checkpoint(goal_id) do
    Repo.one(
      from checkpoint in CheckpointRecord,
        where: checkpoint.goal_id == ^goal_id,
        order_by: [desc: checkpoint.inserted_at],
        limit: 1
    )
  rescue
    _error -> nil
  end

  defp checkpoint_display(nil), do: nil

  defp checkpoint_display(%CheckpointRecord{} = checkpoint) do
    contents = %{
      "acceptance_contract" => checkpoint.acceptance_contract,
      "repository_state" => checkpoint.repository_state,
      "evidence" => checkpoint.evidence,
      "decisions" => checkpoint.decisions,
      "unresolved_issues" => checkpoint.unresolved_issues
    }

    {text, _omitted, _truncated?} =
      contents |> RunPresentation.format_payload() |> RunPresentation.cap_text()

    %{
      id: checkpoint.id,
      next_action: RunPresentation.redact_text(checkpoint.next_action || ""),
      stop_reason: RunPresentation.redact_text(checkpoint.stop_reason || ""),
      contents_text: text
    }
  end

  defp projection_state(nil), do: %{status: "not_projected", error_detail: nil}

  defp projection_state(%ProjectorPosition{status: status, error_detail: detail}) do
    error_detail =
      if status == "failed" do
        safe_error_detail(detail) || "Projection halted; rebuild required."
      end

    %{status: status || "unknown", error_detail: error_detail}
  end

  defp safe_error_detail(detail) when is_binary(detail) do
    detail
    |> Shoestring.Harness.Security.redact()
    |> String.slice(0, 240)
  end

  defp safe_error_detail(_detail), do: nil

  defp build_warnings(latest_decision, projection, rebuild) do
    []
    |> maybe_stale_warning(latest_decision)
    |> maybe_degraded_warning(latest_decision)
    |> maybe_projection_warning(projection)
    |> maybe_rebuild_warning(rebuild)
  end

  defp maybe_stale_warning(warnings, %{observation: observation}) when is_map(observation) do
    if stale_observation?(observation) do
      [
        %{
          id: "stale-observation",
          text: "Latest admission observation is stale; treat capacity as unverified."
        }
        | warnings
      ]
    else
      warnings
    end
  end

  defp maybe_stale_warning(warnings, _decision), do: warnings

  defp maybe_degraded_warning(warnings, %{observation: observation}) when is_map(observation) do
    if degraded_observation?(observation) do
      [
        %{
          id: "degraded-capacity",
          text: "Latest admission observation reports degraded capacity."
        }
        | warnings
      ]
    else
      warnings
    end
  end

  defp maybe_degraded_warning(warnings, _decision), do: warnings

  defp maybe_projection_warning(warnings, %{status: "failed", error_detail: detail}) do
    [
      %{id: "projection-failed", text: "Projection failed: #{detail || "rebuild required"}"}
      | warnings
    ]
  end

  defp maybe_projection_warning(warnings, _projection), do: warnings

  defp maybe_rebuild_warning(warnings, %{consistent?: false, divergences: divergences, error: nil}) do
    count = length(divergences || [])

    [
      %{
        id: "rebuild-diverged",
        text: "Command store diverged from canonical events (#{count} differences)."
      }
      | warnings
    ]
  end

  defp maybe_rebuild_warning(warnings, %{consistent?: false, error: error})
       when not is_nil(error) do
    [%{id: "rebuild-unverifiable", text: "Command rebuild could not be verified."} | warnings]
  end

  defp maybe_rebuild_warning(warnings, _rebuild), do: warnings

  defp stale_observation?(observation) do
    freshness =
      [Map.get(observation, "freshness"), Map.get(observation, "freshness_state")]
      |> Enum.map(&to_string_value/1)

    Enum.any?(freshness, &(&1 in ["stale", "expired"]))
  end

  defp degraded_observation?(observation) do
    state =
      [Map.get(observation, "capacity_state"), Map.get(observation, "state")]
      |> Enum.map(&to_string_value/1)

    Enum.any?(state, &(&1 == "degraded"))
  end

  defp to_string_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(_value), do: ""

  defp subscribe_when_connected(socket, raw_goal_id) do
    if connected?(socket) do
      case Ecto.UUID.cast(raw_goal_id) do
        {:ok, goal_id} ->
          :ok = Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(goal_id))
          :ok = Phoenix.PubSub.subscribe(Shoestring.PubSub, projection_topic(goal_id))
          socket

        :error ->
          socket
      end
    else
      socket
    end
  end

  defp command_dom_id(%{id: id}), do: "cobbler-command-#{id}"
  defp event_dom_id(%TrajectoryEvent{id: id}), do: "cobbler-event-#{id}"

  defp projection_topic(goal_id), do: "trajectory:projection:#{goal_id}"

  # -- Template helpers (UI boundary; redaction applied before render) --

  defp event_time(%TrajectoryEvent{occurred_at: %DateTime{} = occurred_at}),
    do: DateTime.to_iso8601(occurred_at)

  defp event_time(_event), do: ""

  defp event_payload_text(%TrajectoryEvent{payload: payload}) do
    payload |> RunPresentation.format_payload() |> RunPresentation.cap_text() |> elem(0)
  end

  defp command_result_summary(%{result: result}) when is_map(result) do
    result |> RunPresentation.format_payload() |> RunPresentation.cap_text() |> elem(0)
  end

  defp command_result_summary(_command), do: "{}"

  defp command_status_tag(status) when is_binary(status) do
    CobblerPresentation.command_presentation(status).status
  end

  defp command_status_tag(_status), do: "unknown"

  defp intent_of(%{payload: %{"intent" => intent}}) when is_binary(intent), do: intent
  defp intent_of(_command), do: ""
end
