defmodule ShoestringWeb.CobblerGoalLive do
  @moduledoc """
  Per-goal Cobbler explanation page: admission decision, lease, checkpoint,
  claim, execution provider, isolated worktree, sleep honesty, commands, and
  events.

  The execution-provider and worktree cards answer two questions that must
  never be conflated: which provider currently owns a live turn (a
  `harness_runs` row in an executing state), and which provider admission
  merely evaluated as a candidate (the `candidate` block of the latest
  persisted `admission.decided` payload). Worktree identity comes from the
  durable worktree record keyed by run id. Every value is read from a
  persisted row; absent data renders as an explicit "not recorded" rather
  than a placeholder, no provider is contacted, and nothing is inferred.

  Every event is read-only (`refresh`, `rebuild`) except `respond`, the
  single operator confirm/respond form, which delegates to
  `Cobbler.respond_command/4` after enforcing an attributable
  `confirmed_by` identity and a matching intent confirmation at the UI
  boundary, and `request_recheck`, the manual wake control, which delegates
  to `Wakeups.request_recheck/2` after enforcing an attributable operator
  identity (a duplicate recheck replays the queued intent instead of
  duplicating it). Unattributed or mismatched confirmations are rejected with an
  error flash and change nothing.
  """

  use ShoestringWeb, :live_view

  import Ecto.Query

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.AdmissionDecision
  alias Shoestring.Cobbler.{WakeupRecord, Wakeups}
  alias Shoestring.Harness.{CheckpointRecord, ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, ProjectorPosition, TrajectoryEvent}
  alias Shoestring.Worktrees
  alias Shoestring.Worktrees.Worktree
  alias ShoestringWeb.CobblerPresentation
  alias ShoestringWeb.RunPresentation

  require Logger

  @projector "goal_task"

  # A provider only "owns a live turn" in these run states. `requested` is a
  # dispatched intent that is not executing yet, and every suspended or
  # terminal state has stopped. Nothing here is inferred from timing.
  @executing_run_statuses ["starting", "running", "pausing", "cancelling"]

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
  def handle_event("request_recheck", %{"recheck" => recheck_params}, socket) do
    {:noreply, do_recheck(socket, recheck_params)}
  end

  @impl true
  def handle_event("request_recheck", _params, socket) do
    {:noreply, do_recheck(socket, %{})}
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
    |> assign(:execution, empty_execution())
    |> assign(:worktree, %{state: :no_run, run_id: nil, workspace_ref: nil, record: nil})
    |> assign(:projection, %{status: "not_projected", error_detail: nil})
    |> assign(:rebuild, %{consistent?: true, divergences: [], error: nil})
    |> assign(:warnings, [])
    |> assign(:commands_empty?, true)
    |> assign(:respond_forms, %{})
    |> assign(:recheck_form, to_form(%{"operator_identity" => ""}, as: :recheck))
    |> assign(:pending_wakeup, nil)
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
    execution = execution_display(goal.id, latest_decision)
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
    |> assign(:execution, execution)
    |> assign(:worktree, worktree_display(execution.worktree_run))
    |> assign(:projection, projection)
    |> assign(:rebuild, rebuild)
    |> assign(:warnings, warnings)
    |> assign(:commands_empty?, commands == [])
    |> assign(:respond_forms, respond_forms(commands))
    |> assign(:recheck_form, to_form(%{"operator_identity" => ""}, as: :recheck))
    |> assign(:pending_wakeup, pending_wakeup(goal.id))
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

  # Manual wake/recheck control (loop-closure I4, P3): an explicit operator
  # identity is required (P6 convention — anonymous is rejected and changes
  # nothing), and the domain's idempotency-key dedupe keeps a duplicate
  # recheck to a single queued intent. No timers are involved: the control
  # only schedules a durable wake intent whose Oban delivery re-observes
  # before acting.
  defp do_recheck(socket, recheck_params) do
    operator =
      recheck_params
      |> Map.get("operator_identity", "")
      |> to_string()
      |> String.trim()

    case socket.assigns[:goal] do
      %Goal{} = goal ->
        case Wakeups.request_recheck(goal.id, operator_identity: operator) do
          {:ok, %{wakeup: wakeup, outcome: :recorded}} ->
            socket
            |> put_flash(
              :info,
              "Recheck requested by '#{operator}' (wake #{String.slice(wakeup.id, 0, 8)})."
            )
            |> reload()

          {:ok, %{outcome: :replayed}} ->
            socket
            |> put_flash(
              :info,
              "A recheck by '#{operator}' is already queued. Nothing duplicated."
            )
            |> reload()

          {:error, :anonymous_operator} ->
            put_flash(
              socket,
              :error,
              "Recheck requires an attributable operator identity."
            )

          {:error, {:recheck_rejected, reason}} ->
            put_flash(
              socket,
              :error,
              "Recheck rejected (#{inspect(reason)}). Nothing changed."
            )

          {:error, {:wakeup_rejected, :goal_terminal}} ->
            put_flash(socket, :error, "Goal is terminal. Nothing changed.")

          {:error, reason} ->
            Logger.warning("Cobbler recheck failed: #{inspect(reason)}")
            put_flash(socket, :error, "Could not request the recheck. Nothing changed.")
        end

      _missing ->
        put_flash(socket, :error, "Goal is no longer available. Please refresh the page.")
    end
  end

  # Earliest live (`scheduled`/`due`) durable wake intent for the goal, if
  # any — the honest countdown source for the sleep card (a persisted row,
  # never an invented timestamp).
  defp pending_wakeup(goal_id) do
    Repo.one(
      from wakeup in WakeupRecord,
        where: wakeup.goal_id == ^goal_id and wakeup.status in ["scheduled", "due"],
        order_by: [asc: wakeup.wake_at, asc: wakeup.id],
        limit: 1
    )
  rescue
    _error -> nil
  end

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
      candidate: candidate_display(Map.get(payload, "candidate")),
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

  # -- Execution provider + isolated worktree (read-only, durable evidence) --
  #
  # Two distinct questions are answered separately and never merged:
  #
  #   * WHICH PROVIDER IS EXECUTING NOW - the newest `harness_runs` row for
  #     this goal whose status is in `@executing_run_statuses`. Absent such a
  #     row, no provider is executing and the card says exactly that rather
  #     than promoting the latest run's provider.
  #   * WHICH PROVIDER WAS EVALUATED AS A CANDIDATE - the `candidate` block of
  #     the latest persisted `admission.decided` payload. A candidate records
  #     what admission weighed; it is never evidence that anything ran.
  #
  # Both come from persisted rows. Nothing is inferred, no provider is
  # contacted, and a field the records do not carry renders as an explicit
  # unknown instead of a placeholder value.
  defp execution_display(goal_id, latest_decision) do
    latest = latest_run(goal_id)
    executing = executing_run(goal_id)

    %{
      latest_run: run_display(latest),
      executing_run: run_display(executing),
      candidate: candidate_of(latest_decision),
      # The worktree is keyed by run id, so an executing run names the live
      # worktree and otherwise the latest run names the most recent one.
      worktree_run: executing || latest
    }
  end

  defp empty_execution do
    %{latest_run: nil, executing_run: nil, candidate: nil, worktree_run: nil}
  end

  defp latest_run(goal_id) do
    Repo.one(
      from run in RunRecord,
        where: run.goal_id == ^goal_id,
        order_by: [desc: run.inserted_at, desc: run.id],
        limit: 1
    )
  rescue
    _error -> nil
  end

  defp executing_run(goal_id) do
    Repo.one(
      from run in RunRecord,
        where: run.goal_id == ^goal_id and run.status in @executing_run_statuses,
        order_by: [desc: run.inserted_at, desc: run.id],
        limit: 1
    )
  rescue
    _error -> nil
  end

  defp run_display(nil), do: nil

  defp run_display(%RunRecord{} = run) do
    %{
      id: run.id,
      status: run.status,
      presentation: CobblerPresentation.run_provider_presentation(run.status || :unknown),
      provider_id: recorded_value(run.provider_id),
      workspace_ref: recorded_value(run.workspace_ref),
      # Provider-reported, therefore diagnostic evidence only: it is the
      # provider's own identifier for its session, never canonical domain
      # state, and it is redacted like any other provider-sourced text.
      provider_session_id: run.provider_session_id |> recorded_value() |> redact_recorded()
    }
  end

  defp candidate_of(%{candidate: candidate}) when is_map(candidate), do: candidate
  defp candidate_of(_decision), do: nil

  defp candidate_display(candidate) when is_map(candidate) do
    display = %{
      provider_id: recorded_value(Map.get(candidate, "provider_id")),
      adapter_id: recorded_value(Map.get(candidate, "adapter_id")),
      support_tier: recorded_value(Map.get(candidate, "support_tier")),
      compatibility_state: recorded_value(Map.get(candidate, "compatibility_state"))
    }

    if Enum.all?(Map.values(display), &is_nil/1), do: nil, else: display
  end

  defp candidate_display(_candidate), do: nil

  # The durable worktree record is the authority for worktree identity. It is
  # read through `Shoestring.Worktrees` exactly as the run page reads it, and
  # every failure mode keeps its own honest state: a run with no registered
  # record is not the same as a record that could not be read, and neither is
  # the same as a goal that has never had a run.
  defp worktree_display(nil) do
    %{state: :no_run, run_id: nil, workspace_ref: nil, record: nil}
  end

  defp worktree_display(%RunRecord{} = run) do
    base = %{run_id: run.id, workspace_ref: recorded_value(run.workspace_ref)}

    case safe_worktree(run.id) do
      {:ok, %Worktree{} = worktree} ->
        Map.merge(base, %{state: :registered, record: worktree_record(worktree)})

      {:error, :not_found} ->
        Map.merge(base, %{state: :not_registered, record: nil})

      {:error, {:record_diverged, _detail}} ->
        Map.merge(base, %{state: :diverged, record: nil})

      _other ->
        Map.merge(base, %{state: :unavailable, record: nil})
    end
  end

  defp safe_worktree(run_id) do
    Worktrees.get(run_id)
  rescue
    error -> {:error, error}
  catch
    _kind, reason -> {:error, reason}
  end

  defp worktree_record(%Worktree{} = worktree) do
    %{
      path: RunPresentation.redact_text(worktree.path),
      repo_path: RunPresentation.redact_text(worktree.repo_path),
      repo_id: recorded_value(worktree.repo_id),
      branch: recorded_value(worktree.branch),
      base_commit: recorded_value(worktree.base_commit),
      workspace_ref: recorded_value(worktree.workspace_ref),
      created_at: worktree.created_at,
      presentation: CobblerPresentation.worktree_presentation(worktree.status || :unknown)
    }
  end

  # A value is "recorded" only when the row actually carries it. Blank strings
  # are absent data, not empty data, and become an explicit unknown in the UI.
  defp recorded_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp recorded_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp recorded_value(_value), do: nil

  defp redact_recorded(nil), do: nil
  defp redact_recorded(value), do: RunPresentation.redact_text(value)

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

  # An absent value renders as an explicit, visually distinct "not recorded"
  # rather than as a blank cell that could be mistaken for a real value.
  defp recorded_or(nil, fallback), do: fallback
  defp recorded_or(value, _fallback), do: value

  defp value_class(nil), do: "text-sm italic text-zinc-500"
  defp value_class(_value), do: "text-sm font-medium text-zinc-900"

  defp mono_value_class(nil), do: "text-xs italic text-zinc-500"
  defp mono_value_class(_value), do: "text-xs font-mono text-zinc-900 break-all"

  defp worktree_unknown_text(:no_run),
    do:
      "No harness run is recorded for this goal, so no worktree has been provisioned. " <>
        "A worktree is keyed by run id and appears once a run is recorded."

  defp worktree_unknown_text(:not_registered),
    do:
      "No durable worktree record is registered for this run. The workspace reference " <>
        "above is what the run row records; no path, branch, or base commit is known."

  defp worktree_unknown_text(:diverged),
    do:
      "The durable worktree record and the copy stored in the worktree's Git directory " <>
        "disagree, so no worktree identity is shown. Nothing is guessed from either copy."

  defp worktree_unknown_text(_state),
    do:
      "The durable worktree record could not be read, so worktree identity is unknown " <>
        "on this page. No path or branch is inferred."
end
