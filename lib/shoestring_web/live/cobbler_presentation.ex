defmodule ShoestringWeb.CobblerPresentation do
  @moduledoc """
  Presentational mapping for the Cobbler UI boundary.

  Maps goal lifecycle states, admission results, command statuses, and
  lease/renewal states to distinct visual presentations (label + dot +
  badge + icon + `data-status` tag). Every mapper has an honest `:unknown`
  fallback so unrecognized values from future T1–T4 work never crash
  rendering: unknown inputs render as "Unknown", never as an invented
  concrete state.

  Lifecycle state derivation folds one sequence-ordered timeline through
  the pure `Shoestring.Cobbler.GoalLifecycle` machine. The timeline is the
  goal's canonical trajectory replay: admission decisions, command
  outcomes, and run progress events interleaved by sequence (so a run
  finishing after a checkpoint lands in the finished state instead of
  being folded out of order). Run progress contributes
  working/checkpointing/sleeping signal as a read-only derivation — no
  writes. Any unrecognized value or illegal transition yields `:unknown`
  instead of raising.
  """

  alias Shoestring.Cobbler.GoalLifecycle

  @doc """
  Derives a presentational goal lifecycle state from ONE sequence-ordered
  timeline (decisions + commands + run progress events interleaved by
  sequence).

  Each entry may be:

  - a `Shoestring.Trajectory.TrajectoryEvent` struct (mapped by type and
    payload: `admission.decided`, `cobbler.command.accepted` /
    `cobbler.command.resolved` / `cobbler.claim.acquired` /
    `cobbler.claim.released`, `run.*`, `checkpoint.created`,
    `handoff.created`; lifecycle-irrelevant types such as `lease.*`,
    `capacity.*`, `task.*`, `goal.*`, `dispatch.*`, `harness.*`, and
    `elf.*` are skipped as read-only no-ops);
  - a `%{sequence: integer, kind: :decision | :command | :run, value: term}`
    map (string keys and string kinds accepted);
  - a `{sequence, event}` tuple where `event` is already a
    `GoalLifecycle` event.

  Entries sort by `:sequence` (entries without a sequence keep input
  order). Run progress maps to lifecycle signal: `run.starting` /
  `run.running` to `:dispatch_started` (a no-op when already working or
  checkpointing), `checkpoint.created` to `:checkpoint_started` (a no-op
  when already checkpointing, or when working it opens the checkpoint),
  `run.completed` / `run.failed` to outcome-carrying
  `{:run_terminal, outcome}`, `run.interrupted` / `run.cancelled` /
  `run.cancelling` to the legacy outcome-less `:run_terminal`,
  `run.suspended` / `run.pausing` while working or checkpointing to
  `:sleeping` (read-only suspension signal, no writes),
  `handoff.created` to `:handoff_requested` (handoff targets a new run of
  the same goal; the goal itself rests in terminal `handing_off`).

  Unknown values and illegal transitions fold to `:unknown`; this
  function never raises.
  """
  @spec derive_goal_state([term()]) :: atom()
  def derive_goal_state(timeline) when is_list(timeline) do
    timeline
    |> with_order()
    |> Enum.sort_by(fn {sequence, _entry, index} -> {sequence, index} end)
    |> Enum.reduce_while(GoalLifecycle.initial(), fn {_sequence, entry, _index}, state ->
      case timeline_step(state, entry) do
        {:ok, next} -> {:cont, next}
        :skip -> {:cont, state}
        :unknown -> {:halt, :unknown}
      end
    end)
  rescue
    _error -> :unknown
  end

  def derive_goal_state(_timeline), do: :unknown

  @doc """
  Derives a presentational goal lifecycle state from ordered admission
  decision results and ordered persisted command result kinds.

  Both lists accept atoms or strings. Unknown values and illegal
  transitions fold to `:unknown`; this function never raises.

  Deprecated in favor of `derive_goal_state/1` (one sequence-ordered
  timeline): the grouped fold cannot interleave events and drops run
  progress. Kept for outcome-less T1/T3 consumers and the wakeups
  derivation mirror; new call sites should build a timeline.
  """
  @spec derive_goal_state([atom() | String.t()], [atom() | String.t()]) :: atom()
  def derive_goal_state(decision_results, command_kinds)
      when is_list(decision_results) and is_list(command_kinds) do
    events =
      Enum.map(decision_results, &{:admission_decision, &1}) ++
        Enum.map(command_kinds, &{:command_outcome, &1})

    Enum.reduce_while(events, GoalLifecycle.initial(), fn event, state ->
      case safe_transition(state, event) do
        {:ok, next} -> {:cont, next}
        :unknown -> {:halt, :unknown}
      end
    end)
  rescue
    _error -> :unknown
  end

  def derive_goal_state(_decisions, _commands), do: :unknown

  @doc """
  Visual presentation (label, dot, badge, icon) for a goal lifecycle state.

  Every lifecycle state has a distinct `data-status` tag; unrecognized
  states fall back to `:unknown`.
  """
  @spec lifecycle_presentation(atom() | String.t()) :: %{
          label: String.t(),
          detail: String.t(),
          dot_class: String.t(),
          badge_class: String.t(),
          icon: String.t(),
          status: String.t()
        }
  def lifecycle_presentation(:evaluating) do
    %{
      label: "Evaluating admission.",
      detail: "Admission is being evaluated. No claim has been acquired.",
      dot_class: "bg-blue-500",
      badge_class: "bg-blue-100 text-blue-800",
      icon: "hero-magnifying-glass",
      status: "evaluating"
    }
  end

  def lifecycle_presentation(:queued) do
    %{
      label: "Queued for claim.",
      detail: "Admitted and awaiting the exclusive task claim.",
      dot_class: "bg-indigo-500",
      badge_class: "bg-indigo-100 text-indigo-800",
      icon: "hero-queue-list",
      status: "queued"
    }
  end

  def lifecycle_presentation(:dispatching) do
    %{
      label: "Dispatch gated.",
      detail: "Claim acquired; dispatch is held at the execution-disabled boundary.",
      dot_class: "bg-violet-500",
      badge_class: "bg-violet-100 text-violet-800",
      icon: "hero-pause-circle",
      status: "dispatching"
    }
  end

  def lifecycle_presentation(:working) do
    %{
      label: "Working.",
      detail: "A run is doing useful work under an active claim.",
      dot_class: "bg-emerald-500",
      badge_class: "bg-emerald-100 text-emerald-800",
      icon: "hero-cog-6-tooth",
      status: "working"
    }
  end

  def lifecycle_presentation(:checkpointing) do
    %{
      label: "Checkpointing.",
      detail: "A checkpoint is being recorded mid-run.",
      dot_class: "bg-teal-500",
      badge_class: "bg-teal-100 text-teal-800",
      icon: "hero-document-check",
      status: "checkpointing"
    }
  end

  def lifecycle_presentation(:sleeping) do
    %{
      label: "Sleeping — deferred.",
      detail:
        "Deferred until an explicit recheck. Only an explicit wake event resumes this goal; staleness alone never wakes it.",
      dot_class: "bg-amber-500",
      badge_class: "bg-amber-100 text-amber-800",
      icon: "hero-moon",
      status: "sleeping"
    }
  end

  def lifecycle_presentation(:handing_off) do
    %{
      label: "Handed off.",
      detail: "Terminal. The goal left automated handling for an operator.",
      dot_class: "bg-zinc-500",
      badge_class: "bg-zinc-200 text-zinc-800",
      icon: "hero-arrow-right-circle",
      status: "handing-off"
    }
  end

  def lifecycle_presentation(:completed) do
    %{
      label: "Completed.",
      detail: "Terminal. A run finished and reported success.",
      dot_class: "bg-emerald-600",
      badge_class: "bg-emerald-100 text-emerald-900",
      icon: "hero-check-badge",
      status: "completed"
    }
  end

  def lifecycle_presentation(:failed) do
    %{
      label: "Failed.",
      detail: "Terminal. A run finished and reported failure.",
      dot_class: "bg-red-600",
      badge_class: "bg-red-100 text-red-900",
      icon: "hero-x-circle",
      status: "failed"
    }
  end

  def lifecycle_presentation(:needs_user) do
    %{
      label: "Needs operator.",
      detail:
        "A run finished needing an operator decision. Answer the pending command below; the response is attribution-gated.",
      dot_class: "bg-purple-500",
      badge_class: "bg-purple-100 text-purple-900",
      icon: "hero-hand-raised",
      status: "needs-user"
    }
  end

  def lifecycle_presentation(_state) do
    %{
      label: "Unknown goal state.",
      detail:
        "The goal state could not be determined from known lifecycle values. It is never treated as admitted.",
      dot_class: "bg-zinc-400",
      badge_class: "bg-zinc-100 text-zinc-800",
      icon: "hero-question-mark-circle",
      status: "unknown"
    }
  end

  @doc """
  Visual presentation for an admission decision result.

  Unrecognized results fall back to `:unknown`.
  """
  @spec decision_presentation(atom() | String.t()) :: %{
          label: String.t(),
          detail: String.t(),
          dot_class: String.t(),
          badge_class: String.t(),
          icon: String.t(),
          status: String.t()
        }
  def decision_presentation(:admit) do
    %{
      label: "Admitted.",
      detail: "Eligible for execution under the recorded bounds.",
      dot_class: "bg-emerald-500",
      badge_class: "bg-emerald-100 text-emerald-800",
      icon: "hero-check-circle",
      status: "admitted"
    }
  end

  def decision_presentation(:defer_until) do
    %{
      label: "Deferred.",
      detail: "Temporarily blocked; deferred until the recorded recheck.",
      dot_class: "bg-amber-500",
      badge_class: "bg-amber-100 text-amber-800",
      icon: "hero-clock",
      status: "deferred"
    }
  end

  def decision_presentation(:require_confirmation) do
    %{
      label: "Needs confirmation.",
      detail: "Requires an attributable single-decision operator confirmation.",
      dot_class: "bg-purple-500",
      badge_class: "bg-purple-100 text-purple-800",
      icon: "hero-hand-raised",
      status: "confirmation-required"
    }
  end

  def decision_presentation(:reject) do
    %{
      label: "Rejected.",
      detail: "Permanently refused for this candidate; cannot be bypassed.",
      dot_class: "bg-red-600",
      badge_class: "bg-red-100 text-red-800",
      icon: "hero-x-circle",
      status: "rejected"
    }
  end

  def decision_presentation("admit"), do: decision_presentation(:admit)
  def decision_presentation("defer_until"), do: decision_presentation(:defer_until)

  def decision_presentation("require_confirmation"),
    do: decision_presentation(:require_confirmation)

  def decision_presentation("reject"), do: decision_presentation(:reject)

  def decision_presentation(_result) do
    %{
      label: "Unknown decision.",
      detail: "The admission result is not a recognized value and is never treated as admitted.",
      dot_class: "bg-zinc-400",
      badge_class: "bg-zinc-100 text-zinc-800",
      icon: "hero-question-mark-circle",
      status: "unknown"
    }
  end

  @doc """
  Visual presentation for a persisted command status.

  Unrecognized statuses fall back to `:unknown`.
  """
  @spec command_presentation(atom() | String.t()) :: %{
          label: String.t(),
          dot_class: String.t(),
          badge_class: String.t(),
          icon: String.t(),
          status: String.t()
        }
  def command_presentation(:needs_user) do
    %{
      label: "Needs operator.",
      dot_class: "bg-purple-500",
      badge_class: "bg-purple-100 text-purple-800",
      icon: "hero-hand-raised",
      status: "needs-operator"
    }
  end

  def command_presentation(:resolved) do
    %{
      label: "Resolved.",
      dot_class: "bg-emerald-500",
      badge_class: "bg-emerald-100 text-emerald-800",
      icon: "hero-check-circle",
      status: "resolved"
    }
  end

  def command_presentation(:rejected) do
    %{
      label: "Rejected.",
      dot_class: "bg-red-600",
      badge_class: "bg-red-100 text-red-800",
      icon: "hero-x-circle",
      status: "rejected"
    }
  end

  def command_presentation(:pending) do
    %{
      label: "Pending.",
      dot_class: "bg-blue-500",
      badge_class: "bg-blue-100 text-blue-800",
      icon: "hero-clock",
      status: "pending"
    }
  end

  def command_presentation("needs_user"), do: command_presentation(:needs_user)
  def command_presentation("resolved"), do: command_presentation(:resolved)
  def command_presentation("rejected"), do: command_presentation(:rejected)
  def command_presentation("pending"), do: command_presentation(:pending)

  def command_presentation(_status) do
    %{
      label: "Unknown command state.",
      dot_class: "bg-zinc-400",
      badge_class: "bg-zinc-100 text-zinc-800",
      icon: "hero-question-mark-circle",
      status: "unknown"
    }
  end

  @doc """
  Visual presentation for an execution lease status.

  Unrecognized statuses fall back to `:unknown`.
  """
  @spec lease_presentation(atom() | String.t()) :: %{
          label: String.t(),
          dot_class: String.t(),
          badge_class: String.t(),
          icon: String.t(),
          status: String.t()
        }
  def lease_presentation(:proposed),
    do:
      lease_status(
        "Proposed.",
        "bg-blue-500",
        "bg-blue-100 text-blue-800",
        "hero-document",
        "proposed"
      )

  def lease_presentation(:granted),
    do:
      lease_status(
        "Granted.",
        "bg-indigo-500",
        "bg-indigo-100 text-indigo-800",
        "hero-check-badge",
        "granted"
      )

  def lease_presentation(:active),
    do:
      lease_status(
        "Active.",
        "bg-emerald-500",
        "bg-emerald-100 text-emerald-800",
        "hero-bolt",
        "active"
      )

  def lease_presentation(:renewal_due),
    do:
      lease_status(
        "Renewal due.",
        "bg-amber-500",
        "bg-amber-100 text-amber-800",
        "hero-clock",
        "renewal-due"
      )

  def lease_presentation(:renewed),
    do:
      lease_status(
        "Renewed.",
        "bg-teal-500",
        "bg-teal-100 text-teal-800",
        "hero-arrow-path",
        "renewed"
      )

  def lease_presentation(:expired),
    do:
      lease_status(
        "Expired.",
        "bg-zinc-500",
        "bg-zinc-200 text-zinc-800",
        "hero-x-mark",
        "expired"
      )

  def lease_presentation(:revoked),
    do:
      lease_status(
        "Revoked.",
        "bg-red-600",
        "bg-red-100 text-red-800",
        "hero-no-symbol",
        "revoked"
      )

  def lease_presentation(:checkpoint_required),
    do:
      lease_status(
        "Checkpoint required.",
        "bg-orange-500",
        "bg-orange-100 text-orange-800",
        "hero-document-check",
        "checkpoint-required"
      )

  def lease_presentation(status) when is_binary(status) do
    try do
      lease_presentation(String.to_existing_atom(status))
    rescue
      ArgumentError -> lease_presentation(:unknown)
    end
  end

  def lease_presentation(_status),
    do:
      lease_status(
        "Unknown lease state.",
        "bg-zinc-400",
        "bg-zinc-100 text-zinc-800",
        "hero-question-mark-circle",
        "unknown"
      )

  @doc """
  Visual presentation for a lease renewal state.

  Unrecognized states fall back to `:unknown`.
  """
  @spec renewal_presentation(atom() | String.t()) :: %{
          label: String.t(),
          badge_class: String.t(),
          icon: String.t(),
          status: String.t()
        }
  def renewal_presentation(:none),
    do: renewal_status("No renewal.", "bg-zinc-100 text-zinc-800", "hero-minus-circle", "none")

  def renewal_presentation(:eligible),
    do:
      renewal_status(
        "Eligible for renewal.",
        "bg-blue-100 text-blue-800",
        "hero-check-circle",
        "eligible"
      )

  def renewal_presentation(:due),
    do: renewal_status("Renewal due.", "bg-amber-100 text-amber-800", "hero-clock", "due")

  def renewal_presentation(:renewed),
    do: renewal_status("Renewed.", "bg-teal-100 text-teal-800", "hero-arrow-path", "renewed")

  def renewal_presentation(:expired),
    do: renewal_status("Renewal expired.", "bg-zinc-200 text-zinc-800", "hero-x-mark", "expired")

  def renewal_presentation(:revoked),
    do: renewal_status("Renewal revoked.", "bg-red-100 text-red-800", "hero-no-symbol", "revoked")

  def renewal_presentation(state) when is_binary(state) do
    try do
      renewal_presentation(String.to_existing_atom(state))
    rescue
      ArgumentError -> renewal_presentation(:unknown)
    end
  end

  def renewal_presentation(_state),
    do:
      renewal_status(
        "Unknown renewal state.",
        "bg-zinc-100 text-zinc-800",
        "hero-question-mark-circle",
        "unknown"
      )

  defp lease_status(label, dot_class, badge_class, icon, status) do
    %{label: label, dot_class: dot_class, badge_class: badge_class, icon: icon, status: status}
  end

  defp renewal_status(label, badge_class, icon, status) do
    %{label: label, badge_class: badge_class, icon: icon, status: status}
  end

  defp safe_transition(state, {:admission_decision, result}) do
    with {:ok, normalized} <- normalize_admission_result(result),
         {:ok, event} <- GoalLifecycle.decision_event(normalized),
         {:ok, next} <- GoalLifecycle.transition(state, event) do
      {:ok, next}
    else
      _error -> :unknown
    end
  rescue
    _error -> :unknown
  end

  defp safe_transition(state, {:command_outcome, kind}) do
    with {:ok, normalized} <- normalize_command_outcome(kind),
         {:ok, next} <- GoalLifecycle.transition(state, {:command_outcome, normalized}) do
      {:ok, next}
    else
      _error -> :unknown
    end
  rescue
    _error -> :unknown
  end

  # -- Sequence-ordered timeline (derive_goal_state/1) --

  # Lifecycle-irrelevant trajectory types: read-only no-ops for the goal
  # derivation (leases, capacity, tasks, dispatch plumbing, harness Elf
  # progress owned by the parallel slice). Unknown future types outside
  # this list fold to :unknown instead of being silently skipped.
  @skipped_timeline_prefixes [
    "lease.",
    "capacity.",
    "task.",
    "goal.",
    "dispatch.",
    "harness.",
    "elf.",
    "decision."
  ]

  defp with_order(timeline) do
    timeline
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> {timeline_sequence(entry, index), entry, index} end)
  end

  defp timeline_sequence({sequence, _event}, _index) when is_integer(sequence), do: sequence
  defp timeline_sequence(%{sequence: sequence}, _index) when is_integer(sequence), do: sequence

  defp timeline_sequence(%{"sequence" => sequence}, _index) when is_integer(sequence),
    do: sequence

  defp timeline_sequence(%{sequence: _other}, index), do: index
  defp timeline_sequence(%{"sequence" => _other}, index), do: index
  defp timeline_sequence(_entry, index), do: index

  defp timeline_step(state, {sequence, event}) when is_integer(sequence) do
    case event do
      {:admission_decision, _} -> safe_transition(state, event)
      {:command_outcome, _} -> safe_transition(state, event)
      {:run_terminal, _} -> run_terminal_step(state, event)
      {:run_progress, code} -> run_progress_step(state, code)
      :run_terminal -> run_signal_step(state, :run_terminal)
      :dispatch_started -> run_signal_step(state, :dispatch_started)
      :dispatch_blocked -> run_signal_step(state, :dispatch_blocked)
      :checkpoint_started -> run_signal_step(state, :checkpoint_started)
      :checkpoint_done -> run_signal_step(state, :checkpoint_done)
      :recheck_due -> run_signal_step(state, :recheck_due)
      :handoff_requested -> run_signal_step(state, :handoff_requested)
      _other -> :unknown
    end
  rescue
    _error -> :unknown
  end

  defp timeline_step(state, %{kind: kind, value: value}) do
    timeline_step(state, {0, timeline_kind_event(kind, value)})
  rescue
    _error -> :unknown
  end

  defp timeline_step(state, %{"kind" => kind, "value" => value}) do
    timeline_step(state, %{kind: kind, value: value})
  end

  defp timeline_step(state, %{__struct__: struct} = event)
       when struct in [
              Shoestring.Trajectory.TrajectoryEvent
            ] do
    case trajectory_timeline_event(event) do
      {:event, lifecycle_event} -> machine_step(state, lifecycle_event)
      :skip -> :skip
      :unknown -> :unknown
    end
  rescue
    _error -> :unknown
  end

  defp timeline_step(_state, _entry), do: :unknown

  defp timeline_kind_event(kind, value) when kind in [:decision, "decision"] do
    {:admission_decision, value}
  end

  defp timeline_kind_event(kind, value) when kind in [:command, "command"] do
    {:command_outcome, value}
  end

  defp timeline_kind_event(kind, value) when kind in [:run, "run"] do
    {:run_progress, value}
  end

  defp timeline_kind_event(_kind, _value), do: :__unknown_kind__

  # Already-shaped lifecycle events go through the machine with tolerant
  # run-signal no-ops (duplicate run.running / checkpoint.created replays
  # keep the signaled state instead of halting to :unknown) and idempotent
  # claim signals (a `cobbler.claim.acquired` replayed beside its
  # `cobbler.command.accepted` keeps `:dispatching`; a release observed
  # while already `:evaluating` keeps `:evaluating`).
  defp machine_step(state, {:admission_decision, _} = event), do: safe_transition(state, event)
  defp machine_step(state, {:command_outcome, _} = event), do: tolerant_command(state, event)
  defp machine_step(state, {:run_terminal, _} = event), do: run_terminal_step(state, event)
  defp machine_step(state, event) when is_atom(event), do: run_signal_step(state, event)
  defp machine_step(_state, _event), do: :unknown

  defp tolerant_command(state, {:command_outcome, _} = event) do
    case safe_transition(state, event) do
      {:ok, next} ->
        {:ok, next}

      :unknown ->
        case {state, event} do
          {:dispatching, {:command_outcome, :claimed}} -> {:ok, :dispatching}
          {:evaluating, {:command_outcome, :released}} -> {:ok, :evaluating}
          _other -> :unknown
        end
    end
  rescue
    _error -> :unknown
  end

  defp run_terminal_step(state, {:run_terminal, outcome}) do
    with {:ok, normalized} <- normalize_run_outcome(outcome),
         {:ok, next} <- GoalLifecycle.transition(state, {:run_terminal, normalized}) do
      {:ok, next}
    else
      _error -> :unknown
    end
  rescue
    _error -> :unknown
  end

  # Raw run-progress codes (trajectory type strings or signal atoms) map
  # to lifecycle signal before folding. Unknown codes fold to :unknown,
  # never raise.
  defp run_progress_step(state, code) do
    case normalize_run_progress(code) do
      {:event, lifecycle_event} -> machine_step(state, lifecycle_event)
      :unknown -> :unknown
    end
  rescue
    _error -> :unknown
  end

  defp normalize_run_progress(code)
       when code in ["run.starting", "run.running", :run_starting, :run_running, :working],
       do: {:event, :dispatch_started}

  defp normalize_run_progress(code)
       when code in ["checkpoint.created", :checkpoint_created, :checkpointing, "checkpointing"],
       do: {:event, :checkpoint_started}

  defp normalize_run_progress(code)
       when code in ["run.completed", :run_completed, :completed, "completed"],
       do: {:event, {:run_terminal, :completed}}

  defp normalize_run_progress(code)
       when code in ["run.failed", :run_failed, :failed, "failed"],
       do: {:event, {:run_terminal, :failed}}

  defp normalize_run_progress(code)
       when code in [:needs_user, "needs_user"],
       do: {:event, {:run_terminal, :needs_user}}

  defp normalize_run_progress(code)
       when code in ["run.interrupted", "run.cancelled", "run.cancelling", :terminal, "terminal"],
       do: {:event, :run_terminal}

  defp normalize_run_progress(code)
       when code in ["run.suspended", "run.pausing", :suspended, "suspended", :sleeping],
       do: {:event, :run_suspended}

  defp normalize_run_progress(code)
       when code in ["handoff.created", :handoff, "handoff"],
       do: {:event, :handoff_requested}

  # Already-shaped lifecycle signal atoms pass through untouched.
  defp normalize_run_progress(code)
       when code in [
              :dispatch_started,
              :dispatch_blocked,
              :checkpoint_started,
              :checkpoint_done,
              :run_terminal,
              :run_suspended,
              :recheck_due,
              :handoff_requested
            ],
       do: {:event, code}

  defp normalize_run_progress(_code), do: :unknown

  defp run_signal_step(state, event) do
    case GoalLifecycle.transition(state, event) do
      {:ok, next} ->
        {:ok, next}

      {:error, _reason} ->
        case {state, event} do
          {:working, :dispatch_started} -> {:ok, :working}
          {:checkpointing, :dispatch_started} -> {:ok, :checkpointing}
          {:checkpointing, :checkpoint_started} -> {:ok, :checkpointing}
          {:working, :checkpoint_done} -> {:ok, :working}
          {:working, :run_suspended} -> {:ok, :sleeping}
          {:checkpointing, :run_suspended} -> {:ok, :sleeping}
          _other -> :unknown
        end
    end
  rescue
    _error -> :unknown
  end

  defp trajectory_timeline_event(%{type: type, payload: payload}) do
    cond do
      type == "admission.decided" ->
        {:event, {:admission_decision, payload_value(payload, "result")}}

      type in ["cobbler.command.accepted", "cobbler.command.resolved"] ->
        {:event, {:command_outcome, command_kind_from_payload(payload)}}

      type == "cobbler.claim.acquired" ->
        {:event, {:command_outcome, :claimed}}

      type == "cobbler.claim.released" ->
        {:event, {:command_outcome, :released}}

      type in ["run.starting", "run.running"] ->
        {:event, :dispatch_started}

      type == "checkpoint.created" ->
        {:event, :checkpoint_started}

      type == "run.completed" ->
        {:event, {:run_terminal, :completed}}

      type == "run.failed" ->
        {:event, {:run_terminal, :failed}}

      type in ["run.interrupted", "run.cancelled", "run.cancelling"] ->
        {:event, :run_terminal}

      type in ["run.suspended", "run.pausing"] ->
        {:event, :run_suspended}

      type == "handoff.created" ->
        {:event, :handoff_requested}

      skipped_timeline_type?(type) ->
        :skip

      true ->
        :unknown
    end
  rescue
    _error -> :unknown
  end

  defp skipped_timeline_type?(type) when is_binary(type) do
    Enum.any?(@skipped_timeline_prefixes, &String.starts_with?(type, &1))
  end

  defp skipped_timeline_type?(_type), do: false

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key, Map.get(payload, String.to_atom(key)))
  rescue
    _error -> :unknown_value
  end

  defp payload_value(_payload, _key), do: :unknown_value

  defp command_kind_from_payload(payload) when is_map(payload) do
    result = Map.get(payload, "result", Map.get(payload, :result))

    cond do
      is_map(result) and
          (is_binary(result["kind"]) or is_atom(result[:kind]) or
             is_binary(result[:kind])) ->
        result["kind"] || result[:kind]

      is_binary(payload["to_status"]) or is_atom(payload["to_status"]) ->
        command_kind_from_status(payload["to_status"])

      true ->
        :unknown_kind
    end
  end

  defp command_kind_from_payload(_payload), do: :unknown_kind

  # Accepted events carry a status (`needs_user` for held claims) rather
  # than a result kind: a held claim waits recoverably, anything else is
  # unknown and folds honestly.
  defp command_kind_from_status(status) when status in ["needs_user", :needs_user],
    do: :needs_user

  defp command_kind_from_status(status) when status in ["claimed", :claimed], do: :claimed
  defp command_kind_from_status(_status), do: :unknown_kind

  defp normalize_run_outcome(outcome) when is_atom(outcome) do
    if outcome in [:completed, :failed, :needs_user] do
      {:ok, outcome}
    else
      :error
    end
  end

  defp normalize_run_outcome(outcome) when is_binary(outcome) do
    try do
      normalize_run_outcome(String.to_existing_atom(outcome))
    rescue
      ArgumentError -> :error
    end
  end

  defp normalize_run_outcome(_outcome), do: :error

  defp normalize_admission_result(result) when is_atom(result) do
    if result in [:admit, :defer_until, :require_confirmation, :reject] do
      {:ok, result}
    else
      :error
    end
  end

  defp normalize_admission_result(result) when is_binary(result) do
    try do
      normalize_admission_result(String.to_existing_atom(result))
    rescue
      ArgumentError -> :error
    end
  end

  defp normalize_admission_result(_result), do: :error

  defp normalize_command_outcome(kind) when is_atom(kind) do
    if kind in [:claimed, :needs_user, :rejected, :released, :no_active_claim, :abandoned] do
      {:ok, kind}
    else
      :error
    end
  end

  defp normalize_command_outcome(kind) when is_binary(kind) do
    try do
      normalize_command_outcome(String.to_existing_atom(kind))
    rescue
      ArgumentError -> :error
    end
  end

  defp normalize_command_outcome(_kind), do: :error
end
