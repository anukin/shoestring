defmodule ShoestringWeb.CobblerPresentation do
  @moduledoc """
  Presentational mapping for the Cobbler UI boundary.

  Maps goal lifecycle states, admission results, command statuses, and
  lease/renewal states to distinct visual presentations (label + dot +
  badge + icon + `data-status` tag). Every mapper has an honest `:unknown`
  fallback so unrecognized values from future T1–T4 work never crash
  rendering: unknown inputs render as "Unknown", never as an invented
  concrete state.

  Lifecycle state derivation (`derive_goal_state/2`) folds admission
  decision results and persisted command result kinds through the pure
  `Shoestring.Cobbler.GoalLifecycle` machine. Any unrecognized value or
  illegal transition yields `:unknown` instead of raising.
  """

  alias Shoestring.Cobbler.GoalLifecycle

  @doc """
  Derives a presentational goal lifecycle state from ordered admission
  decision results and ordered persisted command result kinds.

  Both lists accept atoms or strings. Unknown values and illegal
  transitions fold to `:unknown`; this function never raises.
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
