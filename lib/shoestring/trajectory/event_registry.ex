defmodule Shoestring.Trajectory.EventRegistry do
  @moduledoc """
  Versioned validation registry for canonical trajectory event payloads.

  A later milestone can add a new `{type, version}` entry here with its own
  payload schema and an explicit upcaster, without changing stored history.

  `validate_payload/4` is the strict write boundary. The v2 capacity schema
  explicitly opts into additive fields, but sanitizes every nested object
  before a payload can be persisted. `validate/1` additionally enables the
  historical compatibility path for already-stored envelopes: it accepts
  fields that were valid before a schema tightened, scans them for secrets,
  and drops them before returning the validated envelope so replay remains
  compatible without weakening new writes.
  """

  import Ecto.Changeset

  alias Shoestring.Harness.{CapacitySnapshot, Contract}
  alias Shoestring.Trajectory.EventEnvelope

  @payload_schemas %{
    "cobbler.planner.requested" => %{
      1 => %{
        required: [:request_id, :request_key, :input_digest, :projection_json, :configuration],
        optional: [],
        uuid_fields: [:request_id],
        types: %{configuration: :map}
      }
    },
    "cobbler.planner.attempt.started" => %{
      1 => %{
        required: [
          :request_id,
          :attempt,
          :admission_event_id,
          :output_token_allowance,
          :charged_output_tokens
        ],
        optional: [],
        uuid_fields: [:request_id, :admission_event_id],
        types: %{
          attempt: :integer,
          output_token_allowance: :integer,
          charged_output_tokens: :integer
        }
      }
    },
    "cobbler.planner.blocked" => %{
      1 => %{
        required: [:request_id, :admission_event_id, :errors],
        optional: [],
        uuid_fields: [:request_id, :admission_event_id],
        types: %{errors: :map}
      }
    },
    "cobbler.planner.attempt.finished" => %{
      1 => %{
        required: [:request_id, :attempt, :state, :errors],
        optional: [:output_tokens, :plan_content, :plan_digest],
        uuid_fields: [:request_id],
        types: %{attempt: :integer, errors: :map, output_tokens: :integer}
      }
    },
    "goal.created" => %{
      1 => %{
        required: [:title],
        optional: [:description, :artifact_id],
        uuid_fields: [:artifact_id]
      }
    },
    "task.created" => %{
      1 => %{
        required: [:task_id, :title],
        optional: [:description, :artifact_id],
        uuid_fields: [:task_id, :artifact_id]
      }
    },
    "decision.recorded" => %{
      1 => %{
        required: [:decision],
        optional: [:rationale, :artifact_id],
        uuid_fields: [:artifact_id]
      }
    },
    "task.completed" => %{
      1 => %{
        required: [:task_id],
        optional: [:result, :artifact_id],
        uuid_fields: [:task_id, :artifact_id]
      }
    },
    "run.requested" => %{
      1 => %{
        required: [
          :run_id,
          :dispatch_id,
          :provider_id,
          :workspace_ref,
          :request_version,
          :prompt,
          :continuation,
          :policy,
          :requested_capabilities
        ],
        optional: [:extensions],
        uuid_fields: [:run_id, :dispatch_id],
        types: %{
          request_version: :integer,
          continuation: :map,
          policy: :map,
          requested_capabilities: :map,
          extensions: :map
        }
      }
    },
    "dispatch.requested" => %{
      1 => %{
        required: [:dispatch_id, :run_id, :request_version],
        optional: [],
        uuid_fields: [:dispatch_id, :run_id],
        types: %{request_version: :integer}
      }
    },
    "dispatch.effect_failed" => %{
      1 => %{
        required: [:dispatch_id, :run_id, :error_code],
        optional: [],
        uuid_fields: [:dispatch_id, :run_id],
        types: %{}
      }
    },
    "dispatch.effect_unknown" => %{
      1 => %{
        required: [:dispatch_id, :run_id, :error_code],
        optional: [],
        uuid_fields: [:dispatch_id, :run_id],
        types: %{}
      }
    },
    "dispatch.effect_deferred" => %{
      1 => %{
        required: [:dispatch_id, :run_id, :error_code],
        optional: [],
        uuid_fields: [:dispatch_id, :run_id],
        types: %{}
      }
    },
    "run.starting" => %{1 => %{required: [:run_id], optional: [], uuid_fields: [:run_id]}},
    "run.running" => %{
      1 => %{
        required: [:run_id],
        optional: [:provider_session_id, :process_id],
        uuid_fields: []
      }
    },
    "run.pausing" => %{1 => %{required: [:run_id], optional: [], uuid_fields: [:run_id]}},
    "run.suspended" => %{1 => %{required: [:run_id], optional: [], uuid_fields: [:run_id]}},
    "run.completed" => %{1 => %{required: [:run_id], optional: [], uuid_fields: [:run_id]}},
    "run.interrupted" => %{1 => %{required: [:run_id], optional: [], uuid_fields: [:run_id]}},
    "run.failed" => %{
      1 => %{
        required: [:run_id, :error_category, :error_code],
        optional: [],
        uuid_fields: [:run_id]
      }
    },
    "run.cancelling" => %{1 => %{required: [:run_id], optional: [], uuid_fields: [:run_id]}},
    "run.cancelled" => %{1 => %{required: [:run_id], optional: [], uuid_fields: [:run_id]}},
    "lease.proposed" => %{
      1 => %{
        required: [
          :grant_id,
          :run_id,
          :admitted_snapshot_id,
          :contract_version,
          :reserves,
          :response_budget,
          :tool_budget,
          :deadline,
          :checkpoint_cadence,
          :renewal_state,
          :extensions
        ],
        optional: [],
        uuid_fields: [:grant_id, :run_id, :admitted_snapshot_id],
        types: %{
          contract_version: :integer,
          reserves: :map,
          response_budget: :integer,
          tool_budget: :integer,
          deadline: :utc_datetime,
          checkpoint_cadence: :integer,
          extensions: :map
        }
      }
    },
    "lease.granted" => %{1 => %{required: [:grant_id], optional: [], uuid_fields: [:grant_id]}},
    "lease.active" => %{1 => %{required: [:grant_id], optional: [], uuid_fields: [:grant_id]}},
    "lease.renewal_due" => %{
      1 => %{required: [:grant_id], optional: [], uuid_fields: [:grant_id]}
    },
    "lease.renewed" => %{1 => %{required: [:grant_id], optional: [], uuid_fields: [:grant_id]}},
    "lease.expired" => %{1 => %{required: [:grant_id], optional: [], uuid_fields: [:grant_id]}},
    "lease.revoked" => %{1 => %{required: [:grant_id], optional: [], uuid_fields: [:grant_id]}},
    "lease.checkpoint_required" => %{
      1 => %{required: [:grant_id], optional: [], uuid_fields: [:grant_id]}
    },
    "checkpoint.created" => %{
      1 => %{
        required: [
          :checkpoint_id,
          :run_id,
          :contract_version,
          :acceptance_contract,
          :repository_state,
          :evidence,
          :decisions,
          :unresolved_issues,
          :next_action,
          :stop_reason,
          :artifact_ids,
          :extensions
        ],
        optional: [:provider_session_id],
        uuid_fields: [:checkpoint_id, :run_id],
        types: %{
          contract_version: :integer,
          acceptance_contract: :map,
          repository_state: :map,
          evidence: :map,
          decisions: :map,
          unresolved_issues: :map,
          artifact_ids: :map,
          extensions: :map
        }
      }
    },
    "handoff.created" => %{
      1 => %{
        required: [
          :handoff_id,
          :run_id,
          :checkpoint_id,
          :from_provider_id,
          :to_provider_id,
          :contract_version,
          :next_action,
          :decision_refs,
          :reason,
          :extensions
        ],
        optional: [:prior_run_id, :lease_grant_id],
        uuid_fields: [:handoff_id, :run_id, :checkpoint_id, :prior_run_id, :lease_grant_id],
        types: %{
          contract_version: :integer,
          decision_refs: {:array, :string},
          extensions: :map
        }
      }
    },
    "handoff.failed" => %{
      1 => %{
        required: [:handoff_id, :contract_version, :reason, :detail, :extensions],
        optional: [:run_id, :checkpoint_id],
        uuid_fields: [:handoff_id, :run_id, :checkpoint_id],
        types: %{
          contract_version: :integer,
          extensions: :map
        }
      }
    },
    "capacity.snapshot_observed" => %{
      1 => %{
        required: [
          :snapshot_id,
          :contract_version,
          :capacity_state,
          :windows,
          :observed_at,
          :source,
          :scope,
          :confidence,
          :support_tier,
          :compatibility_state,
          :extensions
        ],
        optional: [:run_id, :expires_at],
        uuid_fields: [:snapshot_id, :run_id],
        types: %{
          contract_version: :integer,
          windows: :map,
          observed_at: :utc_datetime,
          expires_at: :utc_datetime,
          source: :map,
          extensions: :map
        }
      },
      2 => %{
        # v2 is the one explicitly additive event schema. Unknown fields are
        # validated for safety and removed from the persisted canonical
        # payload by sanitize_capacity_snapshot_payload/1.
        allow_unknown: true,
        required: [
          :snapshot_id,
          :contract_version,
          :capacity_state,
          :windows,
          :freshness,
          :source,
          :scope,
          :confidence,
          :support_tier,
          :compatibility_state,
          :extensions
        ],
        optional: [:run_id, :observed_at, :expires_at, :reason],
        uuid_fields: [:snapshot_id, :run_id],
        types: %{
          contract_version: :integer,
          windows: :map,
          observed_at: :utc_datetime,
          expires_at: :utc_datetime,
          freshness: :map,
          source: :map,
          extensions: :map
        }
      }
    },
    "harness.event_recorded" => %{
      1 => %{
        required: [:run_id, :source_event_id, :ordinal, :occurred_at, :kind],
        optional: [
          :process_id,
          :provider_session_id,
          :artifact_id,
          :capacity_snapshot_id,
          :error,
          :result,
          :extensions
        ],
        uuid_fields: [:run_id, :artifact_id, :capacity_snapshot_id],
        types: %{
          ordinal: :integer,
          occurred_at: :utc_datetime,
          error: :map,
          result: :map,
          extensions: :map
        }
      }
    },
    "elf.staleness_observed" => %{
      1 => %{
        required: [:run_id, :observation_id, :observed_at, :evidence],
        optional: [:provider_session_id, :process_id],
        uuid_fields: [:run_id],
        types: %{
          observed_at: :utc_datetime,
          evidence: :map
        }
      }
    },
    "elf.recovery_decided" => %{
      1 => %{
        required: [:run_id, :decision_id, :action],
        optional: [
          :observation_id,
          :replacement_claim_id,
          :replacement_run_id,
          :evidence_refs,
          :rationale,
          :outcome
        ],
        uuid_fields: [:run_id, :replacement_claim_id, :replacement_run_id],
        types: %{
          evidence_refs: {:array, :string}
        }
      }
    },
    "elf.replacement_claimed" => %{
      1 => %{
        required: [:run_id, :decision_id],
        optional: [:attempt, :rationale],
        uuid_fields: [:run_id],
        types: %{attempt: :integer}
      }
    },
    "elf.replacement_linked" => %{
      1 => %{
        required: [:run_id, :claim_id, :replacement_run_id],
        optional: [:prior_run_id],
        uuid_fields: [:run_id, :prior_run_id, :claim_id, :replacement_run_id]
      }
    },
    "admission.decided" => %{
      1 => %{
        required: [
          :decision_id,
          :result,
          :reason_code,
          :explanation,
          :requested_capability,
          :candidate,
          :scope,
          :observation,
          :policy,
          :proposed_bounds,
          :reobservation_required,
          :evaluated_at
        ],
        optional: [
          :run_id,
          :defer_until,
          :override,
          :extensions
        ],
        uuid_fields: [:decision_id, :run_id],
        types: %{
          candidate: :map,
          observation: :map,
          policy: :map,
          override: :map,
          proposed_bounds: :map,
          reobservation_required: :boolean,
          evaluated_at: :utc_datetime,
          defer_until: :utc_datetime,
          extensions: :map
        }
      }
    },
    "cobbler.command.accepted" => %{
      1 => %{
        required: [
          :command_id,
          :command_type,
          :command_digest,
          :command_payload,
          :from_status,
          :to_status,
          :result
        ],
        optional: [:claim_id, :extensions],
        uuid_fields: [:claim_id],
        types: %{
          command_payload: :map,
          result: :map,
          extensions: :map
        }
      }
    },
    "cobbler.command.resolved" => %{
      1 => %{
        required: [
          :command_id,
          :command_type,
          :response,
          :response_digest,
          :from_status,
          :to_status,
          :result
        ],
        # Strict response attribution rides v1 as purely additive optional
        # keys (projector stays at version 1): pre-attribution events omit
        # them and still validate; new writes mirror the digest-covered
        # response attribution at the top level for schema visibility.
        optional: [:confirmed_by, :confirmed_intent, :extensions],
        uuid_fields: [],
        types: %{
          response: :map,
          result: :map,
          extensions: :map
        }
      }
    },
    "cobbler.claim.acquired" => %{
      1 => %{
        required: [
          :claim_id,
          :command_id,
          :intent,
          :provider_id,
          :admission_decision_id,
          :admission_event_id
        ],
        optional: [:extensions],
        uuid_fields: [:claim_id, :admission_event_id],
        types: %{extensions: :map}
      }
    },
    "cobbler.claim.released" => %{
      1 => %{
        required: [:claim_id, :command_id, :reason],
        optional: [:extensions],
        uuid_fields: [:claim_id],
        types: %{extensions: :map}
      }
    },
    # Plan revisions and decisions are canonical durable facts: the event,
    # not a row and never a process, is what establishes which revision
    # holds authority. The revision event carries the plan as its CANONICAL
    # JSON rendering rather than as a nested object, so what replay reads
    # back is byte-identical to what the digest was taken over; a nested
    # object would be re-serialized by the JSON column and could not make
    # that promise. `validate_plan/4` below re-validates that rendering
    # through the full plan contract on every write and every replay.
    "cobbler.plan.revision.created" => %{
      1 => %{
        required: [
          :plan_revision_id,
          :proposal_id,
          :revision_number,
          :plan_version,
          :plan_digest,
          :plan_content,
          :authored_by,
          :author_kind,
          :task_count,
          :ordered_task_ids
        ],
        optional: [:parent_revision_number, :extensions],
        uuid_fields: [:plan_revision_id],
        types: %{
          revision_number: :integer,
          parent_revision_number: :integer,
          plan_version: :integer,
          task_count: :integer,
          ordered_task_ids: {:array, :string},
          extensions: :map
        }
      }
    },
    "cobbler.plan.approved" => %{
      1 => %{
        required: [
          :plan_revision_id,
          :revision_number,
          :decision_id,
          :plan_digest,
          :decided_by,
          :decided_at
        ],
        # An approval that displaces an earlier one names it here, so
        # supersession is derivable from the approval itself and never
        # depends on a second event arriving.
        optional: [:superseded_revision_id, :superseded_revision_number, :note, :extensions],
        uuid_fields: [:plan_revision_id, :superseded_revision_id],
        types: %{
          revision_number: :integer,
          superseded_revision_number: :integer,
          decided_at: :utc_datetime,
          extensions: :map
        }
      }
    },
    "cobbler.plan.rejected" => %{
      1 => %{
        required: [
          :plan_revision_id,
          :revision_number,
          :decision_id,
          :plan_digest,
          :decided_by,
          :decided_at,
          :reason
        ],
        optional: [:extensions],
        uuid_fields: [:plan_revision_id],
        types: %{
          revision_number: :integer,
          decided_at: :utc_datetime,
          extensions: :map
        }
      }
    },
    "cobbler.plan.execution.requested" => %{
      1 => %{
        required: [:execution_id, :revision_number, :plan_digest, :ordered_task_ids],
        optional: [:note, :agent_profile, :repository_path, :requested_by],
        uuid_fields: [:execution_id],
        types: %{
          revision_number: :integer,
          ordered_task_ids: {:array, :string},
          agent_profile: :map,
          repository_path: :string,
          requested_by: :string
        }
      }
    },
    "cobbler.plan.task.dispatched" => %{
      1 => %{
        required: [
          :execution_id,
          :plan_task_id,
          :trajectory_task_id,
          :revision_number,
          :plan_digest,
          :run_id,
          :attempt,
          :command_id
        ],
        optional: [:grant_id],
        uuid_fields: [:execution_id, :trajectory_task_id, :run_id, :grant_id],
        types: %{
          revision_number: :integer,
          attempt: :integer
        }
      }
    },
    "cobbler.plan.task.accepted" => %{
      1 => %{
        required: [
          :execution_id,
          :plan_task_id,
          :revision_number,
          :plan_digest,
          :run_id,
          :attempt,
          :gate,
          :gate_argv,
          :commit,
          :evidence
        ],
        optional: [:worktree_ref],
        uuid_fields: [:execution_id, :run_id],
        types: %{
          revision_number: :integer,
          attempt: :integer,
          gate_argv: {:array, :string},
          evidence: :map
        }
      }
    },
    "cobbler.plan.task.gate_failed" => %{
      1 => %{
        required: [
          :execution_id,
          :plan_task_id,
          :revision_number,
          :plan_digest,
          :run_id,
          :attempt,
          :gate,
          :reason,
          :retry_state
        ],
        optional: [:detail, :duration_ms],
        uuid_fields: [:execution_id, :run_id],
        types: %{
          revision_number: :integer,
          attempt: :integer,
          duration_ms: :integer
        }
      }
    },
    "cobbler.plan.execution.completed" => %{
      1 => %{
        required: [:execution_id, :revision_number, :plan_digest, :commit],
        optional: [:global_gate, :evidence],
        uuid_fields: [:execution_id],
        types: %{
          revision_number: :integer,
          evidence: :map
        }
      }
    }
  }

  @human_identity_pattern ~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/
  @plan_digest_pattern ~r/\A[0-9a-f]{64}\z/

  @doc "Lists the exact event type/version pairs supported by this registry."
  @spec registered_types() :: [{String.t(), pos_integer()}]
  def registered_types do
    @payload_schemas
    |> Enum.flat_map(fn {type, versions} ->
      Enum.map(versions, fn {version, _schema} -> {type, version} end)
    end)
    |> Enum.sort()
  end

  @doc "Returns the current registered version for an event type."
  @spec current_version(term()) :: pos_integer() | {:error, {:unknown_event_type, term()}}
  def current_version(type) do
    case Map.fetch(@payload_schemas, type) do
      {:ok, versions} -> versions |> Map.keys() |> Enum.max()
      :error -> {:error, {:unknown_event_type, type}}
    end
  end

  @doc "Explicitly upcasts a registered payload without mutating stored history."
  @spec upcast(term(), term(), map(), keyword()) ::
          {:ok, map()}
          | {:error, {:unknown_event_type, term()}}
          | {:error, {:unknown_event_version, term(), term()}}
  def upcast(type, version, payload, opts \\ [])

  def upcast("capacity.snapshot_observed", 1, payload, opts) do
    with {:ok, payload} <- validate_payload("capacity.snapshot_observed", 1, payload, opts),
         {:ok, payload} <- upcast_legacy_capacity_snapshot(payload, opts) do
      {:ok, payload}
    end
  end

  def upcast(type, version, payload, _opts) do
    case current_version(type) do
      {:error, error} -> {:error, error}
      ^version -> {:ok, payload}
      _current_version -> {:error, {:unknown_event_version, type, version}}
    end
  end

  @doc "Returns a schema-valid, portable payload for export, dropping legacy unknown keys."
  @spec export_payload(term(), term(), map()) ::
          {:ok, map()}
          | {:error, {:invalid_payload, term(), term(), Ecto.Changeset.t()}}
          | {:error, {:unknown_event_type, term()}}
          | {:error, {:unknown_event_version, term(), term()}}
  def export_payload(type, version, payload) when is_map(payload) do
    with {:ok, schema} <- schema_for(type, version),
         sanitized = Map.take(payload, allowed_keys(schema)),
         {:ok, validated} <-
           validate_payload(type, version, sanitized, legacy_validation_opts(type, version)) do
      {:ok, validated}
    end
  end

  def export_payload(type, version, _payload),
    do: validate_payload(type, version, %{})

  @doc "Validates an envelope and then validates its registered payload schema."
  @spec validate(map()) ::
          {:ok, %{envelope: EventEnvelope.t(), payload: map()}}
          | {:error, {:invalid_envelope, Ecto.Changeset.t()}}
          | {:error, {:invalid_payload, String.t(), pos_integer(), Ecto.Changeset.t()}}
          | {:error, {:unknown_event_type, term()}}
          | {:error, {:unknown_event_version, term(), term()}}
  def validate(attrs) do
    case EventEnvelope.validate(attrs) do
      {:ok, envelope} ->
        case validate_payload(
               envelope.type,
               envelope.schema_version,
               envelope.payload,
               [now: envelope.occurred_at] ++
                 legacy_validation_opts(envelope.type, envelope.schema_version)
             ) do
          {:ok, payload} ->
            {:ok, %{envelope: %{envelope | payload: payload}, payload: payload}}

          error ->
            error
        end

      {:error, changeset} ->
        {:error, {:invalid_envelope, changeset}}
    end
  end

  @doc "Validates one payload against the exact registered type and version."
  @spec validate_payload(String.t(), pos_integer(), map(), keyword()) ::
          {:ok, map()}
          | {:error, {:invalid_payload, String.t(), pos_integer(), Ecto.Changeset.t()}}
          | {:error, {:unknown_event_type, term()}}
          | {:error, {:unknown_event_version, term(), term()}}
  def validate_payload(type, version, payload, opts \\ []) do
    case schema_for(type, version) do
      {:ok, schema} -> validate_payload_schema(type, version, schema, payload, opts)
      error -> error
    end
  end

  defp schema_for(type, version) do
    case Map.fetch(@payload_schemas, type) do
      :error ->
        {:error, {:unknown_event_type, type}}

      {:ok, versions} ->
        case Map.fetch(versions, version) do
          :error -> {:error, {:unknown_event_version, type, version}}
          {:ok, schema} -> {:ok, schema}
        end
    end
  end

  defp allowed_keys(schema), do: Enum.map(schema.required ++ schema.optional, &Atom.to_string/1)

  defp validate_payload_schema(type, version, schema, payload, opts) when is_map(payload) do
    fields = schema.required ++ schema.optional
    allowed_keys = Enum.map(fields, &Atom.to_string/1)

    changeset =
      {%{}, Enum.into(fields, %{}, &{&1, field_type(schema, &1)})}
      |> cast(payload, fields)
      |> validate_required(schema.required)
      |> validate_uuid_fields(schema.uuid_fields)
      |> validate_unknown_keys(schema, payload, allowed_keys, opts)
      |> validate_payload_safety(type, schema, payload)

    if changeset.valid? do
      validated =
        payload
        |> Map.take(allowed_keys)
        |> sanitize_payload(type, version, opts)

      with :ok <- validate_capacity_snapshot(type, version, validated, opts),
           :ok <- validate_admission_decision(type, version, validated, opts),
           :ok <- validate_handoff(type, version, validated, opts),
           :ok <- validate_plan(type, version, validated, opts),
           :ok <- validate_plan_decision(type, version, validated, opts),
           :ok <- validate_plan_execution(type, version, validated, opts),
           :ok <- Shoestring.Cobbler.Planner.Events.validate(type, validated) do
        {:ok, validated}
      else
        {:error, changeset} -> {:error, {:invalid_payload, type, version, changeset}}
      end
    else
      {:error, {:invalid_payload, type, version, changeset}}
    end
  end

  defp validate_payload_schema(type, version, _schema, _payload, _opts) do
    changeset = change(%{}) |> add_error(:base, "must be a JSON-compatible object")
    {:error, {:invalid_payload, type, version, changeset}}
  end

  defp validate_uuid_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      validate_change(changeset, field, fn ^field, value ->
        case Ecto.UUID.cast(value) do
          {:ok, _uuid} -> []
          :error -> [{field, "must be a UUID"}]
        end
      end)
    end)
  end

  defp field_type(schema, field), do: schema |> Map.get(:types, %{}) |> Map.get(field, :string)

  defp validate_unknown_keys(changeset, schema, payload, allowed_keys, opts) do
    if Map.get(schema, :allow_unknown, false) or
         Keyword.get(opts, :allow_legacy_unknown, false) or
         Enum.all?(Map.keys(payload), &(to_string(&1) in allowed_keys)) do
      changeset
    else
      add_error(changeset, :base, "contains unsupported fields")
    end
  end

  defp sanitize_payload(payload, "capacity.snapshot_observed", 2, _opts),
    do: sanitize_capacity_snapshot_payload(payload)

  defp sanitize_payload(payload, "capacity.snapshot_observed", 1, opts) do
    if Keyword.get(opts, :allow_legacy_unknown, false) do
      sanitize_legacy_capacity_snapshot_payload(payload)
    else
      payload
    end
  end

  defp sanitize_payload(payload, _type, _version, _opts), do: payload

  defp sanitize_legacy_capacity_snapshot_payload(payload) do
    payload
    |> sanitize_nested_map("source", ["adapter_id", "method"])
    |> sanitize_nested_list_map("windows", "items", [
      "kind",
      "state",
      "used_percent",
      "reset_at",
      "reason"
    ])
  end

  defp sanitize_capacity_snapshot_payload(payload) do
    payload
    |> sanitize_nested_map("freshness", ["max_age_seconds"])
    |> sanitize_nested_map("source", ["adapter_id", "provider_id", "invocation_mode", "event"])
    |> sanitize_nested_list_map("windows", "items", [
      "kind",
      "state",
      "used_percent",
      "reset_at",
      "reason"
    ])
  end

  defp sanitize_nested_map(payload, key, allowed_keys) do
    case Map.get(payload, key) do
      value when is_map(value) -> Map.put(payload, key, Map.take(value, allowed_keys))
      _other -> payload
    end
  end

  defp sanitize_nested_list_map(payload, parent_key, list_key, allowed_keys) do
    case Map.get(payload, parent_key) do
      parent when is_map(parent) ->
        case Map.get(parent, list_key) do
          items when is_list(items) ->
            sanitized_items =
              Enum.map(items, fn item ->
                if is_map(item), do: Map.take(item, allowed_keys), else: item
              end)

            Map.put(payload, parent_key, %{list_key => sanitized_items})

          _other ->
            payload
        end

      _other ->
        payload
    end
  end

  defp validate_payload_safety(changeset, type, schema, payload) do
    if normalized_harness_event?(type) do
      validate_normalized_payload_safety(changeset, schema, payload)
    else
      changeset
    end
  end

  defp validate_capacity_snapshot("capacity.snapshot_observed", 2, payload, opts) do
    case CapacitySnapshot.from_payload(payload, opts) do
      {:ok, _snapshot} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp validate_capacity_snapshot("capacity.snapshot_observed", 1, payload, opts) do
    cond do
      Map.get(payload, "capacity_state") not in ["known", "unknown"] ->
        Contract.invalid(:capacity_state, "must be a recognized legacy state")

      not valid_legacy_capacity_windows?(Map.get(payload, "windows"), opts) ->
        Contract.invalid(:windows, "must use a valid legacy windows format")

      not valid_legacy_source?(Map.get(payload, "source"), opts) ->
        Contract.invalid(:source, "must use a valid legacy source format")

      Map.get(payload, "confidence") not in ["none", "low", "medium", "high"] ->
        Contract.invalid(:confidence, "must be a recognized legacy confidence")

      Map.get(payload, "support_tier") not in ["supported", "partial", "unsupported"] ->
        Contract.invalid(:support_tier, "must be a recognized legacy support tier")

      Map.get(payload, "compatibility_state") not in ["compatible", "degraded", "incompatible"] ->
        Contract.invalid(:compatibility_state, "must be a recognized legacy compatibility state")

      not valid_legacy_capacity_state?(payload, opts) ->
        Contract.invalid(:capacity_state, "does not match its legacy windows and freshness")

      true ->
        :ok
    end
  end

  defp validate_capacity_snapshot(_type, _version, _payload, _opts), do: :ok

  # A plan revision event must carry a plan that still validates TODAY, whose
  # digest is the digest of its own content, and whose ordered task ids are
  # the deterministic order that content produces. Checking all three here
  # means replay cannot resurrect a plan that could not be proposed now, and
  # cannot reconstruct an authority whose digest never matched its content.
  defp validate_plan("cobbler.plan.revision.created", 1, payload, _opts) do
    with {:ok, contract} <- plan_contract(payload),
         :ok <- plan_matches(contract, payload) do
      :ok
    end
  end

  defp validate_plan(_type, _version, _payload, _opts), do: :ok

  defp plan_contract(payload) do
    case Shoestring.Cobbler.PlanContract.from_canonical_json(Map.get(payload, "plan_content")) do
      {:ok, contract} ->
        {:ok, contract}

      {:error, reason} ->
        Contract.invalid(:plan_content, "must be a valid plan contract (#{inspect(reason)})")
    end
  end

  defp plan_matches(contract, payload) do
    cond do
      Map.get(payload, "plan_digest") != contract.digest ->
        Contract.invalid(:plan_digest, "must be the digest of plan_content")

      Map.get(payload, "plan_version") != contract.version ->
        Contract.invalid(:plan_version, "must match the plan contract version")

      Map.get(payload, "ordered_task_ids") != contract.ordered_task_ids ->
        Contract.invalid(:ordered_task_ids, "must be the deterministic order of plan_content")

      Map.get(payload, "task_count") != length(contract.content["tasks"]) ->
        Contract.invalid(:task_count, "must match the number of tasks in plan_content")

      Map.get(payload, "author_kind") != "human" ->
        Contract.invalid(:author_kind, "must be human in this slice")

      not human_identity?(Map.get(payload, "authored_by")) ->
        Contract.invalid(:authored_by, "must be a human: identity in this slice")

      true ->
        :ok
    end
  end

  defp human_identity?(value) when is_binary(value),
    do: Regex.match?(@human_identity_pattern, value)

  defp human_identity?(_value), do: false

  # Only a human decides on a plan revision. The Plans API refuses a
  # non-`human:` decider, so an event carrying one could never have been
  # written through it; refusing here keeps replay from laundering a forged
  # or backfilled decision into authority.
  defp validate_plan_decision(type, 1, payload, _opts)
       when type in ["cobbler.plan.approved", "cobbler.plan.rejected"] do
    case Map.get(payload, "decided_by") do
      decided_by when is_binary(decided_by) ->
        if Regex.match?(@human_identity_pattern, decided_by) do
          :ok
        else
          Contract.invalid(:decided_by, "must be a human: identity in this slice")
        end

      _other ->
        Contract.invalid(:decided_by, "must be a human: identity in this slice")
    end
  end

  defp validate_plan_decision(_type, _version, _payload, _opts), do: :ok

  # Structural hardening for the sequential-executor events: digests are
  # bound at dispatch time, so a malformed digest, a non-positive
  # revision/attempt, an unknown gate, or an unknown retry state fails the
  # write rather than entering history.
  defp validate_plan_execution("cobbler.plan.execution.requested", 1, payload, _opts) do
    with :ok <- plan_execution_digest(payload),
         :ok <- plan_execution_revision(payload),
         :ok <- plan_execution_order(payload) do
      :ok
    end
  end

  defp validate_plan_execution("cobbler.plan.task.dispatched", 1, payload, _opts) do
    with :ok <- plan_execution_digest(payload),
         :ok <- plan_execution_revision(payload),
         :ok <- plan_execution_attempt(payload),
         :ok <- plan_execution_task_id(payload) do
      :ok
    end
  end

  defp validate_plan_execution("cobbler.plan.task.accepted", 1, payload, _opts) do
    with :ok <- plan_execution_digest(payload),
         :ok <- plan_execution_revision(payload),
         :ok <- plan_execution_attempt(payload),
         :ok <- plan_execution_task_id(payload),
         :ok <- plan_execution_gate(payload),
         :ok <- plan_execution_commit(payload) do
      :ok
    end
  end

  defp validate_plan_execution("cobbler.plan.task.gate_failed", 1, payload, _opts) do
    with :ok <- plan_execution_digest(payload),
         :ok <- plan_execution_revision(payload),
         :ok <- plan_execution_attempt(payload),
         :ok <- plan_execution_task_id(payload),
         :ok <- plan_execution_gate(payload),
         :ok <- plan_execution_retry_state(payload) do
      :ok
    end
  end

  defp validate_plan_execution("cobbler.plan.execution.completed", 1, payload, _opts) do
    with :ok <- plan_execution_digest(payload),
         :ok <- plan_execution_revision(payload),
         :ok <- plan_execution_commit(payload) do
      :ok
    end
  end

  defp validate_plan_execution(_type, _version, _payload, _opts), do: :ok

  defp plan_execution_digest(payload) do
    case Map.get(payload, "plan_digest") do
      digest when is_binary(digest) ->
        if Regex.match?(@plan_digest_pattern, digest) do
          :ok
        else
          Contract.invalid(:plan_digest, "must be a sha256 hex digest")
        end

      _other ->
        Contract.invalid(:plan_digest, "must be a sha256 hex digest")
    end
  end

  defp plan_execution_revision(payload) do
    case Map.get(payload, "revision_number") do
      number when is_integer(number) and number > 0 ->
        :ok

      _other ->
        Contract.invalid(:revision_number, "must be a positive integer")
    end
  end

  defp plan_execution_attempt(payload) do
    case Map.get(payload, "attempt") do
      attempt when is_integer(attempt) and attempt > 0 ->
        :ok

      _other ->
        Contract.invalid(:attempt, "must be a positive integer")
    end
  end

  defp plan_execution_task_id(payload) do
    case Map.get(payload, "plan_task_id") do
      id when is_binary(id) and byte_size(id) > 0 ->
        :ok

      _other ->
        Contract.invalid(:plan_task_id, "must be a non-empty task id")
    end
  end

  defp plan_execution_order(payload) do
    case Map.get(payload, "ordered_task_ids") do
      ids when is_list(ids) and length(ids) > 0 ->
        if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) > 0)) do
          :ok
        else
          Contract.invalid(:ordered_task_ids, "must be a non-empty list of task ids")
        end

      _other ->
        Contract.invalid(:ordered_task_ids, "must be a non-empty list of task ids")
    end
  end

  defp plan_execution_gate(payload) do
    case Map.get(payload, "gate") do
      gate when is_binary(gate) ->
        if gate in Shoestring.Cobbler.PlanGate.names() do
          :ok
        else
          Contract.invalid(:gate, "must be a trusted gate name")
        end

      _other ->
        Contract.invalid(:gate, "must be a trusted gate name")
    end
  end

  defp plan_execution_retry_state(payload) do
    case Map.get(payload, "retry_state") do
      state when state in ["retry", "escalate", "needs_user"] ->
        :ok

      _other ->
        Contract.invalid(:retry_state, "must be one of retry, escalate, needs_user")
    end
  end

  defp plan_execution_commit(payload) do
    case Map.get(payload, "commit") do
      commit when is_binary(commit) ->
        if Regex.match?(~r/\A[0-9a-f]{7,40}\z/, commit) do
          :ok
        else
          Contract.invalid(:commit, "must be a resolved hex revision")
        end

      _other ->
        Contract.invalid(:commit, "must be a resolved hex revision")
    end
  end

  defp validate_admission_decision("admission.decided", 1, payload, opts) do
    case Shoestring.Cobbler.AdmissionDecision.from_payload(payload, opts) do
      {:ok, _decision} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp validate_admission_decision(_type, _version, _payload, _opts), do: :ok

  # Handoff pointers must stay small, structured, and secret-free. Decision
  # refs are admission decision ids (UUIDs); free-text checkpoint decisions
  # are never valid here. The normalized `handoff.` prefix additionally
  # subjects the whole payload to `Contract.safe_term?/1` secret scanning.
  defp validate_handoff("handoff.created", 1, payload, _opts) do
    with {:ok, _handoff_id} <- handoff_uuid(payload, "handoff_id"),
         {:ok, _run_id} <- handoff_uuid(payload, "run_id"),
         {:ok, _checkpoint_id} <- handoff_uuid(payload, "checkpoint_id"),
         :ok <- handoff_optional_uuid(payload, "prior_run_id"),
         :ok <- handoff_optional_uuid(payload, "lease_grant_id"),
         {:ok, _version} <- handoff_contract_version(payload),
         {:ok, _next_action} <-
           Contract.text(Map.get(payload, "next_action"), :next_action, max: 2_000),
         :ok <- handoff_decision_refs(payload),
         {:ok, _reason} <- Contract.text(Map.get(payload, "reason"), :reason, max: 500),
         {:ok, _from} <-
           Contract.text(Map.get(payload, "from_provider_id"), :from_provider_id, max: 200),
         {:ok, _to} <-
           Contract.text(Map.get(payload, "to_provider_id"), :to_provider_id, max: 200) do
      :ok
    else
      {:error, changeset} -> {:error, changeset}
    end
  end

  # A permanently failed handoff intent. Carries the machine-readable
  # `reason` an operator surface can branch on plus a bounded human `detail`,
  # and nothing else: no transcript, no adapter output. The `handoff.` prefix
  # subjects the payload to `Contract.safe_term?/1` like the pointer.
  defp validate_handoff("handoff.failed", 1, payload, _opts) do
    with {:ok, _handoff_id} <- handoff_uuid(payload, "handoff_id"),
         :ok <- handoff_optional_uuid(payload, "run_id"),
         :ok <- handoff_optional_uuid(payload, "checkpoint_id"),
         {:ok, _version} <- handoff_contract_version(payload),
         {:ok, _reason} <- Contract.text(Map.get(payload, "reason"), :reason, max: 200),
         {:ok, _detail} <- Contract.text(Map.get(payload, "detail"), :detail, max: 500) do
      :ok
    else
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp validate_handoff(_type, _version, _payload, _opts), do: :ok

  defp handoff_uuid(payload, key) do
    case Ecto.UUID.cast(Map.get(payload, key)) do
      {:ok, _uuid} -> {:ok, Map.get(payload, key)}
      :error -> Contract.invalid(String.to_atom(key), "must be a UUID")
    end
  end

  defp handoff_optional_uuid(payload, key) do
    case Map.get(payload, key) do
      nil -> :ok
      _value -> handoff_uuid(payload, key) |> then(&handoff_uuid_result/1)
    end
  end

  defp handoff_uuid_result({:ok, _uuid}), do: :ok
  defp handoff_uuid_result({:error, changeset}), do: {:error, changeset}

  defp handoff_contract_version(payload) do
    case Map.get(payload, "contract_version") do
      1 -> {:ok, 1}
      _other -> Contract.invalid(:contract_version, "must equal 1")
    end
  end

  defp handoff_decision_refs(payload) do
    case Map.get(payload, "decision_refs") do
      refs when is_list(refs) and length(refs) <= 32 ->
        Enum.reduce_while(refs, :ok, fn ref, :ok ->
          case Ecto.UUID.cast(ref) do
            {:ok, _uuid} -> {:cont, :ok}
            :error -> {:halt, Contract.invalid(:decision_refs, "must be UUIDs")}
          end
        end)

      _other ->
        Contract.invalid(:decision_refs, "must be a list of at most 32 UUIDs")
    end
  end

  defp valid_legacy_capacity_state?(%{"capacity_state" => "known"} = payload, opts) do
    with %{"items" => windows} = windows_payload when is_list(windows) <-
           Map.get(payload, "windows"),
         true <- legacy_unknown_allowed?(opts) or supported_keys?(windows_payload, ["items"]),
         true <- windows != [] do
      true
    else
      _other -> false
    end
  end

  defp valid_legacy_capacity_state?(%{"capacity_state" => "unknown"} = payload, opts) do
    match?(%{"items" => []}, Map.get(payload, "windows")) and
      (legacy_unknown_allowed?(opts) or supported_keys?(Map.get(payload, "windows"), ["items"])) and
      Map.get(payload, "confidence") == "none"
  end

  defp valid_legacy_capacity_state?(_payload, _opts), do: false

  defp valid_legacy_capacity_windows?(%{"items" => windows}, opts) when is_list(windows) do
    Enum.all?(windows, &valid_legacy_capacity_window?(&1, opts)) and
      Enum.uniq_by(windows, &Map.get(&1, "kind")) == windows
  end

  defp valid_legacy_capacity_windows?(_value, _opts), do: false

  defp valid_legacy_capacity_window?(%{"kind" => kind, "state" => "known"} = window, opts)
       when is_binary(kind) and byte_size(kind) > 0 do
    (legacy_unknown_allowed?(opts) or
       supported_keys?(window, ["kind", "state", "used_percent", "reset_at"])) and
      is_number(Map.get(window, "used_percent")) and
      Map.get(window, "used_percent") >= 0 and Map.get(window, "used_percent") <= 100 and
      valid_optional_datetime?(Map.get(window, "reset_at"))
  end

  defp valid_legacy_capacity_window?(
         %{"kind" => kind, "state" => "unknown", "reason" => reason} = window,
         opts
       )
       when is_binary(kind) and byte_size(kind) > 0 and is_binary(reason) and
              byte_size(reason) > 0 do
    legacy_unknown_allowed?(opts) or supported_keys?(window, ["kind", "state", "reason"])
  end

  defp valid_legacy_capacity_window?(_window, _opts), do: false

  defp valid_legacy_source?(%{"adapter_id" => adapter_id, "method" => method} = source, opts)
       when is_binary(adapter_id) and byte_size(adapter_id) > 0 do
    (legacy_unknown_allowed?(opts) or supported_keys?(source, ["adapter_id", "method"])) and
      method in ["probe", "status", "vendor_api"]
  end

  defp valid_legacy_source?(_source, _opts), do: false

  defp legacy_unknown_allowed?(opts),
    do: Keyword.get(opts, :allow_legacy_unknown, false)

  defp supported_keys?(map, allowed_keys) do
    Enum.all?(Map.keys(map), &supported_key?(&1, allowed_keys))
  end

  defp supported_key?(key, allowed_keys) when is_binary(key), do: key in allowed_keys

  defp supported_key?(key, allowed_keys) when is_atom(key),
    do: Atom.to_string(key) in allowed_keys

  defp supported_key?(_key, _allowed_keys), do: false

  defp valid_optional_datetime?(nil), do: true

  defp valid_optional_datetime?(value) do
    match?({:ok, _datetime}, Contract.datetime(value, :reset_at))
  end

  defp upcast_legacy_capacity_snapshot(payload, opts) do
    with {:ok, observed_at} <- Contract.datetime(Map.fetch!(payload, "observed_at"), :observed_at),
         max_age_seconds <- legacy_max_age_seconds(payload, observed_at),
         {:ok, windows} <- upcast_legacy_windows(Map.fetch!(payload, "windows")) do
      future? = legacy_observation_in_future?(observed_at, opts)
      windows = if future?, do: mark_future_windows_unknown(windows), else: windows
      has_observed_window? = Enum.any?(windows, &(&1["state"] == "observed"))

      # A legacy "known" record with no window that actually upcasts to
      # :observed carries no usable data (e.g. every window was itself
      # "unknown"), so v2's :degraded state (which requires at least one
      # observed window) does not apply -- it must fail closed to :unknown
      # instead, matching the "no data" legacy case.
      capacity_state =
        case Map.fetch!(payload, "capacity_state") do
          "known" when has_observed_window? -> "degraded"
          "known" -> "unknown"
          "unknown" -> "unknown"
        end

      support_tier =
        case Map.fetch!(payload, "support_tier") do
          "unsupported" -> "unsupported"
          _tier -> "conservative_partial"
        end

      # v2's :degraded state forbids "none" confidence, so a legacy record
      # that claims real observed data but "none" confidence is floored to
      # "low" rather than dropped -- it is downgraded, not discarded.
      confidence =
        cond do
          future? -> "none"
          capacity_state == "unknown" -> "none"
          Map.fetch!(payload, "confidence") == "none" -> "low"
          true -> Map.fetch!(payload, "confidence")
        end

      expires_at = DateTime.add(observed_at, max_age_seconds, :second)

      {:ok,
       %{
         "snapshot_id" => Map.fetch!(payload, "snapshot_id"),
         "run_id" => Map.get(payload, "run_id"),
         "contract_version" => CapacitySnapshot.version(),
         "capacity_state" => capacity_state,
         "windows" => %{"items" => windows},
         "observed_at" => DateTime.to_iso8601(observed_at),
         "expires_at" => DateTime.to_iso8601(expires_at),
         "freshness" => %{"max_age_seconds" => max_age_seconds},
         "source" => %{
           "adapter_id" => Map.fetch!(payload, "source") |> Map.fetch!("adapter_id"),
           "provider_id" => "legacy",
           "invocation_mode" => "unknown",
           "event" => "none"
         },
         "scope" => Map.fetch!(payload, "scope"),
         "confidence" => confidence,
         "support_tier" => support_tier,
         "compatibility_state" => "degraded",
         "reason" =>
           if(future?,
             do: "legacy_capacity_observation_after_event",
             else: "legacy_capacity_contract_missing_provenance"
           ),
         "extensions" => Map.fetch!(payload, "extensions")
       }}
    end
  end

  defp legacy_observation_in_future?(observed_at, opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> DateTime.compare(observed_at, now) == :gt
      _other -> false
    end
  end

  defp mark_future_windows_unknown(windows) do
    Enum.map(windows, fn window ->
      case window["state"] do
        "observed" ->
          %{
            "kind" => window["kind"],
            "state" => "unknown",
            "reason" => "legacy_capacity_observation_after_event"
          }

        "unknown" ->
          window
      end
    end)
  end

  defp legacy_max_age_seconds(payload, observed_at) do
    with expires_at when is_binary(expires_at) <- Map.get(payload, "expires_at"),
         {:ok, expires_at} <- Contract.datetime(expires_at, :expires_at),
         seconds <- DateTime.diff(expires_at, observed_at, :second),
         true <- seconds > 0 and seconds <= CapacitySnapshot.maximum_freshness_seconds() do
      seconds
    else
      _other -> 300
    end
  end

  defp upcast_legacy_windows(%{"items" => windows}) when is_list(windows) do
    windows
    |> Enum.reduce_while({:ok, []}, fn window, {:ok, acc} ->
      case upcast_legacy_window(window) do
        {:ok, window} -> {:cont, {:ok, [window | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, windows} -> {:ok, Enum.reverse(windows)}
      error -> error
    end
  end

  defp upcast_legacy_windows(_windows),
    do: Contract.invalid(:windows, "must be a legacy windows list")

  defp upcast_legacy_window(%{"state" => "known"} = window) do
    {:ok,
     %{
       "kind" => Map.fetch!(window, "kind"),
       "state" => "observed",
       "used_percent" => Map.fetch!(window, "used_percent"),
       "reset_at" => Map.get(window, "reset_at")
     }
     |> reject_nil_values()}
  end

  defp upcast_legacy_window(%{"state" => "unknown"} = window) do
    {:ok,
     %{
       "kind" => Map.fetch!(window, "kind"),
       "state" => "unknown",
       "reason" => Map.fetch!(window, "reason")
     }}
  end

  defp upcast_legacy_window(_window), do: Contract.invalid(:windows, "must be a legacy window")

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp validate_normalized_payload_safety(changeset, schema, payload) do
    changeset =
      if Contract.safe_term?(payload) do
        changeset
      else
        add_error(changeset, :base, "must not contain secrets or raw transcripts")
      end

    if :extensions in (schema.required ++ schema.optional) do
      case Map.get(payload, "extensions") do
        nil ->
          changeset

        extensions when is_map(extensions) ->
          case Contract.extensions(extensions) do
            {:ok, _extensions} ->
              changeset

            {:error, _error} ->
              add_error(changeset, :extensions, "must be bounded, namespaced, and secret-free")
          end

        _other ->
          add_error(changeset, :extensions, "must be an object")
      end
    else
      changeset
    end
  end

  # Stored v1 envelopes were accepted before the strict write boundary was
  # restored. Replay/import may therefore use this explicit compatibility
  # option; callers creating new events must use validate_payload/4 without it.
  defp legacy_validation_opts(_type, 1), do: [allow_legacy_unknown: true]
  defp legacy_validation_opts(_type, _version), do: []

  defp normalized_harness_event?(type) do
    String.starts_with?(type, [
      "run.",
      "lease.",
      "checkpoint.",
      "capacity.",
      "harness.",
      "handoff.",
      "admission.",
      "cobbler."
    ])
  end
end
