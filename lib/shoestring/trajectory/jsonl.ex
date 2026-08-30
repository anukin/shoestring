defmodule Shoestring.Trajectory.JSONL do
  @moduledoc "Strict, versioned, redacted JSONL export and replay fixtures."

  import Ecto.Query

  alias Shoestring.Repo

  alias Shoestring.Trajectory.{
    Artifact,
    ArtifactStore,
    EventEnvelope,
    EventRegistry,
    Goal,
    Projector,
    TrajectoryEvent
  }

  @manifest_kind "shoestring.trajectory.export"
  @event_kind "event"
  @artifact_kind "artifact"
  @manifest_version 1
  @line_schema_version 1
  @artifact_fields ~w(id goal_id task_id sha256 byte_size media_type location redacted bytes_base64)
  @required_artifact_fields ~w(id goal_id sha256 byte_size media_type location redacted)

  @doc "Exports one goal's validated history and portable artifact metadata."
  @spec export(Ecto.UUID.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def export(goal_id, opts \\ []) do
    with {:ok, normalized_goal_id} <- cast_uuid(goal_id),
         events <- fetch_events(normalized_goal_id),
         {:ok, event_lines} <- export_events(events, normalized_goal_id),
         {:ok, artifact_lines} <- export_artifacts(normalized_goal_id, opts) do
      manifest = %{
        "kind" => @manifest_kind,
        "manifest_version" => @manifest_version,
        "event_schema_version" => @line_schema_version,
        "event_schema_versions" => event_schema_versions(),
        "goal_id" => normalized_goal_id,
        "artifact_mode" =>
          if(Keyword.get(opts, :include_artifacts, false), do: "bytes", else: "metadata")
      }

      {:ok,
       ([Jason.encode!(manifest) | event_lines ++ artifact_lines] |> Enum.join("\n")) <> "\n"}
    end
  end

  @doc "Decodes strict JSONL without inserting any canonical events."
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(jsonl) when is_binary(jsonl) do
    lines = jsonl |> String.split("\n", trim: false) |> trim_final_line()

    cond do
      lines == [] ->
        {:error, {:empty_jsonl, 1}}

      Enum.any?(lines, &(&1 == "")) ->
        {:error, {:malformed_line, Enum.find_index(lines, &(&1 == "")) + 1, :blank}}

      true ->
        decode_lines(lines)
    end
  end

  def decode(_jsonl), do: {:error, {:invalid_jsonl, :must_be_binary}}

  @doc "Replays a decoded export fixture through pure transitions only."
  @spec replay_fixture(binary() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def replay_fixture(input, opts \\ [])

  def replay_fixture(jsonl, opts) when is_binary(jsonl) do
    case decode(jsonl) do
      {:ok, fixture} -> replay_fixture(fixture, opts)
      error -> error
    end
  end

  def replay_fixture(%{manifest: manifest, events: event_maps}, opts) do
    with {:ok, events} <- fixture_events(event_maps),
         goal <- Keyword.get(opts, :goal, fixture_goal(manifest["goal_id"])),
         {:ok, projection} <- Projector.replay_events(goal, events) do
      {:ok, projection}
    end
  end

  def replay_fixture(_fixture, _opts), do: {:error, {:invalid_fixture, :shape}}

  defp decode_lines([manifest_line | rest]) do
    with {:ok, manifest} <- decode_manifest(manifest_line, 1),
         {:ok, events, artifacts} <- decode_records(rest, manifest["goal_id"]) do
      {:ok, %{manifest: manifest, events: events, artifacts: artifacts}}
    end
  end

  defp decode_records(lines, goal_id) do
    Enum.reduce_while(Enum.with_index(lines, 2), {:ok, :events, 1, [], []}, fn {line, line_number},
                                                                               {:ok, phase,
                                                                                expected, events,
                                                                                artifacts} ->
      with {:ok, record} <- decode_line(line, line_number) do
        case record["kind"] do
          @event_kind when phase == :events ->
            case decode_event_record(record, line_number, goal_id, expected) do
              {:ok, event} -> {:cont, {:ok, :events, expected + 1, [event | events], artifacts}}
              {:error, error} -> {:halt, {:error, error}}
            end

          @artifact_kind ->
            case decode_artifact_record(record, line_number, goal_id) do
              {:ok, artifact} ->
                {:cont, {:ok, :artifacts, expected, events, [artifact | artifacts]}}

              {:error, error} ->
                {:halt, {:error, error}}
            end

          @event_kind ->
            {:halt, {:error, {:invalid_line_order, line_number}}}

          kind ->
            {:halt, {:error, {:unknown_line_kind, line_number, kind}}}
        end
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, _phase, _expected, events, artifacts} ->
        {:ok, Enum.reverse(events), Enum.reverse(artifacts)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp decode_manifest(line, line_number) do
    with {:ok, manifest} <- decode_line(line, line_number),
         :ok <- require_kind(manifest, @manifest_kind, {:invalid_manifest, line_number}),
         :ok <-
           require_version(
             manifest,
             "manifest_version",
             @manifest_version,
             {:unknown_manifest_version, manifest["manifest_version"]}
           ),
         :ok <-
           require_version(
             manifest,
             "event_schema_version",
             @line_schema_version,
             {:unknown_event_schema_version, manifest["event_schema_version"]}
           ),
         {:ok, goal_id} <- cast_uuid(manifest["goal_id"]),
         :ok <- validate_schema_versions(manifest["event_schema_versions"]) do
      {:ok, Map.put(manifest, "goal_id", goal_id)}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp decode_event_record(record, line_number, goal_id, expected) do
    with :ok <-
           require_version(
             record,
             "schema_version",
             @line_schema_version,
             {:unknown_event_schema_version, record["schema_version"]}
           ),
         event when is_map(event) <- Map.get(record, "event"),
         :ok <- event_goal_matches(event, goal_id),
         sequence <- Map.get(event, "sequence"),
         :ok <- expected_sequence(sequence, expected),
         {:ok, _validated} <- EventRegistry.validate(event) do
      {:ok, event}
    else
      nil -> {:error, {:malformed_line, line_number, :event_must_be_map}}
      {:error, error} -> {:error, error}
      _other -> {:error, {:malformed_line, line_number, :event}}
    end
  end

  defp decode_artifact_record(record, line_number, goal_id) do
    artifact = Map.get(record, "artifact")

    cond do
      not is_map(artifact) ->
        {:error, {:malformed_line, line_number, :artifact_must_be_map}}

      Map.get(artifact, "goal_id") != goal_id ->
        {:error, {:artifact_goal_mismatch, line_number}}

      not Artifact.safe_location?(Map.get(artifact, "location")) ->
        {:error, {:artifact_unsafe_location, Map.get(artifact, "location")}}

      true ->
        validate_artifact_record(artifact, line_number)
    end
  end

  defp validate_artifact_record(artifact, line_number) do
    unknown_fields = Map.keys(artifact) -- @artifact_fields

    with :ok <- validate_artifact_fields(artifact, unknown_fields, line_number),
         {:ok, _id} <- cast_uuid(Map.get(artifact, "id")),
         {:ok, _goal_id} <- cast_uuid(Map.get(artifact, "goal_id")),
         :ok <- validate_optional_uuid(Map.get(artifact, "task_id")),
         :ok <- validate_sha(artifact["sha256"]),
         :ok <- validate_byte_size(artifact["byte_size"]),
         true <- is_binary(artifact["media_type"]) and artifact["media_type"] != "",
         true <- is_boolean(artifact["redacted"]),
         :ok <- validate_redacted_bytes(artifact),
         {:ok, _bytes} <- validate_optional_artifact_bytes(artifact) do
      {:ok, artifact}
    else
      false -> {:error, {:malformed_artifact, line_number}}
      {:error, error} -> {:error, {:malformed_artifact, line_number, error}}
    end
  end

  defp validate_artifact_fields(_artifact, [_unknown | _], line_number),
    do: {:error, {:malformed_artifact, line_number, :unknown_fields}}

  defp validate_artifact_fields(artifact, [], line_number) do
    case Enum.find(@required_artifact_fields, &(not Map.has_key?(artifact, &1))) do
      nil -> :ok
      missing -> {:error, {:malformed_artifact, line_number, {:missing_field, missing}}}
    end
  end

  defp validate_redacted_bytes(%{"redacted" => true, "bytes_base64" => _}),
    do: {:error, :redacted_bytes}

  defp validate_redacted_bytes(_artifact), do: :ok

  defp validate_optional_artifact_bytes(artifact) do
    case Map.fetch(artifact, "bytes_base64") do
      :error ->
        {:ok, nil}

      {:ok, encoded} when is_binary(encoded) ->
        with {:ok, bytes} <- Base.decode64(encoded),
             true <- sha256(bytes) == artifact["sha256"],
             true <- byte_size(bytes) == artifact["byte_size"] do
          {:ok, bytes}
        else
          false -> {:error, :integrity}
          :error -> {:error, :base64}
        end

      {:ok, _encoded} ->
        {:error, :base64}
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp decode_line(line, line_number) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) -> {:ok, record}
      {:ok, _record} -> {:error, {:malformed_line, line_number, :must_be_object}}
      {:error, reason} -> {:error, {:malformed_line, line_number, reason}}
    end
  end

  defp export_events(events, goal_id) do
    Enum.reduce_while(events, {:ok, 1, []}, fn event, {:ok, expected, lines} ->
      if event.sequence != expected do
        {:halt, {:error, {:event_order, event.sequence, expected}}}
      else
        case export_event(event, goal_id) do
          {:ok, line} -> {:cont, {:ok, expected + 1, [line | lines]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end
    end)
    |> case do
      {:ok, _expected, lines} -> {:ok, Enum.reverse(lines)}
      {:error, error} -> {:error, error}
    end
  end

  defp export_event(event, goal_id) do
    with {:ok, envelope} <- EventEnvelope.validate(event_attributes(event)),
         true <- envelope.goal_id == goal_id,
         {:ok, payload} <-
           EventRegistry.export_payload(envelope.type, envelope.schema_version, envelope.payload),
         {:ok, upcasted_payload} <-
           EventRegistry.upcast(envelope.type, envelope.schema_version, payload) do
      exported =
        event_attributes(%{event | payload: upcasted_payload})
        |> redact()

      {:ok,
       Jason.encode!(%{
         "kind" => @event_kind,
         "schema_version" => @line_schema_version,
         "event" => exported
       })}
    else
      false -> {:error, {:event_goal_mismatch, event.sequence}}
      {:error, error} -> {:error, error}
    end
  end

  defp export_artifacts(goal_id, opts) do
    artifacts =
      Repo.all(
        from artifact in Artifact,
          where: artifact.goal_id == ^goal_id,
          order_by: [asc: artifact.id]
      )

    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, lines} ->
      case export_artifact(artifact, opts) do
        {:ok, line} -> {:cont, {:ok, [line | lines]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      {:error, error} -> {:error, error}
    end
  end

  defp export_artifact(artifact, opts) do
    with true <- Artifact.safe_location?(artifact.location),
         {:ok, %{bytes: bytes}} <-
           ArtifactStore.read(artifact.id, root: ArtifactStore.root(opts)),
         metadata <- artifact_metadata(artifact, bytes, opts) do
      {:ok,
       Jason.encode!(%{
         "kind" => @artifact_kind,
         "schema_version" => @line_schema_version,
         "artifact" => redact(metadata)
       })}
    else
      false -> {:error, {:artifact_unsafe_location, artifact.location}}
      {:error, error} -> {:error, error}
    end
  end

  defp artifact_metadata(artifact, bytes, opts) do
    metadata = %{
      "id" => artifact.id,
      "goal_id" => artifact.goal_id,
      "task_id" => artifact.task_id,
      "sha256" => artifact.sha256,
      "byte_size" => artifact.byte_size,
      "media_type" => artifact.media_type,
      "location" => artifact.location,
      "redacted" => artifact.redacted
    }

    if Keyword.get(opts, :include_artifacts, false) and not artifact.redacted do
      Map.put(metadata, "bytes_base64", Base.encode64(bytes))
    else
      metadata
    end
  end

  defp fixture_events(event_maps) do
    Enum.reduce_while(event_maps, {:ok, []}, fn event_map, {:ok, events} ->
      case EventRegistry.validate(event_map) do
        {:ok, %{envelope: envelope}} ->
          event = %TrajectoryEvent{
            id: envelope.id,
            goal_id: envelope.goal_id,
            task_id: envelope.task_id,
            run_id: envelope.run_id,
            sequence: envelope.sequence,
            parent_event_id: envelope.parent_event_id,
            type: envelope.type,
            actor: envelope.actor,
            occurred_at: envelope.occurred_at,
            schema_version: envelope.schema_version,
            payload: envelope.payload,
            idempotency_key: envelope.idempotency_key
          }

          {:cont, {:ok, [event | events]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, error} -> {:error, error}
    end
  end

  defp fixture_goal(goal_id) do
    %Goal{
      id: goal_id,
      owner_id: "00000000-0000-4000-8000-000000000000",
      title: "fixture",
      status: "active"
    }
  end

  defp validate_schema_versions(versions) when is_map(versions) do
    Enum.reduce_while(versions, :ok, fn {type, version}, :ok ->
      case EventRegistry.current_version(type) do
        ^version -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
        _current -> {:halt, {:error, {:unknown_event_version, type, version}}}
      end
    end)
  end

  defp validate_schema_versions(_versions),
    do: {:error, {:invalid_manifest, :event_schema_versions}}

  defp event_schema_versions do
    EventRegistry.registered_types()
    |> Enum.into(%{}, fn {type, version} -> {type, version} end)
  end

  defp require_kind(record, kind, error) do
    if record["kind"] == kind, do: :ok, else: {:error, error}
  end

  defp require_version(record, key, expected, error) do
    if record[key] == expected, do: :ok, else: {:error, error}
  end

  defp event_goal_matches(event, goal_id) do
    if event["goal_id"] == goal_id,
      do: :ok,
      else: {:error, {:event_goal_mismatch, event["sequence"]}}
  end

  defp expected_sequence(sequence, expected) when sequence == expected, do: :ok
  defp expected_sequence(sequence, expected), do: {:error, {:event_order, sequence, expected}}

  defp validate_optional_uuid(nil), do: :ok
  defp validate_optional_uuid(value), do: cast_uuid(value) |> to_ok()

  defp validate_sha(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: :ok, else: {:error, :sha256}
  end

  defp validate_sha(_value), do: {:error, :sha256}

  defp validate_byte_size(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_byte_size(_value), do: {:error, :byte_size}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_uuid, value}}
    end
  end

  defp to_ok({:ok, _value}), do: :ok
  defp to_ok({:error, error}), do: {:error, error}

  defp fetch_events(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id,
        order_by: [asc: event.sequence]
    )
  end

  defp event_attributes(event) do
    %{
      "id" => event.id,
      "goal_id" => event.goal_id,
      "task_id" => event.task_id,
      "run_id" => event.run_id,
      "sequence" => event.sequence,
      "parent_event_id" => event.parent_event_id,
      "type" => event.type,
      "actor" => event.actor,
      "occurred_at" => event.occurred_at,
      "schema_version" => event.schema_version,
      "payload" => event.payload,
      "idempotency_key" => event.idempotency_key
    }
  end

  defp trim_final_line([]), do: []

  defp trim_final_line(lines) do
    if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
  end

  defp redact(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp redact(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, result ->
      key = to_string(key)

      if secret_key?(key) do
        result
      else
        Map.put(result, key, redact(nested_value))
      end
    end)
  end

  defp redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  defp redact(value) when is_binary(value) do
    Regex.replace(
      ~r/(?i)(sk-[a-z0-9][a-z0-9_-]*|ghp_[a-z0-9_]+|bearer\s+[a-z0-9._~+\/-=]+|(?:api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+)/,
      value,
      "[REDACTED]"
    )
  end

  defp redact(value), do: value

  defp secret_key?(key),
    do:
      Regex.match?(
        ~r/(?i)(token|secret|password|credential|authorization|api[_-]?key|private[_-]?key)/,
        key
      )
end
