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
          :evidence_refs,
          :rationale,
          :outcome
        ],
        uuid_fields: [:run_id, :replacement_claim_id],
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

      case validate_capacity_snapshot(type, version, validated, opts) do
        :ok -> {:ok, validated}
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
    String.starts_with?(type, ["run.", "lease.", "checkpoint.", "capacity.", "harness."])
  end
end
