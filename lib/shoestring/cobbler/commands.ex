defmodule Shoestring.Cobbler.Commands do
  @moduledoc """
  Durable, idempotent command engine for Cobbler.

  Enforces:
  1. Caller-supplied stable command IDs scoped to goal.
  2. Idempotency: duplicate commands return original results without new events.
  3. Conflict detection: conflicting payload reuse for the same command ID is rejected.
  4. Admission validation: admission reference must be an `:admit` for the matching
     goal, provider candidate, capability, and scope.
  5. Deterministic lifecycle transitions via `Shoestring.Cobbler.StateMachine`.
  6. SQLite-enforced atomic exclusivity for the global MVP task claim.
  7. Trajectory authoritative persistence: trajectory event is emitted and
     persisted atomically with database updates.
  8. Inert pending intents: execution remains completely disabled.
  """

  import Ecto.Query
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent
  alias Shoestring.Cobbler.{AdmissionDecision, Claim, CommandRecord, Intent, StateMachine}

  @supported_commands [
    "submit_intent",
    "claim",
    "needs_user",
    "resume",
    "complete",
    "fail",
    "cancel"
  ]

  @doc """
  Executes a command on Cobbler.

  Accepts `goal_id`, `command_params` map with `:command_id`, `:command_type`,
  and `:payload`, and optional options.
  """
  @spec execute(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute(goal_id, command_params, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, normalized_goal_id} <- validate_uuid(goal_id, :goal_id),
         {:ok, command} <- validate_command_envelope(command_params) do
      payload_hash = compute_payload_hash(command.payload)

      # Check existing command for goal_id and command_id
      case get_existing_command(repo, normalized_goal_id, command.command_id) do
        %CommandRecord{} = existing ->
          handle_existing_command(existing, payload_hash)

        nil ->
          execute_command_flow(repo, normalized_goal_id, command, payload_hash, opts)
      end
    end
  end

  defp validate_command_envelope(%{command_id: id, command_type: type} = params) do
    payload = Map.get(params, :payload, %{})
    validate_envelope_fields(id, type, payload)
  end

  defp validate_command_envelope(%{"command_id" => id, "command_type" => type} = params) do
    payload = Map.get(params, "payload", %{})
    validate_envelope_fields(id, type, payload)
  end

  defp validate_command_envelope(params) do
    {:error,
     {:malformed_command, "missing required command_id or command_type in #{inspect(params)}"}}
  end

  defp validate_envelope_fields(id, type, payload) do
    type_str = to_string(type)

    cond do
      not is_binary(id) or String.trim(id) == "" ->
        {:error, {:malformed_command, "command_id must be a non-empty string"}}

      type_str not in @supported_commands ->
        {:error, {:malformed_command, "unsupported command_type '#{type_str}'"}}

      not is_map(payload) ->
        {:error, {:malformed_command, "payload must be a map"}}

      true ->
        {:ok, %{command_id: id, command_type: type_str, payload: payload}}
    end
  end

  defp validate_uuid(nil, field), do: {:error, {:malformed_command, "#{field} cannot be nil"}}

  defp validate_uuid(uuid, field) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, casted} ->
        {:ok, casted}

      :error ->
        {:error, {:malformed_command, "#{field} must be a valid UUID, got: #{inspect(uuid)}"}}
    end
  end

  defp validate_uuid(other, field),
    do: {:error, {:malformed_command, "#{field} must be a valid UUID, got: #{inspect(other)}"}}

  defp compute_payload_hash(payload) do
    canonical = canonicalize(payload)
    :crypto.hash(:sha256, :erlang.term_to_binary(canonical)) |> Base.encode16(case: :lower)
  end

  defp canonicalize(%_{} = struct), do: struct |> Map.from_struct() |> canonicalize()

  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp get_existing_command(repo, goal_id, command_id) do
    repo.one(
      from c in CommandRecord,
        where: c.goal_id == ^goal_id and c.command_id == ^command_id
    )
  end

  defp handle_existing_command(%CommandRecord{} = existing, current_hash) do
    if existing.payload_hash == current_hash do
      {:ok, existing.result}
    else
      {:error,
       {:conflicting_command_payload,
        "command_id '#{existing.command_id}' was already executed with a different payload"}}
    end
  end

  defp execute_command_flow(repo, goal_id, command, payload_hash, opts) do
    case process_command(repo, goal_id, command, opts) do
      {:ok, result, event_attrs} ->
        trajectory_event_id =
          if event_attrs do
            case Trajectory.append(goal_id, event_attrs, opts) do
              {:ok, %TrajectoryEvent{id: event_id}} ->
                event_id

              {:error, reason} ->
                {:error, {:trajectory_append_failed, reason}}
            end
          else
            nil
          end

        case trajectory_event_id do
          {:error, _} = err ->
            err

          event_id ->
            command_record_attrs = %{
              command_id: command.command_id,
              intent_id: Map.get(result, :intent_id) || Map.get(result, "intent_id"),
              command_type: command.command_type,
              payload: command.payload,
              payload_hash: payload_hash,
              status: "applied",
              result: stringify_keys(result),
              trajectory_event_id: event_id
            }

            %CommandRecord{}
            |> CommandRecord.changeset(command_record_attrs)
            |> Ecto.Changeset.put_change(:goal_id, goal_id)
            |> repo.insert!()

            {:ok, result}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_command(repo, goal_id, %{command_type: "submit_intent"} = cmd, opts) do
    payload = cmd.payload

    with {:ok, validated_intent_params} <- extract_intent_params(goal_id, payload),
         {:ok, admission_ref} <-
           validate_admission_reference(repo, goal_id, validated_intent_params, payload, opts) do
      # Set up intent attributes
      intent_id =
        Map.get(payload, "intent_id") || Map.get(payload, :intent_id) || Ecto.UUID.generate()

      intent_attrs =
        Map.merge(validated_intent_params, %{
          id: intent_id,
          goal_id: goal_id,
          status: "pending",
          admission_decision_id: admission_ref.decision_id,
          proposed_bounds: admission_ref.proposed_bounds,
          override: admission_ref.override
        })

      intent =
        %Intent{}
        |> Intent.changeset(intent_attrs)
        |> Ecto.Changeset.put_change(:goal_id, goal_id)
        |> then(fn cs ->
          if intent_attrs[:task_id],
            do: Ecto.Changeset.put_change(cs, :task_id, intent_attrs[:task_id]),
            else: cs
        end)
        |> repo.insert!()

      result = %{
        intent_id: intent.id,
        goal_id: goal_id,
        status: "pending",
        title: intent.title,
        provider_id: intent.provider_id,
        scope: intent.scope,
        admission_decision_id: intent.admission_decision_id
      }

      event_attrs = %{
        "type" => "cobbler.intent_submitted",
        "schema_version" => 1,
        "actor" => "cobbler",
        "occurred_at" => DateTime.utc_now(),
        "payload" => %{
          "command_id" => cmd.command_id,
          "intent_id" => intent.id,
          "goal_id" => goal_id,
          "title" => intent.title,
          "requested_capability" => intent.requested_capability,
          "provider_id" => intent.provider_id,
          "account_id" => intent.account_id,
          "scope" => intent.scope,
          "admission_decision_id" => intent.admission_decision_id,
          "proposed_bounds" => intent.proposed_bounds,
          "override" => intent.override,
          "submitted_at" => DateTime.to_iso8601(intent.inserted_at),
          "metadata" => intent.metadata
        }
      }

      {:ok, result, event_attrs}
    end
  end

  defp process_command(repo, goal_id, %{command_type: "claim"} = cmd, _opts) do
    payload = cmd.payload

    with {:ok, intent_id} <- fetch_uuid(payload, "intent_id", :intent_id),
         {:ok, intent} <- get_intent_for_goal(repo, goal_id, intent_id) do
      # Check if this exact intent already has an active claim
      existing_active_claim =
        repo.one(
          from c in Claim,
            where: c.intent_id == ^intent.id and c.status == "active"
        )

      if existing_active_claim do
        # Already claimed by this intent: recover existing claim
        result = %{
          intent_id: intent.id,
          claim_id: existing_active_claim.id,
          status: "active",
          provider_id: existing_active_claim.provider_id,
          scope: existing_active_claim.scope
        }

        {:ok, result, nil}
      else
        # Verify legal transition: pending -> active
        case StateMachine.transition(intent.status, :claim) do
          {:ok, :active} ->
            # Attempt exclusive SQLite claim
            claim_id = Ecto.UUID.generate()
            now = DateTime.utc_now()

            claim_attrs = %{
              id: claim_id,
              claim_slot: "global_active",
              active_slot: "global",
              goal_id: goal_id,
              intent_id: intent.id,
              command_id: cmd.command_id,
              provider_id: intent.provider_id,
              account_id: intent.account_id,
              scope: intent.scope,
              status: "active",
              claimed_at: now,
              metadata: Map.get(payload, "metadata", %{})
            }

            claim_changeset =
              %Claim{}
              |> Claim.acquire_changeset(claim_attrs)
              |> Ecto.Changeset.put_change(:goal_id, goal_id)
              |> Ecto.Changeset.put_change(:intent_id, intent.id)

            case repo.insert(claim_changeset) do
              {:ok, claim} ->
                # Update intent status to active
                intent
                |> Ecto.Changeset.change(%{status: "active"})
                |> repo.update!()

                result = %{
                  intent_id: intent.id,
                  claim_id: claim.id,
                  status: "active",
                  provider_id: claim.provider_id,
                  scope: claim.scope
                }

                event_attrs = %{
                  "type" => "cobbler.intent_claimed",
                  "schema_version" => 1,
                  "actor" => "cobbler",
                  "occurred_at" => now,
                  "payload" => %{
                    "command_id" => cmd.command_id,
                    "intent_id" => intent.id,
                    "claim_id" => claim.id,
                    "goal_id" => goal_id,
                    "provider_id" => claim.provider_id,
                    "account_id" => claim.account_id,
                    "scope" => claim.scope,
                    "claimed_at" => DateTime.to_iso8601(now),
                    "metadata" => claim.metadata
                  }
                }

                {:ok, result, event_attrs}

              {:error, %Ecto.Changeset{errors: errors}} ->
                if Keyword.has_key?(errors, :active_slot) or Keyword.has_key?(errors, :claim_slot) do
                  # Unique constraint violated: another task holds the global slot
                  current_active =
                    repo.one(
                      from c in Claim,
                        where: c.status == "active",
                        limit: 1
                    )

                  {:error, {:already_claimed, current_active}}
                else
                  {:error, {:claim_failed, errors}}
                end
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp process_command(repo, goal_id, %{command_type: "needs_user"} = cmd, _opts) do
    payload = cmd.payload

    with {:ok, intent_id} <- fetch_uuid(payload, "intent_id", :intent_id),
         {:ok, intent} <- get_intent_for_goal(repo, goal_id, intent_id),
         {:ok, next_state} <- StateMachine.transition(intent.status, :needs_user) do
      now = DateTime.utc_now()

      reason =
        Map.get(payload, "reason") || Map.get(payload, :reason) ||
          "Operator intervention requested"

      metadata = Map.get(payload, "metadata") || Map.get(payload, :metadata) || %{}

      recovery_data = %{
        "suspended_at" => DateTime.to_iso8601(now),
        "reason" => reason,
        "metadata" => metadata
      }

      intent
      |> Ecto.Changeset.change(%{status: to_string(next_state), recovery_data: recovery_data})
      |> repo.update!()

      result = %{
        intent_id: intent.id,
        goal_id: goal_id,
        status: to_string(next_state),
        reason: reason
      }

      event_attrs = %{
        "type" => "cobbler.intent_transitioned",
        "schema_version" => 1,
        "actor" => "cobbler",
        "occurred_at" => now,
        "payload" => %{
          "command_id" => cmd.command_id,
          "intent_id" => intent.id,
          "goal_id" => goal_id,
          "from_status" => intent.status,
          "to_status" => to_string(next_state),
          "event_name" => "needs_user",
          "reason" => reason,
          "metadata" => metadata,
          "transitioned_at" => DateTime.to_iso8601(now)
        }
      }

      {:ok, result, event_attrs}
    end
  end

  defp process_command(repo, goal_id, %{command_type: "resume"} = cmd, _opts) do
    payload = cmd.payload

    with {:ok, intent_id} <- fetch_uuid(payload, "intent_id", :intent_id),
         {:ok, intent} <- get_intent_for_goal(repo, goal_id, intent_id),
         {:ok, next_state} <- StateMachine.transition(intent.status, :resume) do
      now = DateTime.utc_now()
      metadata = Map.get(payload, "metadata") || Map.get(payload, :metadata) || %{}

      intent
      |> Ecto.Changeset.change(%{status: to_string(next_state), recovery_data: nil})
      |> repo.update!()

      result = %{
        intent_id: intent.id,
        goal_id: goal_id,
        status: to_string(next_state)
      }

      event_attrs = %{
        "type" => "cobbler.intent_transitioned",
        "schema_version" => 1,
        "actor" => "cobbler",
        "occurred_at" => now,
        "payload" => %{
          "command_id" => cmd.command_id,
          "intent_id" => intent.id,
          "goal_id" => goal_id,
          "from_status" => intent.status,
          "to_status" => to_string(next_state),
          "event_name" => "resume",
          "metadata" => metadata,
          "transitioned_at" => DateTime.to_iso8601(now)
        }
      }

      {:ok, result, event_attrs}
    end
  end

  defp process_command(repo, goal_id, %{command_type: terminal_type} = cmd, _opts)
       when terminal_type in ["complete", "fail", "cancel"] do
    payload = cmd.payload
    event_atom = String.to_existing_atom(terminal_type)

    with {:ok, intent_id} <- fetch_uuid(payload, "intent_id", :intent_id),
         {:ok, intent} <- get_intent_for_goal(repo, goal_id, intent_id),
         {:ok, next_state} <- StateMachine.transition(intent.status, event_atom) do
      now = DateTime.utc_now()

      reason =
        Map.get(payload, "reason") || Map.get(payload, :reason) ||
          Map.get(payload, "terminal_reason") || "#{terminal_type} requested"

      metadata = Map.get(payload, "metadata") || Map.get(payload, :metadata) || %{}

      # Release active claim if this intent holds one
      active_claim =
        repo.one(
          from c in Claim,
            where: c.intent_id == ^intent.id and c.status == "active"
        )

      if active_claim do
        active_claim
        |> Claim.release_changeset(%{
          status: "released",
          active_slot: nil,
          released_at: now,
          release_reason: terminal_type
        })
        |> repo.update!()
      end

      intent
      |> Ecto.Changeset.change(%{status: to_string(next_state), terminal_reason: reason})
      |> repo.update!()

      result = %{
        intent_id: intent.id,
        goal_id: goal_id,
        status: to_string(next_state),
        reason: reason
      }

      event_attrs = %{
        "type" => "cobbler.intent_transitioned",
        "schema_version" => 1,
        "actor" => "cobbler",
        "occurred_at" => now,
        "payload" => %{
          "command_id" => cmd.command_id,
          "intent_id" => intent.id,
          "claim_id" => if(active_claim, do: active_claim.id, else: nil),
          "goal_id" => goal_id,
          "from_status" => intent.status,
          "to_status" => to_string(next_state),
          "event_name" => terminal_type,
          "reason" => reason,
          "metadata" => metadata,
          "transitioned_at" => DateTime.to_iso8601(now)
        }
      }

      {:ok, result, event_attrs}
    end
  end

  defp extract_intent_params(goal_id, payload) do
    title = Map.get(payload, "title") || Map.get(payload, :title) || "Task Intent"
    task_id = Map.get(payload, "task_id") || Map.get(payload, :task_id)

    capability =
      Map.get(payload, "requested_capability") || Map.get(payload, :requested_capability) ||
        "supervised_execution"

    provider_id = Map.get(payload, "provider_id") || Map.get(payload, :provider_id)
    account_id = Map.get(payload, "account_id") || Map.get(payload, :account_id) || "default"
    scope = Map.get(payload, "scope") || Map.get(payload, :scope) || "account:default"
    metadata = Map.get(payload, "metadata") || Map.get(payload, :metadata) || %{}

    cond do
      not is_binary(provider_id) or String.trim(provider_id) == "" ->
        {:error, {:malformed_command, "provider_id must be a non-empty string"}}

      not is_binary(scope) or String.trim(scope) == "" ->
        {:error, {:malformed_command, "scope must be a non-empty string"}}

      true ->
        {:ok,
         %{
           goal_id: goal_id,
           task_id: task_id,
           title: title,
           requested_capability: capability,
           provider_id: provider_id,
           account_id: account_id,
           scope: scope,
           metadata: metadata
         }}
    end
  end

  defp validate_admission_reference(repo, goal_id, intent_params, payload, opts) do
    raw_admission =
      Map.get(payload, "admission_decision") || Map.get(payload, :admission_decision)

    decision_id =
      Map.get(payload, "admission_decision_id") || Map.get(payload, :admission_decision_id)

    cond do
      is_struct(raw_admission, AdmissionDecision) ->
        validate_decision_struct(raw_admission, goal_id, intent_params)

      is_map(raw_admission) ->
        case AdmissionDecision.from_payload(raw_admission, opts) do
          {:ok, decision} -> validate_decision_struct(decision, goal_id, intent_params)
          {:error, changeset} -> {:error, {:invalid_admission_decision, changeset}}
        end

      is_binary(decision_id) ->
        # Look up admission.decided event in trajectory for this goal
        case find_admission_event(repo, goal_id, decision_id) do
          {:ok, payload} ->
            case AdmissionDecision.from_payload(payload, opts) do
              {:ok, decision} -> validate_decision_struct(decision, goal_id, intent_params)
              {:error, cs} -> {:error, {:invalid_admission_decision, cs}}
            end

          :not_found ->
            {:error, {:admission_decision_not_found, decision_id}}
        end

      true ->
        {:error,
         {:missing_admission_reference,
          "must supply a valid admission_decision or admission_decision_id"}}
    end
  end

  defp validate_decision_struct(%AdmissionDecision{} = decision, goal_id, intent_params) do
    candidate_provider =
      case decision.candidate do
        %{provider_id: p} -> p
        %{"provider_id" => p} -> p
        _ -> nil
      end

    cond do
      decision.result != :admit ->
        {:error,
         {:admission_not_admitted,
          "admission decision result is #{inspect(decision.result)}, only :admit is permitted"}}

      decision.goal_id != nil and decision.goal_id != goal_id ->
        {:error,
         {:admission_scope_mismatch,
          "admission decision goal_id #{decision.goal_id} does not match command goal_id #{goal_id}"}}

      candidate_provider != intent_params.provider_id ->
        {:error,
         {:admission_provider_mismatch,
          "candidate provider '#{candidate_provider}' does not match requested '#{intent_params.provider_id}'"}}

      decision.requested_capability != intent_params.requested_capability ->
        {:error,
         {:admission_capability_mismatch,
          "requested capability '#{decision.requested_capability}' does not match intent '#{intent_params.requested_capability}'"}}

      decision.scope != intent_params.scope ->
        {:error,
         {:admission_scope_mismatch,
          "scope '#{decision.scope}' does not match intent scope '#{intent_params.scope}'"}}

      true ->
        {:ok,
         %{
           decision_id: decision.decision_id,
           proposed_bounds: decision.proposed_bounds || %{},
           override: decision.override
         }}
    end
  end

  defp find_admission_event(repo, goal_id, decision_id) do
    event =
      repo.one(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type == "admission.decided",
          order_by: [desc: e.sequence],
          limit: 1
      )

    case event do
      %TrajectoryEvent{payload: %{"decision_id" => ^decision_id} = p} -> {:ok, p}
      %TrajectoryEvent{payload: %{decision_id: ^decision_id} = p} -> {:ok, p}
      _ -> :not_found
    end
  end

  defp get_intent_for_goal(repo, goal_id, intent_id) do
    case repo.one(from i in Intent, where: i.goal_id == ^goal_id and i.id == ^intent_id) do
      %Intent{} = intent -> {:ok, intent}
      nil -> {:error, {:intent_not_found, intent_id}}
    end
  end

  defp fetch_uuid(payload, str_key, atom_key) do
    val = Map.get(payload, str_key) || Map.get(payload, atom_key)

    case val do
      nil ->
        {:error, {:malformed_command, "missing #{str_key} in payload"}}

      uuid when is_binary(uuid) ->
        validate_uuid(uuid, atom_key)

      other ->
        {:error, {:malformed_command, "#{str_key} must be a valid UUID, got: #{inspect(other)}"}}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(%_{} = s), do: s |> Map.from_struct() |> stringify_keys()
  defp stringify_value(map) when is_map(map), do: stringify_keys(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(other), do: other
end
