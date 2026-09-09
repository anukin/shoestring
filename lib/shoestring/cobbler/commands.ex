defmodule Shoestring.Cobbler.Commands do
  @moduledoc """
  Durable, goal-scoped Cobbler command store: submit, respond, inspect, rebuild.

  ## Boundary semantics

  - **Durable goal-scoped command ids.** A command id is unique per goal
    (enforced by a unique index). The id, type, payload, and digest are
    persisted together with the outcome.
  - **Identical replay, conflicting reuse.** Re-submitting the same command
    id with an identical digest returns the originally recorded result and
    appends no events. The same command id with a different digest is
    rejected as a conflict. `respond/4` applies the same rule to user
    responses.
  - **Validated legal transitions.** Every persisted transition passes the
    pure `Shoestring.Cobbler.Command` state machine; illegal transitions are
    rejected and never persisted.
  - **Recoverable needs_user.** A command that requires an operator decision
    is recorded as `needs_user` with its reason and offered options. A
    validated response resolves it; an unoffered response changes nothing, so
    the command stays recoverable.
  - **Atomic intent/transition/result.** The command row, any claim row, and
    the canonical trajectory events commit in ONE immediate SQLite write
    transaction or not at all; there is no pending intent without a result
    and no result without its events.
  - **Trajectory rebuild.** Command and claim state is recomputed purely
    from canonical `cobbler.*` events; `rebuild/2` reports divergence from
    stored rows without mutating anything.
  - **Exclusive global MVP claim.** Claim acquisition inserts a row covered
    by a partial unique index on `scope` over active claims inside an
    immediate write transaction. SQLite rejects the second concurrent
    writer on that index; commands never count claims first.
  - **No timed release.** An active claim is released only by an explicit
    release command against the owning goal. There is no expiry, no
    staleness trigger, and no release on ambiguous restart.
  - **Execution disabled.** Submitting, responding to, or inspecting commands
    never spawns a process, enqueues a job, or dispatches at startup. The
    first gated consumer is `Shoestring.Cobbler.Dispatcher`, which reads
    command rows and stops at an explicit execution-disabled boundary.
    Direct run paths (Elves, harness adapters, dispatch) accept an opt-in
    `require_cobbler_command: true` guard
    (`Shoestring.Cobbler.DispatchGate`); without the flag they still do not
    route through commands.

  ## Event appends inside the store transaction

  Unlike the per-goal `Shoestring.Trajectory.Writer` process (a separate
  transaction that would deadlock against this one), this store constructs
  the trusted event identity and sequence fields itself, inside the same
  immediate write transaction as the command and claim rows. Sequence
  assignment is safe because SQLite serializes write transactions;
  concurrent writer appends retry on the busy lock and re-read the sequence.
  Payload validation still goes through
  `Shoestring.Trajectory.EventRegistry.validate_payload/4`, and inserts go
  through the same `Shoestring.Trajectory.TrajectoryEvent.changeset/2`
  constraint path the writer uses.
  """

  import Ecto.Query
  require Logger

  alias Shoestring.Cobbler.{Command, CommandRecord, TaskClaimRecord}
  alias Shoestring.Harness.Contract
  alias Shoestring.Repo
  alias Shoestring.Trajectory.Goal
  alias Shoestring.Trajectory.{EventRegistry, TrajectoryEvent}

  @actor "cobbler"
  @schema_version 1

  @claim_event_types ["cobbler.claim.acquired", "cobbler.claim.released"]

  @event_types ["cobbler.command.accepted", "cobbler.command.resolved"] ++ @claim_event_types

  @type submit_result :: %{
          required(:command) => CommandRecord.t(),
          required(:outcome) => :recorded | :replayed,
          required(:events) => [TrajectoryEvent.t()]
        }

  # ----------------------------------------------------------------------------
  # Submission
  # ----------------------------------------------------------------------------

  @doc """
  Records a command outcome for a goal-scoped command id.

  Returns `{:ok, %{command: row, outcome: :recorded | :replayed, events: []}}`.
  A replay carries the original result with an empty event list.
  """
  @spec submit(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, submit_result()} | {:error, term()}
  def submit(goal_id, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, normalized_goal_id} <- cast_goal_id(goal_id),
         {:ok, %Command{} = command} <- Command.new(attrs),
         true <- repo_exists?(repo, normalized_goal_id) || {:error, :goal_not_found} do
      run_transaction(repo, fn ->
        accept_transaction(normalized_goal_id, command, repo, now(opts))
      end)
      |> case do
        {:ok, %{command: command_row, outcome: outcome, events: events}} ->
          publish(events, opts)
          {:ok, %{command: command_row, outcome: outcome, events: events}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :goal_not_found}
      error -> error
    end
  end

  defp accept_transaction(goal_id, command, repo, now) do
    case existing_command(repo, goal_id, command.command_id) do
      %CommandRecord{digest: digest} = existing when digest == command.digest ->
        %{command: existing, outcome: :replayed, events: []}

      %CommandRecord{digest: existing_digest} ->
        repo.rollback(
          {:command_conflict,
           %{
             "command_id" => command.command_id,
             "existing_digest" => existing_digest,
             "incoming_digest" => command.digest
           }}
        )

      nil ->
        record_new_command(goal_id, command, repo, now)
    end
  end

  defp record_new_command(goal_id, command, repo, now) do
    {status, result, extra_events, claim_id} = evaluate(command, repo, goal_id, now)
    :ok = Command.transition(:pending, :accept, status)

    events =
      append_events_in_transaction(
        repo,
        goal_id,
        accepted_events(goal_id, command, status, result, claim_id) ++ extra_events,
        now
      )

    command_row =
      %CommandRecord{}
      |> CommandRecord.outcome_changeset(
        goal_id,
        command,
        Command.status_string(status),
        result,
        now
      )
      |> repo.insert()
      |> case do
        {:ok, row} -> row
        {:error, changeset} -> repo.rollback({:command_record_failed, changeset})
      end

    %{command: command_row, outcome: :recorded, events: events}
  end

  # ----------------------------------------------------------------------------
  # Command handlers
  # ----------------------------------------------------------------------------

  defp evaluate(%Command{type: "task.claim"} = command, repo, goal_id, now) do
    case do_active_claim(repo) do
      %TaskClaimRecord{} = claim ->
        {:needs_user, needs_user_result("claim_held", claim), [], nil}

      nil ->
        with {:ok, decision} <- validate_admission_reference(repo, goal_id, command) do
          acquire_claim(repo, goal_id, command, decision, now)
        else
          {:rejected, reason} -> {:rejected, rejected_result(reason, command), [], nil}
        end
    end
  end

  defp evaluate(%Command{type: "task.release"} = command, repo, goal_id, now) do
    case do_active_claim(repo) do
      nil ->
        {:resolved, %{"kind" => "no_active_claim"}, [], nil}

      %TaskClaimRecord{goal_id: ^goal_id} = claim ->
        release_claim(repo, claim, command, now)

      %TaskClaimRecord{} = claim ->
        {:rejected,
         %{
           "kind" => "rejected",
           "reason" => "claim_owned_by_other_goal",
           "claim_goal_id" => claim.goal_id
         }, [], nil}
    end
  end

  defp acquire_claim(repo, goal_id, command, decision, now) do
    claim_changeset =
      TaskClaimRecord.acquire_changeset(
        goal_id,
        command.command_id,
        %{
          intent: command.payload["intent"],
          provider_id: command.payload["candidate"]["provider_id"]
        },
        decision.decision_id,
        command.payload["admission_event_id"],
        now
      )

    case repo.insert(claim_changeset) do
      {:ok, claim} ->
        claimed = %{
          "kind" => "claimed",
          "claim_id" => claim.id,
          "intent" => claim.intent,
          "provider_id" => claim.provider_id,
          "admission_decision_id" => claim.admission_decision_id,
          "admission_event_id" => claim.admission_event_id
        }

        {:resolved, claimed, [claim_acquired_event(claim)], claim.id}

      {:error, changeset} ->
        # Inside the same immediate write transaction the read-first check
        # cannot miss a claim, but if the partial unique index ever rejects
        # the insert the claim demonstrably exists: degrade to the
        # recoverable needs_user outcome instead of failing the command.
        case do_active_claim(repo) do
          %TaskClaimRecord{} = claim ->
            {:needs_user, needs_user_result("claim_held", claim), [], nil}

          nil ->
            repo.rollback({:claim_insert_failed, changeset})
        end
    end
  end

  defp release_claim(repo, claim, command, now) do
    released =
      claim
      |> TaskClaimRecord.release_changeset(command.command_id, command.payload["reason"], now)
      |> repo.update()
      |> case do
        {:ok, released} -> released
        {:error, changeset} -> repo.rollback({:claim_release_failed, changeset})
      end

    {:resolved,
     %{
       "kind" => "released",
       "claim_id" => released.id,
       "reason" => released.release_reason
     }, [claim_released_event(released, command.command_id)], released.id}
  end

  defp needs_user_result(reason, claim) do
    %{
      "kind" => "needs_user",
      "reason" => reason,
      "options" => Command.response_options(reason),
      "active_claim" => %{
        "claim_id" => claim.id,
        "goal_id" => claim.goal_id,
        "command_id" => claim.command_id,
        "intent" => claim.intent,
        "provider_id" => claim.provider_id
      }
    }
  end

  defp rejected_result(reason, command) do
    %{
      "kind" => "rejected",
      "reason" => reason,
      "admission_event_id" => command.payload["admission_event_id"]
    }
  end

  @doc """
  Validates the admitted decision referenced by a claim command: the
  trajectory event must exist in the same goal, be an `admission.decided` v1
  event, and carry the same intent, scope, and candidate before any claim can
  be attempted.
  """
  @spec validate_admission_reference(module(), Ecto.UUID.t(), Command.t()) ::
          {:ok, %{decision_id: String.t(), occurred_at: DateTime.t()}} | {:rejected, String.t()}
  def validate_admission_reference(repo, goal_id, command) do
    event_id = command.payload["admission_event_id"]

    event =
      repo.one(
        from trajectory_event in TrajectoryEvent,
          where: trajectory_event.id == ^event_id and trajectory_event.goal_id == ^goal_id
      )

    cond do
      is_nil(event) ->
        {:rejected, "admission_event_not_found"}

      event.type != "admission.decided" ->
        {:rejected, "admission_event_type_invalid"}

      event.schema_version != @schema_version ->
        {:rejected, "admission_event_schema_unsupported"}

      true ->
        validate_admission_payload(event, command)
    end
  end

  defp validate_admission_payload(event, command) do
    payload = event.payload || %{}
    candidate = command.payload["candidate"]

    cond do
      blank?(payload["decision_id"]) ->
        {:rejected, "admission_decision_id_missing"}

      payload["requested_capability"] != command.payload["intent"] ->
        {:rejected, "admission_intent_mismatch"}

      payload["scope"] != command.payload["scope"] ->
        {:rejected, "admission_scope_mismatch"}

      payload_candidate(payload) != candidate ->
        {:rejected, "admission_candidate_mismatch"}

      true ->
        {:ok, %{decision_id: payload["decision_id"], occurred_at: event.occurred_at}}
    end
  end

  defp payload_candidate(%{"candidate" => candidate}) when is_map(candidate) do
    %{
      "provider_id" => candidate["provider_id"],
      "adapter_id" => candidate["adapter_id"]
    }
  end

  defp payload_candidate(_payload), do: nil

  # ----------------------------------------------------------------------------
  # Response (needs_user recovery)
  # ----------------------------------------------------------------------------

  @doc """
  Resolves a `needs_user` command with a validated, attributed operator response.

  Every new response MUST carry a non-blank `confirmed_by` identity
  (fail-closed as `{:error, {:confirmation_invalid_responder, detail}}`;
  automated callers pass an explicit `system:`-prefixed identity such as
  `"system:wakeup"` — never a silently defaulted human). The optional
  `intent` confirmation is persisted where carried but matched at the UI
  boundary, not here.

  An identical response replays the recorded resolution without appending
  events; a different response is rejected as a conflict; an unoffered
  response option leaves the command in `needs_user` unchanged.
  """
  @spec respond(Ecto.UUID.t(), String.t(), map(), keyword()) ::
          {:ok, submit_result()} | {:error, term()}
  def respond(goal_id, command_id, response_attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, normalized_goal_id} <- cast_goal_id(goal_id),
         {:ok, response} <- validate_response(response_attrs),
         {:ok, %CommandRecord{} = existing} <- fetch_command(repo, normalized_goal_id, command_id) do
      response_digest = Command.response_digest(response)

      case Command.status_atom(existing.status) do
        :needs_user ->
          # The only persisted respond target is :resolved; the machine check
          # keeps the transition table load-bearing even if targets grow.
          :ok = Command.transition(:needs_user, :respond, :resolved)
          resolve_response(existing, response, response_digest, repo, now(opts), opts)

        :resolved ->
          cond do
            existing.response_digest == response_digest ->
              # A repeated identical response (e.g. after an ambiguous
              # restart) replays the recorded resolution without appending
              # events.
              {:ok, %{command: existing, outcome: :replayed, events: []}}

            is_nil(existing.response_digest) ->
              {:error, {:illegal_respond, %{"command_id" => command_id, "status" => "resolved"}}}

            true ->
              {:error,
               {:response_conflict,
                %{
                  "command_id" => command_id,
                  "existing_digest" => existing.response_digest,
                  "incoming_digest" => response_digest
                }}}
          end

        status ->
          {:error,
           {:illegal_respond, %{"command_id" => command_id, "status" => to_string(status)}}}
      end
    end
  end

  defp resolve_response(existing, response, response_digest, repo, now, opts) do
    if existing.response_digest && existing.response_digest != response_digest do
      {:error,
       {:response_conflict,
        %{
          "command_id" => existing.command_id,
          "existing_digest" => existing.response_digest,
          "incoming_digest" => response_digest
        }}}
    else
      case Command.resolution(existing.result["reason"], response["resolution"]) do
        {:ok, kind} ->
          record_response(existing, response, response_digest, kind, repo, now, opts)

        {:error, :invalid_response} ->
          {:error, {:invalid_response, Command.response_options(existing.result["reason"])}}
      end
    end
  end

  defp record_response(existing, response, response_digest, kind, repo, now, opts) do
    result = %{
      "kind" => kind,
      "reason" => existing.result["reason"],
      "resolved_by" => "user_response"
    }

    confirmed_by = response["confirmed_by"]
    confirmed_intent = response["intent"]

    run_transaction(repo, fn ->
      events =
        append_events_in_transaction(
          repo,
          existing.goal_id,
          [
            %{
              "type" => "cobbler.command.resolved",
              "idempotency_key" =>
                "cobbler-command-resolved:#{existing.goal_id}:#{existing.command_id}",
              "payload" =>
                %{
                  "command_id" => existing.command_id,
                  "command_type" => existing.type,
                  "response" => response,
                  "response_digest" => response_digest,
                  "from_status" => "needs_user",
                  "to_status" => "resolved",
                  "result" => result
                }
                |> maybe_put("confirmed_by", confirmed_by)
                |> maybe_put("confirmed_intent", confirmed_intent)
            }
          ],
          now
        )

      command_row =
        existing
        |> CommandRecord.response_changeset(response, response_digest, "resolved", result, now, %{
          "confirmed_by" => confirmed_by,
          "confirmed_intent" => confirmed_intent
        })
        |> repo.update()
        |> case do
          {:ok, row} -> row
          {:error, changeset} -> repo.rollback({:command_update_failed, changeset})
        end

      %{command: command_row, outcome: :recorded, events: events}
    end)
    |> case do
      {:ok, %{command: command_row, outcome: outcome, events: events}} ->
        publish(events, opts)
        {:ok, %{command: command_row, outcome: outcome, events: events}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # STRICT (P1): every new response must carry a non-blank confirmed_by
  # identity. nil/missing/blank is rejected fail-closed BEFORE any write
  # with {:error, {:confirmation_invalid_responder, detail}} — a reason
  # distinct from response_conflict, following the confirmation_invalid_*
  # code family from admission. Attribution rides inside the digest-covered
  # response map (P4), so the existing response_digest pair semantics
  # ({response, response_digest} both set together) also cover who
  # confirmed. Automated callers pass an explicit system:-prefixed identity
  # (P2); the domain never silently defaults a human identity.
  defp validate_response(response) when is_map(response) do
    with {:ok, resolution} <- validate_resolution(response),
         {:ok, confirmed_by} <- validate_confirmed_by(response),
         {:ok, intent} <- validate_response_intent(response) do
      normalized =
        %{"resolution" => resolution, "confirmed_by" => confirmed_by}
        |> maybe_put("intent", intent)

      {:ok, normalized}
    end
  end

  defp validate_response(_response), do: Contract.invalid(:response, "must be an object")

  defp validate_resolution(response) do
    case Contract.fetch(response, :resolution) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _other} ->
        Contract.invalid(:resolution, "must be a string")

      :error ->
        Contract.invalid(:resolution, "can't be blank")
    end
  end

  defp validate_confirmed_by(response) do
    case Contract.fetch(response, :confirmed_by) do
      {:ok, value} when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          {:error, {:confirmation_invalid_responder, %{"reason" => "unattributed"}}}
        else
          {:ok, trimmed}
        end

      _missing_or_nil ->
        {:error, {:confirmation_invalid_responder, %{"reason" => "unattributed"}}}
    end
  end

  # The intent confirmation is carried, not matched, here: the UI boundary
  # enforces the match against the command payload intent. Absent or blank
  # intent persists as nil; only a non-string or overlong value is rejected.
  defp validate_response_intent(response) do
    case Contract.fetch(response, :intent) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" -> {:ok, nil}
          String.length(trimmed) > 200 -> invalid_intent()
          true -> {:ok, trimmed}
        end

      {:ok, _other} ->
        invalid_intent()
    end
  end

  defp invalid_intent,
    do: {:error, {:confirmation_invalid_responder, %{"reason" => "invalid_intent"}}}

  # ----------------------------------------------------------------------------
  # Inspection
  # ----------------------------------------------------------------------------

  @doc "Returns the command row for a goal-scoped command id, or nil."
  @spec get(Ecto.UUID.t(), String.t(), keyword()) :: CommandRecord.t() | nil
  def get(goal_id, command_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case cast_goal_id(goal_id) do
      {:ok, normalized_goal_id} -> existing_command(repo, normalized_goal_id, command_id)
      _error -> nil
    end
  end

  @doc "Lists command rows for a goal in insertion order."
  @spec list(Ecto.UUID.t(), keyword()) :: [CommandRecord.t()]
  def list(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case cast_goal_id(goal_id) do
      {:ok, normalized_goal_id} ->
        repo.all(
          from command in CommandRecord,
            where: command.goal_id == ^normalized_goal_id,
            order_by: [asc: command.inserted_at, asc: command.id]
        )

      _error ->
        []
    end
  end

  @doc """
  Lists pending operator decisions for a goal: commands recorded as
  `needs_user`. Pending commands are inert; this function only reads.
  """
  @spec pending(Ecto.UUID.t(), keyword()) :: [CommandRecord.t()]
  def pending(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case cast_goal_id(goal_id) do
      {:ok, normalized_goal_id} ->
        repo.all(
          from command in CommandRecord,
            where: command.goal_id == ^normalized_goal_id and command.status == "needs_user",
            order_by: [asc: command.inserted_at, asc: command.id]
        )

      _error ->
        []
    end
  end

  @doc "Returns the single active global task claim, or nil."
  @spec active_claim(keyword()) :: TaskClaimRecord.t() | nil
  def active_claim(opts \\ []) do
    do_active_claim(Keyword.get(opts, :repo, Repo))
  end

  # ----------------------------------------------------------------------------
  # Rebuild
  # ----------------------------------------------------------------------------

  @doc """
  Rebuilds command and claim state purely from canonical `cobbler.*` events
  and reports divergence from the stored rows without mutating anything.

  Returns
  `{:ok, %{commands: [map()], claim: map() | nil, consistent?: boolean(), divergences: [String.t()]}}`.
  """
  @spec rebuild(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             commands: [map()],
             claim: map() | nil,
             consistent?: boolean(),
             divergences: [String.t()]
           }}
          | {:error, term()}
  def rebuild(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, normalized_goal_id} <- cast_goal_id(goal_id),
         events <- fetch_command_events(repo, normalized_goal_id),
         :ok <- validate_history(events),
         {:ok, rebuilt} <- fold_events(events) do
      stored_commands = list(normalized_goal_id, opts)
      divergences = divergences(rebuilt, stored_commands, do_active_claim(repo))

      {:ok,
       %{
         commands: Map.values(rebuilt.commands),
         claim: rebuilt.claim,
         consistent?: divergences == [],
         divergences: divergences
       }}
    end
  end

  defp fetch_command_events(repo, goal_id) do
    repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type in @event_types,
        order_by: [asc: event.sequence]
    )
  end

  defp validate_history(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case EventRegistry.validate(event_attributes(event)) do
        {:ok, _validated} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp fold_events(events) do
    Enum.reduce_while(events, {:ok, %{commands: %{}, claim: nil}}, fn event, {:ok, state} ->
      case fold_event(state, event) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fold_event(state, %TrajectoryEvent{type: "cobbler.command.accepted"} = event) do
    payload = event.payload

    with :ok <- Command.transition(:pending, :accept, Command.status_atom(payload["to_status"])) do
      command_state = %{
        "command_id" => payload["command_id"],
        "type" => payload["command_type"],
        "digest" => payload["command_digest"],
        "payload" => payload["command_payload"],
        "status" => payload["to_status"],
        "result" => payload["result"],
        "response" => nil,
        "response_digest" => nil,
        "confirmed_by" => nil,
        "confirmed_intent" => nil
      }

      {:ok, put_in(state, [:commands, payload["command_id"]], command_state)}
    else
      {:error, {:invalid_transition, from, to}} ->
        {:error, {:rebuild_transition_invalid, event.sequence, from, to}}
    end
  end

  defp fold_event(state, %TrajectoryEvent{type: "cobbler.command.resolved"} = event) do
    payload = event.payload
    command_id = payload["command_id"]

    with {:ok, prior} <- rebuilt_command(state, command_id, event),
         :ok <- Command.transition(Command.status_atom(prior["status"]), :respond, :resolved) do
      # P3: pre-attribution events carry neither top-level attribution nor
      # response-embedded attribution; both fall back to nil and still
      # rebuild. New events carry top-level mirrors of the digest-covered
      # response attribution.
      resolved =
        prior
        |> Map.put("status", payload["to_status"])
        |> Map.put("result", payload["result"])
        |> Map.put("response", payload["response"])
        |> Map.put("response_digest", payload["response_digest"])
        |> Map.put(
          "confirmed_by",
          payload["confirmed_by"] || get_in(payload, ["response", "confirmed_by"])
        )
        |> Map.put(
          "confirmed_intent",
          payload["confirmed_intent"] || get_in(payload, ["response", "intent"])
        )

      {:ok, put_in(state, [:commands, command_id], resolved)}
    else
      {:error, {:invalid_transition, from, to}} ->
        {:error, {:rebuild_transition_invalid, event.sequence, from, to}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fold_event(state, %TrajectoryEvent{type: "cobbler.claim.acquired"} = event) do
    payload = event.payload

    if state.claim do
      {:error, {:rebuild_claim_conflict, event.sequence, payload["claim_id"]}}
    else
      {:ok,
       %{
         state
         | claim: %{
             "claim_id" => payload["claim_id"],
             "goal_id" => event.goal_id,
             "command_id" => payload["command_id"],
             "intent" => payload["intent"],
             "provider_id" => payload["provider_id"],
             "admission_decision_id" => payload["admission_decision_id"],
             "status" => "active"
           }
       }}
    end
  end

  defp fold_event(
         state,
         %TrajectoryEvent{
           type: "cobbler.claim.released",
           payload: %{"claim_id" => released_claim_id}
         } =
           event
       ) do
    case state.claim do
      %{"claim_id" => ^released_claim_id, "status" => "active"} = claim ->
        {:ok, %{state | claim: %{claim | "status" => "released"}}}

      _other ->
        {:error, {:rebuild_release_without_active_claim, event.sequence}}
    end
  end

  defp rebuilt_command(state, command_id, event) do
    case Map.fetch(state.commands, command_id) do
      {:ok, prior} -> {:ok, prior}
      :error -> {:error, {:rebuild_resolved_without_accepted, event.sequence, command_id}}
    end
  end

  defp divergences(rebuilt, stored_commands, stored_active_claim) do
    rebuilt_by_id = rebuilt.commands
    stored_ids = MapSet.new(stored_commands, & &1.command_id)

    row_divergences =
      Enum.flat_map(stored_commands, fn row ->
        case Map.get(rebuilt_by_id, row.command_id) do
          nil ->
            ["command #{row.command_id} persisted without canonical events"]

          rebuilt_command ->
            if canonical(row.status) == canonical(rebuilt_command["status"]) and
                 canonical(row.result) == canonical(rebuilt_command["result"]) and
                 canonical(row.digest) == canonical(rebuilt_command["digest"]) and
                 canonical(row.response) == canonical(rebuilt_command["response"]) and
                 row.response_digest == rebuilt_command["response_digest"] and
                 row.confirmed_by == rebuilt_command["confirmed_by"] and
                 row.confirmed_intent == rebuilt_command["confirmed_intent"] do
              []
            else
              ["command #{row.command_id} diverges from canonical events"]
            end
        end
      end)

    event_only_divergences =
      for command_id <- Map.keys(rebuilt_by_id),
          not MapSet.member?(stored_ids, command_id) do
        "canonical events for command #{command_id} have no persisted row"
      end

    row_divergences ++
      event_only_divergences ++ claim_divergences(rebuilt.claim, stored_active_claim)
  end

  defp claim_divergences(rebuilt_claim, stored_active_claim) do
    rebuilt_active =
      if rebuilt_claim && rebuilt_claim["status"] == "active", do: rebuilt_claim, else: nil

    cond do
      is_nil(rebuilt_active) and is_nil(stored_active_claim) ->
        []

      is_nil(rebuilt_active) ->
        ["persisted active claim has no canonical acquisition event"]

      is_nil(stored_active_claim) ->
        ["canonical active claim has no persisted active claim row"]

      rebuilt_active["claim_id"] != stored_active_claim.id ->
        ["canonical active claim diverges from persisted active claim row"]

      rebuilt_active["command_id"] != stored_active_claim.command_id ->
        ["canonical active claim diverges from persisted active claim row"]

      true ->
        []
    end
  end

  # ----------------------------------------------------------------------------
  # In-transaction event append
  # ----------------------------------------------------------------------------

  defp accepted_events(goal_id, command, status, result, claim_id) do
    payload =
      %{
        "command_id" => command.command_id,
        "command_type" => command.type,
        "command_digest" => command.digest,
        "command_payload" => command.payload,
        "from_status" => "pending",
        "to_status" => Command.status_string(status),
        "result" => result
      }
      |> maybe_put("claim_id", claim_id)

    [
      %{
        "type" => "cobbler.command.accepted",
        "idempotency_key" => "cobbler-command-accepted:#{goal_id}:#{command.command_id}",
        "payload" => payload
      }
    ]
  end

  defp claim_acquired_event(claim) do
    %{
      "type" => "cobbler.claim.acquired",
      "idempotency_key" => "cobbler-claim-acquired:#{claim.id}",
      "payload" => %{
        "claim_id" => claim.id,
        "command_id" => claim.command_id,
        "intent" => claim.intent,
        "provider_id" => claim.provider_id,
        "admission_decision_id" => claim.admission_decision_id,
        "admission_event_id" => claim.admission_event_id
      }
    }
  end

  defp claim_released_event(claim, command_id) do
    %{
      "type" => "cobbler.claim.released",
      "idempotency_key" => "cobbler-claim-released:#{claim.id}",
      "payload" => %{
        "claim_id" => claim.id,
        "command_id" => command_id,
        "reason" => claim.release_reason
      }
    }
  end

  defp append_events_in_transaction(repo, goal_id, event_inputs, now) do
    base_sequence = next_sequence(repo, goal_id)

    Enum.with_index(event_inputs, fn input, index ->
      append_one_event(repo, goal_id, input, base_sequence + index, now)
    end)
  end

  defp append_one_event(repo, goal_id, input, sequence, now) do
    try do
      with {:ok, payload} <-
             EventRegistry.validate_payload(input["type"], @schema_version, input["payload"],
               now: now
             ),
           {:ok, event} <- insert_event(repo, goal_id, input, payload, sequence, now) do
        event
      else
        {:error, reason} -> repo.rollback({:event_append_failed, input["type"], reason})
      end
    rescue
      # SQLite reports unnamed FOREIGN KEY violations with a nil constraint
      # name that Ecto cannot map to a changeset error; catch the raise so
      # the whole store transaction still rolls back with a clean reason.
      error in [Ecto.ConstraintError] ->
        repo.rollback({:event_append_failed, input["type"], error})
    end
  end

  defp insert_event(repo, goal_id, input, payload, sequence, now) do
    event = %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: goal_id,
      task_id: nil,
      run_id: nil,
      sequence: sequence,
      parent_event_id: nil,
      type: input["type"],
      actor: @actor,
      occurred_at: now,
      schema_version: @schema_version,
      payload: payload,
      idempotency_key: input["idempotency_key"]
    }

    event
    |> TrajectoryEvent.changeset(%{})
    |> repo.insert()
  end

  defp repo_exists?(repo, goal_id) do
    repo.exists?(from goal in Goal, where: goal.id == ^goal_id)
  end

  defp next_sequence(repo, goal_id) do
    last =
      repo.one(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal_id,
          select: max(event.sequence)
      ) || 0

    last + 1
  end

  # ----------------------------------------------------------------------------
  # Shared helpers
  # ----------------------------------------------------------------------------

  defp run_transaction(repo, fun) do
    repo.transaction(fun, transaction_opts())
  end

  defp existing_command(repo, goal_id, command_id) do
    repo.one(
      from command in CommandRecord,
        where: command.goal_id == ^goal_id and command.command_id == ^command_id
    )
  end

  defp fetch_command(repo, goal_id, command_id) do
    case existing_command(repo, goal_id, command_id) do
      %CommandRecord{} = row -> {:ok, row}
      nil -> {:error, :command_not_found}
    end
  end

  defp do_active_claim(repo) do
    repo.one(from claim in TaskClaimRecord, where: claim.status == "active")
  end

  defp event_attributes(event) do
    %{
      id: event.id,
      goal_id: event.goal_id,
      task_id: event.task_id,
      run_id: event.run_id,
      sequence: event.sequence,
      parent_event_id: event.parent_event_id,
      type: event.type,
      actor: event.actor,
      occurred_at: event.occurred_at,
      schema_version: event.schema_version,
      payload: event.payload,
      idempotency_key: event.idempotency_key
    }
  end

  defp publish(events, opts) do
    publish_fun = Keyword.get(opts, :publish_fun, &default_publish/1)
    Enum.each(events, publish_fun)
  end

  defp default_publish(event) do
    Phoenix.PubSub.broadcast(Shoestring.PubSub, Shoestring.Trajectory.topic(event.goal_id), {
      :trajectory_event_committed,
      event
    })
  rescue
    error ->
      # The command and its events are already durably committed; a PubSub
      # hiccup must not fail the recorded outcome.
      Logger.warning("cobbler command event publish failed: #{Exception.message(error)}")
  end

  defp transaction_opts, do: [mode: :immediate]

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> DateTime.truncate(now, :microsecond)
      _other -> DateTime.truncate(DateTime.utc_now(), :microsecond)
    end
  end

  defp cast_goal_id(goal_id) do
    case Ecto.UUID.cast(goal_id) do
      {:ok, normalized_goal_id} -> {:ok, normalized_goal_id}
      :error -> {:error, {:invalid_goal_id, goal_id}}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_other), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp canonical(term) when is_map(term) do
    term
    |> Map.new(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort(fn {left, _}, {right, _} -> left <= right end)
  end

  defp canonical(term) when is_list(term), do: Enum.map(term, &canonical/1)
  defp canonical(term), do: term
end
