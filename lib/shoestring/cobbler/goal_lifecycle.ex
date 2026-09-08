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
  - `:handing_off` - terminal. The goal leaves automated handling (rejected
    candidate, explicit operator handoff). Nothing transitions out.

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
  - `:checkpoint_started` / `:checkpoint_done`, `:run_terminal`,
    `:recheck_due`, `:handoff_requested`.

  All functions are pure: no processes, no database, no clocks.
  """

  @states [
    :evaluating,
    :queued,
    :dispatching,
    :working,
    :checkpointing,
    :sleeping,
    :handing_off
  ]

  @admission_results [:admit, :defer_until, :require_confirmation, :reject]

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
          | :handing_off

  @type admission_result :: :admit | :defer_until | :require_confirmation | :reject

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
          | :recheck_due
          | :handoff_requested

  @doc "All goal lifecycle states."
  @spec states() :: [state()]
  def states, do: @states

  @doc "The initial state of a goal before any admission decision."
  @spec initial() :: state()
  def initial, do: :evaluating

  @doc "Returns true only for terminal goal states."
  @spec terminal?(state()) :: boolean()
  def terminal?(:handing_off), do: true
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
  def transition(:working, :run_terminal), do: {:ok, :evaluating}
  def transition(:checkpointing, :run_terminal), do: {:ok, :evaluating}

  # Explicit wake-up only: no timer may wake a sleeping goal by itself.
  def transition(:sleeping, :recheck_due), do: {:ok, :evaluating}

  # Explicit handoff from any non-terminal state.
  def transition(state, :handoff_requested)
      when state in [:evaluating, :queued, :dispatching, :working, :checkpointing, :sleeping],
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
                      elem(event, 0) == :command_outcome))),
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
