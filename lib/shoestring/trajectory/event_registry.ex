defmodule Shoestring.Trajectory.EventRegistry do
  @moduledoc """
  Versioned validation registry for canonical trajectory event payloads.

  A later milestone can add a new `{type, version}` entry here with its own
  payload schema and an explicit upcaster, without changing stored history.
  """

  import Ecto.Changeset

  alias Shoestring.Harness.Contract
  alias Shoestring.Trajectory.EventEnvelope

  @payload_schemas %{
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
    "dispatch.cancelled" => %{
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
    }
  }

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
  @spec upcast(term(), term(), map()) ::
          {:ok, map()}
          | {:error, {:unknown_event_type, term()}}
          | {:error, {:unknown_event_version, term(), term()}}
  def upcast(type, version, payload) do
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
         {:ok, validated} <- validate_payload(type, version, sanitized) do
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
        case validate_payload(envelope.type, envelope.schema_version, envelope.payload) do
          {:ok, payload} -> {:ok, %{envelope: envelope, payload: payload}}
          error -> error
        end

      {:error, changeset} ->
        {:error, {:invalid_envelope, changeset}}
    end
  end

  @doc "Validates one payload against the exact registered type and version."
  @spec validate_payload(String.t(), pos_integer(), map()) ::
          {:ok, map()}
          | {:error, {:invalid_payload, String.t(), pos_integer(), Ecto.Changeset.t()}}
          | {:error, {:unknown_event_type, term()}}
          | {:error, {:unknown_event_version, term(), term()}}
  def validate_payload(type, version, payload) do
    case schema_for(type, version) do
      {:ok, schema} -> validate_payload_schema(type, version, schema, payload)
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

  defp validate_payload_schema(type, version, schema, payload) when is_map(payload) do
    fields = schema.required ++ schema.optional
    allowed_keys = Enum.map(fields, &Atom.to_string/1)
    unknown_keys = Map.keys(payload) -- allowed_keys

    changeset =
      {%{}, Enum.into(fields, %{}, &{&1, field_type(schema, &1)})}
      |> cast(payload, fields)
      |> validate_required(schema.required)
      |> validate_uuid_fields(schema.uuid_fields)
      |> validate_payload_safety(type, schema, payload)

    changeset =
      if unknown_keys == [] do
        changeset
      else
        add_error(changeset, :base, "contains unknown fields")
      end

    if changeset.valid? do
      {:ok, Map.take(payload, allowed_keys)}
    else
      {:error, {:invalid_payload, type, version, changeset}}
    end
  end

  defp validate_payload_schema(type, version, _schema, _payload) do
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

  defp validate_payload_safety(changeset, type, schema, payload) do
    if normalized_harness_event?(type) do
      validate_normalized_payload_safety(changeset, schema, payload)
    else
      changeset
    end
  end

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

  defp normalized_harness_event?(type) do
    String.starts_with?(type, ["run.", "lease.", "checkpoint.", "capacity.", "harness."])
  end
end
