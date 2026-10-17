defmodule Shoestring.Cobbler.PlanGateLog do
  @moduledoc """
  Gate start and completion events and output artifacts (iteration 8, work
  package B).

  Every gate the executor runs, for a task attempt or for the goal's final
  gates, is one invocation with its own id:

  - `cobbler.plan.gate.started` before the command runs: the gate, its
    specification identity (`Shoestring.Cobbler.GateSpec`), its position in
    the run order and whether it is required;
  - `cobbler.plan.gate.completed` after it: the exact result (`passed`,
    `failed`, `timeout`, `output_oversized`, `unavailable` or `error`), exit
    status, commit, duration, sandbox identity and a reference to the output
    artifact.

  The output (complete, or what arrived before a timeout or the output
  limit) is stored as a redacted text artifact (`ArtifactStore`); the event
  carries its id, SHA-256 and size, and whether it was cut at the limit. It
  is written when the gate ends, not streamed while it runs.

  An invocation interrupted by a restart keeps its start event with no
  completion; the executor runs the gate again as a new invocation. These
  events record what ran: acceptance still comes only from verified evidence,
  and nothing here changes lifecycle state.
  """

  alias Shoestring.Harness.RunRecord
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.ArtifactStore

  @results ~w(passed failed timeout output_oversized unavailable error)

  @type t :: map() | nil

  @doc "The recorded results."
  @spec results() :: [String.t()]
  def results, do: @results

  @doc """
  A log for one run of gates. `scope` is `"task"` (with the attempt's
  `context`) or `"execution"` (the goal's final gates).
  """
  @spec new(module(), Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map(), keyword()) :: t()
  def new(repo, goal_id, execution_id, scope, context, opts) do
    task_fields =
      if scope == "task" do
        %{
          "plan_task_id" => context.plan_task_id,
          "run_id" => context.run_id,
          "attempt" => context.attempt
        }
      else
        %{}
      end

    trusted =
      case scope == "task" && repo.get_by(RunRecord, id: context.run_id, goal_id: goal_id) do
        %RunRecord{task_id: task_id} -> [run_id: context.run_id, task_id: task_id]
        _ -> []
      end

    %{
      goal_id: goal_id,
      fields: Map.merge(%{"execution_id" => execution_id, "scope" => scope}, task_fields),
      trusted: trusted,
      opts: opts
    }
  end

  @doc "Records that an invocation is starting."
  @spec started(t(), Ecto.UUID.t(), pos_integer(), map()) :: :ok | {:error, term()}
  def started(nil, _invocation_id, _position, _spec), do: :ok

  def started(log, invocation_id, position, spec) do
    append(log, "cobbler.plan.gate.started", invocation_id, position, spec, %{})
  end

  @doc """
  Records how an invocation ended and stores its output. `outcome`:
  `:result`, `:duration_ms`, and when known `:commit`, `:exit_status`,
  `:sandbox`, `:output`, `:output_truncated` and `:reason`.
  Returns the stored artifact id (or `nil`).
  """
  @spec completed(t(), Ecto.UUID.t(), pos_integer(), map(), map()) ::
          {:ok, Ecto.UUID.t() | nil} | {:error, term()}
  def completed(nil, _invocation_id, _position, _spec, _outcome), do: {:ok, nil}

  def completed(log, invocation_id, position, spec, outcome) do
    artifact = store_output(log, outcome[:output])

    fields =
      %{
        "result" => outcome.result,
        "duration_ms" => outcome.duration_ms,
        "commit" => outcome[:commit],
        "exit_status" => outcome[:exit_status],
        "sandbox" => outcome[:sandbox],
        "reason" => outcome[:reason] && String.slice(outcome.reason, 0, 2000),
        "output_truncated" => outcome[:output_truncated] || false
      }
      |> Map.merge(artifact_fields(artifact))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    with :ok <-
           append(log, "cobbler.plan.gate.completed", invocation_id, position, spec, fields) do
      {:ok, artifact && artifact.id}
    end
  end

  defp store_output(_log, output) when output in [nil, ""], do: nil

  defp store_output(log, output) do
    redacted = Shoestring.Cobbler.GateOutput.redact(output)

    case ArtifactStore.put(
           log.goal_id,
           redacted,
           %{media_type: "text/plain", redacted: true},
           task_id: log.trusted[:task_id]
         ) do
      {:ok, artifact} -> artifact
      {:error, _reason} -> nil
    end
  end

  defp artifact_fields(nil), do: %{}

  defp artifact_fields(artifact) do
    %{
      "artifact_id" => artifact.id,
      "output_sha256" => artifact.sha256,
      "output_bytes" => artifact.byte_size
    }
  end

  # The executor's clock, so its tests' fixed times also order these events.
  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now ->
        DateTime.truncate(now, :microsecond)

      _other ->
        opts
        |> Keyword.get(:clock, Shoestring.Harness.SystemClock)
        |> Shoestring.Harness.Clock.now()
        |> DateTime.truncate(:microsecond)
    end
  end

  defp append(log, type, invocation_id, position, spec, fields) do
    payload =
      log.fields
      |> Map.merge(%{
        "invocation_id" => invocation_id,
        "gate" => spec["gate"],
        "spec" => Shoestring.Cobbler.GateSpec.identity(spec),
        "kind" => spec["kind"],
        "position" => position,
        "required" => spec["required"]
      })
      |> Map.merge(fields)

    attrs = %{
      "type" => type,
      "schema_version" => 1,
      "actor" => "cobbler",
      "occurred_at" => now(log.opts),
      "idempotency_key" => "#{type}:#{invocation_id}",
      "payload" => payload
    }

    case Trajectory.append(log.goal_id, attrs,
           trusted: log.trusted,
           writer_opts: Keyword.get(log.opts, :writer_opts, [])
         ) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, {:executor_append_failed, type, reason}}
    end
  end
end
