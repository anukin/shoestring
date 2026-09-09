defmodule Shoestring.Cobbler.GoalLifecycle do
  @moduledoc """
  Goal-level lifecycle machine for quota-aware Cobbler goals.

  This is a NEW level above the command machine
  (`Shoestring.Cobbler.Command`): it tracks where a goal stands in the
  admit -> claim -> dispatch -> work cycle. It never redefines command
  semantics; command outcomes and admission decisions arrive here as input
  events and drive goal transitions.

  States:

  - `:evaluating` - admission is being evaluated (or re-evaluated).
  - `:queued` - admitted; awaiting (or holding) the exclusive claim.
  - `:dispatching` - claim acquired; a dispatch is being prepared. While
    execution stays disabled this state gates instead of spawning anything.
  - `:working` - a run is doing useful work.
  - `:checkpointing` - a checkpoint is being recorded mid-run.
  - `:sleeping` - deferred until an explicit recheck (quota reset, occupancy
    clearing). Per the locked iteration-4 decisions, staleness is evidence,
    not a trigger: only an explicit `:recheck_due` event wakes a sleeping
    goal. There are no timers here. A sleeping goal also waits in place on
    a repeat `defer_until` (resleep) or a `require_confirmation` (the
    operator confirms out-of-band and wakes the goal with an explicit
    recheck); a claim released while sleeping returns the goal to
    `:evaluating`.
  - `:completed` - terminal. A run finished and reported success.
  - `:failed` - terminal. A run finished and reported failure.
  - `:needs_user` - waiting. A run finished needing an operator decision;
    the existing attribution-gated `respond` path (operator response to the
    pending command) moves the goal back to `:evaluating`.
  - `:handing_off` - terminal. The goal leaves automated handling (rejected
    candidate, explicit operator handoff). Handoff targets a NEW run of the
    SAME goal (I5 contract); nothing transitions out of this state.

  Input events:

  - `{:admission_decision, result}` with
    `result in [:admit, :defer_until, :require_confirmation, :reject]`
    (see `Shoestring.Cobbler.AdmissionDecision`).
  - `{:command_outcome, kind}` with `kind` derived from a persisted
    `Shoestring.Cobbler.CommandRecord` result (`:claimed`, `:needs_user`,
    `:rejected`, `:released`, `:no_active_claim`, `:abandoned`).
  - `:dispatch_started` / `:dispatch_blocked` - the gated consumer reports
    whether a dispatch proceeded or stopped at the execution-disabled
    boundary. `:dispatch_blocked` keeps the goal in `:dispatching`; it never
    bypasses the gate.
  - `:checkpoint_started` / `:checkpoint_done`, `:run_terminal` (legacy
    outcome-less recycle to `:evaluating`, kept for callers that drive
    outcome-less terminals — see the dual-path note below),
    `{:run_terminal, outcome}` with `outcome in [:completed, :failed,
    :needs_user]` (outcome-carrying terminals from `:working` /
    `:checkpointing`), `:recheck_due`, `:handoff_requested`.

  Dual-path note (P1): `:run_terminal` (bare) preserves the old
  working/checkpointing → `:evaluating` recycle for outcome-less callers
  (T1/T3 consumers); `{:run_terminal, outcome}` carries the outcome class
  to a terminal (or waiting) state. New producers should pass outcomes;
  the bare path is deprecated but supported. See
  `plans/evidence/05-quota-aware-mvp/lifecycle-ui-completion.md`.

  All functions are pure: no processes, no database, no clocks.
  """

  @states [
    :evaluating,
    :queued,
    :dispatching,
    :working,
    :checkpointing,
    :sleeping,
    :completed,
    :failed,
    :needs_user,
    :handing_off
  ]

  @admission_results [:admit, :defer_until, :require_confirmation, :reject]

  @run_outcomes [:completed, :failed, :needs_user]

  @command_outcomes [
    :claimed,
    :needs_user,
    :rejected,
    :released,
    :no_active_claim,
    :abandoned
  ]

  @type state ::
          :evaluating
          | :queued
          | :dispatching
          | :working
          | :checkpointing
          | :sleeping
          | :completed
          | :failed
          | :needs_user
          | :handing_off

  @type admission_result :: :admit | :defer_until | :require_confirmation | :reject

  @type run_outcome :: :completed | :failed | :needs_user

  @type command_outcome ::
          :claimed
          | :needs_user
          | :rejected
          | :released
          | :no_active_claim
          | :abandoned

  @type event ::
          {:admission_decision, admission_result()}
          | {:command_outcome, command_outcome()}
          | :dispatch_started
          | :dispatch_blocked
          | :checkpoint_started
          | :checkpoint_done
          | :run_terminal
          | {:run_terminal, run_outcome()}
          | :recheck_due
          | :handoff_requested

  @doc "All goal lifecycle states."
  @spec states() :: [state()]
  def states, do: @states

  @doc "The outcome classes carried by `{:run_terminal, outcome}` events."
  @spec run_outcomes() :: [run_outcome()]
  def run_outcomes, do: @run_outcomes

  @doc "The initial state of a goal before any admission decision."
  @spec initial() :: state()
  def initial, do: :evaluating

  @doc "Returns true only for terminal goal states."
  @spec terminal?(state()) :: boolean()
  def terminal?(:handing_off), do: true
  def terminal?(:completed), do: true
  def terminal?(:failed), do: true
  def terminal?(_state), do: false

  @doc """
  Applies one lifecycle event to a goal state.

  Returns `{:ok, next_state}` (which may equal the current state for
  explicitly recoverable waits) or
  `{:error, {:invalid_transition, state, event}}`.
  """
  @spec transition(state(), event()) :: {:ok, state()} | {:error, term()}
  def transition(state, event)

  # Admission decisions.
  def transition(:evaluating, {:admission_decision, :admit}), do: {:ok, :queued}
  def transition(:evaluating, {:admission_decision, :defer_until}), do: {:ok, :sleeping}

  def transition(:evaluating, {:admission_decision, :require_confirmation}),
    do: {:ok, :evaluating}

  def transition(:evaluating, {:admission_decision, :reject}), do: {:ok, :handing_off}
  def transition(:sleeping, {:admission_decision, :admit}), do: {:ok, :queued}
  def transition(:sleeping, {:admission_decision, :reject}), do: {:ok, :handing_off}
  # A repeat deferral while asleep re-parks in place (resleep with a new
  # wake time); the wake worker schedules the new intent separately.
  def transition(:sleeping, {:admission_decision, :defer_until}), do: {:ok, :sleeping}
  # A confirmation demand while asleep waits in place: the operator surface
  # (pending commands plus the recorded decision) stays addressable and the
  # next wake comes from an explicit operator recheck.
  def transition(:sleeping, {:admission_decision, :require_confirmation}),
    do: {:ok, :sleeping}

  def transition(:queued, {:admission_decision, :defer_until}), do: {:ok, :sleeping}
  def transition(:working, {:admission_decision, :defer_until}), do: {:ok, :sleeping}
  def transition(:checkpointing, {:admission_decision, :defer_until}), do: {:ok, :sleeping}

  # Command outcomes.
  def transition(:queued, {:command_outcome, :claimed}), do: {:ok, :dispatching}
  # Recoverable: a held claim waits for the operator without leaving :queued.
  def transition(:queued, {:command_outcome, :needs_user}), do: {:ok, :queued}
  # The command was invalid against durable state; re-evaluate admission.
  def transition(:queued, {:command_outcome, :rejected}), do: {:ok, :evaluating}
  # An abandoned recovery returns the goal to evaluation.
  def transition(:queued, {:command_outcome, :abandoned}), do: {:ok, :evaluating}
  def transition(:queued, {:command_outcome, :released}), do: {:ok, :evaluating}
  def transition(:dispatching, {:command_outcome, :released}), do: {:ok, :evaluating}
  def transition(:dispatching, {:command_outcome, :no_active_claim}), do: {:ok, :evaluating}
  # A claim released while the goal sleeps (operator release out-of-band)
  # returns the goal to evaluation instead of stranding it asleep.
  def transition(:sleeping, {:command_outcome, :released}), do: {:ok, :evaluating}

  # Dispatch gate reports.
  def transition(:dispatching, :dispatch_started), do: {:ok, :working}
  # Gated on the disabled execution path: the goal waits in :dispatching
  # instead of bypassing the gate.
  def transition(:dispatching, :dispatch_blocked), do: {:ok, :dispatching}

  # Run progress.
  def transition(:working, :checkpoint_started), do: {:ok, :checkpointing}
  def transition(:checkpointing, :checkpoint_done), do: {:ok, :working}

  # Outcome-carrying terminals: the run finished and reported its class.
  def transition(:working, {:run_terminal, :completed}), do: {:ok, :completed}
  def transition(:working, {:run_terminal, :failed}), do: {:ok, :failed}
  def transition(:working, {:run_terminal, :needs_user}), do: {:ok, :needs_user}
  def transition(:checkpointing, {:run_terminal, :completed}), do: {:ok, :completed}
  def transition(:checkpointing, {:run_terminal, :failed}), do: {:ok, :failed}
  def transition(:checkpointing, {:run_terminal, :needs_user}), do: {:ok, :needs_user}

  # Legacy outcome-less recycle (deprecated, preserved for T1/T3 callers
  # that drive terminals without an outcome class): re-enter evaluation.
  def transition(:working, :run_terminal), do: {:ok, :evaluating}
  def transition(:checkpointing, :run_terminal), do: {:ok, :evaluating}

  # A goal waiting on its operator stays put on a repeated needs_user
  # outcome; the attribution-gated respond path resolves the pending
  # command (abandoned / released / rejected) and returns the goal to
  # evaluation. Admission re-evaluation stays available while waiting.
  def transition(:needs_user, {:command_outcome, :needs_user}), do: {:ok, :needs_user}
  def transition(:needs_user, {:command_outcome, :abandoned}), do: {:ok, :evaluating}
  def transition(:needs_user, {:command_outcome, :released}), do: {:ok, :evaluating}
  def transition(:needs_user, {:command_outcome, :rejected}), do: {:ok, :evaluating}
  def transition(:needs_user, {:admission_decision, :admit}), do: {:ok, :queued}
  def transition(:needs_user, {:admission_decision, :defer_until}), do: {:ok, :sleeping}

  def transition(:needs_user, {:admission_decision, :require_confirmation}),
    do: {:ok, :needs_user}

  def transition(:needs_user, {:admission_decision, :reject}), do: {:ok, :handing_off}

  # Explicit wake-up only: no timer may wake a sleeping goal by itself.
  def transition(:sleeping, :recheck_due), do: {:ok, :evaluating}

  # Explicit handoff from any non-terminal state. Completed/failed stay
  # terminal (like handing_off); needs_user may hand off while waiting.
  def transition(state, :handoff_requested)
      when state in [
             :evaluating,
             :queued,
             :dispatching,
             :working,
             :checkpointing,
             :sleeping,
             :needs_user
           ],
      do: {:ok, :handing_off}

  def transition(state, event)
      when state in @states and
             (event in [
                :dispatch_started,
                :dispatch_blocked,
                :checkpoint_started,
                :checkpoint_done,
                :run_terminal,
                :recheck_due,
                :handoff_requested
              ] or
                (is_tuple(event) and tuple_size(event) == 2 and
                   (elem(event, 0) == :admission_decision or
                      elem(event, 0) == :command_outcome or
                      elem(event, 0) == :run_terminal))),
      do: {:error, {:invalid_transition, state, event}}

  def transition(state, event), do: {:error, {:invalid_transition, state, event}}

  @doc """
  Maps an admission decision result to its lifecycle event.

  Accepts `Shoestring.Cobbler.AdmissionDecision` structs (whose `result` is
  an atom) as well as raw result atoms and strings.
  """
  @spec decision_event(Shoestring.Cobbler.AdmissionDecision.t() | atom() | String.t()) ::
          {:ok, event()} | {:error, term()}
  def decision_event(%Shoestring.Cobbler.AdmissionDecision{result: result}),
    do: decision_event(result)

  def decision_event(result) when result in @admission_results,
    do: {:ok, {:admission_decision, result}}

  def decision_event(result) when is_binary(result) do
    try do
      decision_event(String.to_existing_atom(result))
    rescue
      ArgumentError -> {:error, {:unknown_admission_result, result}}
    end
  end

  def decision_event(result), do: {:error, {:unknown_admission_result, result}}

  @doc """
  Maps a persisted command row to its lifecycle event, reading the recorded
  result kind (`Shoestring.Cobbler.CommandRecord.result["kind"]`).
  """
  @spec command_event(Shoestring.Cobbler.CommandRecord.t()) :: {:ok, event()} | {:error, term()}
  def command_event(%Shoestring.Cobbler.CommandRecord{result: %{"kind" => kind}}) do
    try do
      outcome = String.to_existing_atom(kind)

      if outcome in @command_outcomes do
        {:ok, {:command_outcome, outcome}}
      else
        {:error, {:unknown_command_outcome, kind}}
      end
    rescue
      ArgumentError -> {:error, {:unknown_command_outcome, kind}}
    end
  end

  def command_event(%Shoestring.Cobbler.CommandRecord{result: result}),
    do: {:error, {:unknown_command_outcome, result}}

  @doc """
  Maps a run outcome class to its lifecycle event.

  Accepts outcome atoms and strings (`"completed"`, `"failed"`,
  `"needs_user"`). Unknown values return an error. Callers driving
  outcome-less terminals keep emitting the bare `:run_terminal` atom
  directly (legacy recycle path).
  """
  @spec run_terminal_event(run_outcome() | String.t()) ::
          {:ok, event()} | {:error, term()}
  def run_terminal_event(outcome) when outcome in @run_outcomes,
    do: {:ok, {:run_terminal, outcome}}

  def run_terminal_event(outcome) when is_binary(outcome) do
    try do
      run_terminal_event(String.to_existing_atom(outcome))
    rescue
      ArgumentError -> {:error, {:unknown_run_outcome, outcome}}
    end
  end

  def run_terminal_event(outcome), do: {:error, {:unknown_run_outcome, outcome}}

  @doc """
  Applies an admission decision struct directly to a goal state.
  """
  @spec apply_decision(state(), Shoestring.Cobbler.AdmissionDecision.t() | atom() | String.t()) ::
          {:ok, state()} | {:error, term()}
  def apply_decision(state, decision) do
    with {:ok, event} <- decision_event(decision), do: transition(state, event)
  end

  @doc """
  Applies a persisted command row directly to a goal state.
  """
  @spec apply_command(state(), Shoestring.Cobbler.CommandRecord.t()) ::
          {:ok, state()} | {:error, term()}
  def apply_command(state, command) do
    with {:ok, event} <- command_event(command), do: transition(state, event)
  end
end
