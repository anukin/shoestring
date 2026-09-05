defmodule Shoestring.Elves.Staleness do
  @moduledoc """
  Evidence-backed staleness observations. Collection only — never recovery.

  ## Staleness is evidence, never auto-kill

  A timer, expired lease, quiet heartbeat, or missing final response must never
  by itself interrupt, replace, or duplicate an Elf that may still be doing
  useful work. This module therefore only collects and persists a bounded
  evidence packet describing what is deterministically known:

    * last normalized event time and heartbeat age;
    * OS process-group liveness plus provider-session identity;
    * current safe boundary (last boundary-kind event, if any);
    * Oban attempt state for the linked dispatch job;
    * worktree git status/commit/diff (bounded; `:unavailable` when the
      worktree manager of Work Package A is absent or the path is missing);
    * completed commands/tests observed in the trajectory;
    * pending approval or final-response condition.

  The packet is persisted as `elf.staleness_observed` with a stable
  `observation_id` derived from `(run_id, last_event_sequence, reason)`, so
  repeated collection across retries and application restarts deduplicates via
  the idempotency key instead of spamming the trajectory.

  Deterministic policy still enforces hard safety boundaries elsewhere: unsafe
  dispatch/renewal is refused, and explicit cancellation always terminates the
  owned process group. The orchestrator-facing decision logic (wait, request
  status, synthesize completion, replace, escalate) is a deliberate follow-up
  and lives outside this module — nothing here interrupts or replaces an Elf.
  """

  import Ecto.Query

  alias Shoestring.Elves.PortRunner
  alias Shoestring.Harness.{Clock, DispatchRecord, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Redaction, TrajectoryEvent}

  @max_git_lines 50
  @max_diff_bytes 8_192
  @max_events_scanned 500

  @doc "Maximum git status lines and diff bytes captured per evidence packet."
  @spec collection_bounds() :: %{git_lines: pos_integer(), diff_bytes: pos_integer()}
  def collection_bounds, do: %{git_lines: @max_git_lines, diff_bytes: @max_diff_bytes}

  @doc """
  Collects the evidence packet for `run_id` and persists it as
  `elf.staleness_observed`. Returns `{:ok, :persisted | :duplicate, event}`.

  `reason` names the deterministic trigger (e.g. `"heartbeat_quiet"`,
  `"final_response_missing"`, `"manual_probe"`) and feeds the stable
  observation id. Collection never signals, kills, or replaces anything.
  """
  @spec collect(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, :persisted | :duplicate, TrajectoryEvent.t()} | {:error, term()}
  def collect(run_id, reason, opts \\ []) when is_binary(reason) do
    repo = Keyword.get(opts, :repo, Repo)
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
    now = Clock.now(clock)

    with {:ok, run} <- fetch_run(run_id, repo) do
      events = recent_run_events(run, repo)
      # Prior observations are meta-evidence: they must not feed the
      # observation basis, or every persisted packet would change the next
      # observation id and deduplication could never converge.
      {progress_events, prior_observations} =
        Enum.split_with(events, &(&1.type != "elf.staleness_observed"))

      evidence =
        build_evidence(run, progress_events, reason, now, opts, length(prior_observations))

      observation_id = observation_id(run_id, last_sequence(progress_events), reason)
      persist(run, observation_id, now, evidence, opts)
    end
  end

  @doc """
  Pure observation-id derivation. Stable for the same
  `(run_id, last_sequence, reason)`: retries and restarts that observe no new
  durable state deduplicate instead of duplicating findings.
  """
  @spec observation_id(Ecto.UUID.t(), non_neg_integer(), String.t()) :: String.t()
  def observation_id(run_id, last_sequence, reason) do
    digest =
      :crypto.hash(:sha256, "#{run_id}:#{last_sequence}:#{reason}")
      |> Base.encode16(case: :lower)

    binary_part(digest, 0, 16)
  end

  # -- Private helpers --

  defp fetch_run(run_id, repo) do
    case repo.get(RunRecord, run_id) do
      %RunRecord{} = run -> {:ok, run}
      nil -> {:error, :run_not_found}
    end
  end

  defp recent_run_events(run, repo) do
    repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^run.goal_id and event.run_id == ^run.id,
        order_by: [desc: event.sequence],
        limit: @max_events_scanned
    )
  end

  defp last_sequence([]), do: 0
  defp last_sequence([%TrajectoryEvent{sequence: sequence} | _rest]), do: sequence

  defp build_evidence(run, events, reason, now, opts, prior_observations) do
    last_event = List.first(events)
    os_status = os_status(run, last_event, opts)
    completed = completed_work(events)

    evidence = %{
      "reason" => reason,
      "run_status" => run.status,
      "prior_observations" => prior_observations,
      "last_event_at" => iso8601(last_event && last_event.occurred_at),
      "last_event_sequence" => last_sequence(events),
      "last_event_type" => last_event && last_event.type,
      "heartbeat_age_seconds" => heartbeat_age(last_event, now),
      "os_process_group" => os_status,
      "provider_session_id" => provider_session(run, last_event),
      "safe_boundary" => safe_boundary(events),
      "oban_attempt" => oban_attempt(run, opts),
      "worktree" => worktree_evidence(run),
      "completed_commands" => completed.commands,
      "completed_tests" => completed.tests,
      "final_response" => final_response(events),
      "pending_approval" => false
    }

    Redaction.redact(evidence)
  end

  defp heartbeat_age(nil, _now), do: nil

  defp heartbeat_age(%TrajectoryEvent{occurred_at: occurred_at}, now) do
    max(DateTime.diff(now, occurred_at, :second), 0)
  end

  defp os_status(run, last_event, opts) do
    pgid = process_group_id(run, last_event, opts)

    %{
      "pgid" => pgid,
      "alive" => pgid != nil and PortRunner.alive_id?(pgid)
    }
  end

  defp process_group_id(_run, %TrajectoryEvent{type: "run.running", payload: payload}, _opts) do
    parse_pgid(payload["process_id"])
  end

  defp process_group_id(run, _last_event, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    query =
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^run.goal_id and event.run_id == ^run.id and
            event.type == "run.running",
        order_by: [desc: event.sequence],
        limit: 1,
        select: event.payload

    case repo.one(query) do
      %{"process_id" => process_id} -> parse_pgid(process_id)
      _other -> nil
    end
  end

  defp parse_pgid("pgid:" <> rest) do
    case Integer.parse(rest) do
      {pgid, _rest} when pgid > 1 -> pgid
      _other -> nil
    end
  end

  defp parse_pgid(process_id) when is_binary(process_id) do
    case Integer.parse(process_id) do
      {pgid, _rest} when pgid > 1 -> pgid
      _other -> nil
    end
  end

  defp parse_pgid(_process_id), do: nil

  defp provider_session(%RunRecord{provider_session_id: session_id}, _last_event)
       when is_binary(session_id),
       do: session_id

  defp provider_session(_run, %TrajectoryEvent{payload: %{"provider_session_id" => session_id}})
       when is_binary(session_id),
       do: session_id

  defp provider_session(_run, _last_event), do: nil

  defp safe_boundary(events) do
    events
    |> Enum.find(&boundary_kind?/1)
    |> case do
      nil ->
        %{"kind" => "none"}

      %TrajectoryEvent{type: type, sequence: sequence} ->
        %{"kind" => type, "sequence" => sequence}
    end
  end

  defp boundary_kind?(%TrajectoryEvent{type: "run." <> _}), do: true
  defp boundary_kind?(%TrajectoryEvent{type: "checkpoint.created"}), do: true
  defp boundary_kind?(%TrajectoryEvent{type: "lease." <> _}), do: true
  defp boundary_kind?(_event), do: false

  defp oban_attempt(run, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(DispatchRecord, run.dispatch_id) do
      %DispatchRecord{job_id: nil, status: status} ->
        %{"dispatch_status" => status, "job_state" => "none"}

      %DispatchRecord{job_id: job_id, status: status} ->
        %{"dispatch_status" => status, "job_state" => job_state(job_id, repo)}

      nil ->
        %{"dispatch_status" => "unknown", "job_state" => "unknown"}
    end
  end

  defp job_state(job_id, repo) do
    case repo.get(Oban.Job, job_id) do
      %Oban.Job{state: state} -> state
      nil -> "missing"
    end
  end

  defp worktree_evidence(%RunRecord{workspace_ref: workspace_ref}) do
    base = %{"workspace_ref" => workspace_ref}

    case worktree_path(workspace_ref) do
      nil ->
        Map.put(base, "status", "unavailable")

      path ->
        base
        |> Map.put("path", path)
        |> Map.merge(git_evidence(path))
    end
  end

  defp worktree_path(workspace_ref) when is_binary(workspace_ref) do
    root =
      try do
        Shoestring.State.path(:worktrees)
      rescue
        _error -> nil
      catch
        _kind, _reason -> nil
      end

    case root do
      nil ->
        nil

      root ->
        candidate = Path.join(root, workspace_ref)

        if File.dir?(candidate) and not String.contains?(workspace_ref, "..") do
          candidate
        else
          nil
        end
    end
  end

  defp worktree_path(_workspace_ref), do: nil

  defp git_evidence(path) do
    %{
      "status" => "observed",
      "commit" => git_output(path, ["rev-parse", "HEAD"]),
      "porcelain" => git_output(path, ["status", "--porcelain=v1"]) |> take_lines(@max_git_lines),
      "diff_stat" => git_output(path, ["diff", "--stat"]) |> binary_part_bounded(@max_diff_bytes)
    }
  end

  defp git_output(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> "unavailable"
    end
  rescue
    _error -> "unavailable"
  end

  defp take_lines(text, max) when is_binary(text) do
    text |> String.split("\n", trim: true) |> Enum.take(max)
  end

  defp take_lines(_text, _max), do: "unavailable"

  defp binary_part_bounded(text, max) when is_binary(text) and byte_size(text) > max do
    binary_part(text, 0, max) <> "…[truncated]"
  end

  defp binary_part_bounded(text, _max), do: text

  defp completed_work(events) do
    recorded =
      events
      |> Enum.filter(&(&1.type == "harness.event_recorded"))
      |> Enum.map(& &1.payload)

    commands =
      recorded
      |> Enum.filter(&(&1["kind"] == "command"))
      |> Enum.map(& &1["source_event_id"])
      |> Enum.uniq()

    tests =
      recorded
      |> Enum.filter(&(&1["kind"] in ["command", "result"]))
      |> Enum.map(& &1["source_event_id"])
      |> Enum.uniq()

    %{commands: commands, tests: tests}
  end

  defp final_response(events) do
    if Enum.any?(
         events,
         &(&1.type in ["run.completed", "run.failed", "run.interrupted", "run.cancelled"])
       ) do
      %{"state" => "terminal_recorded"}
    else
      result_seen? = Enum.any?(events, &result_event?/1)
      %{"state" => if(result_seen?, do: "result_seen", else: "missing")}
    end
  end

  defp result_event?(%TrajectoryEvent{type: "harness.event_recorded", payload: payload}) do
    payload["kind"] == "result"
  end

  defp result_event?(_event), do: false

  defp persist(run, observation_id, now, evidence, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    idempotency_key = "elf-staleness:#{observation_id}"

    case repo.get_by(TrajectoryEvent, goal_id: run.goal_id, idempotency_key: idempotency_key) do
      %TrajectoryEvent{} = existing ->
        {:ok, :duplicate, existing}

      nil ->
        append_evidence(run, observation_id, idempotency_key, now, evidence, opts)
    end
  end

  defp append_evidence(run, observation_id, idempotency_key, now, evidence, opts) do
    attrs = %{
      "type" => "elf.staleness_observed",
      "schema_version" => 1,
      "actor" => "elf",
      "occurred_at" => now,
      "idempotency_key" => idempotency_key,
      "payload" => %{
        "run_id" => run.id,
        "observation_id" => observation_id,
        "observed_at" => DateTime.to_iso8601(now),
        "evidence" => evidence
      }
    }

    append_opts =
      [trusted: [task_id: run.task_id, run_id: run.id]] ++
        Keyword.take(opts, [:writer_opts, :dispatch_fun, :call_timeout])

    case Trajectory.append(run.goal_id, attrs, append_opts) do
      {:ok, event} -> {:ok, :persisted, event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
