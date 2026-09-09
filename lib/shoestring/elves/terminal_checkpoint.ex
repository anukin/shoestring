defmodule Shoestring.Elves.TerminalCheckpoint do
  @moduledoc """
  Terminal-path recovery checkpoints with real repository evidence
  (Milestone 05, work package D loop-closure slice I3).

  The Elf terminal path (`commit_terminal/2` in `Shoestring.Elves.Elf`)
  attempts a checkpoint from durable evidence **before** the terminal commit,
  on every terminal (`completed` / `failed` / `cancelled` / `interrupted`).

  ## Collection inventory (source per field)

  | Checkpoint field | Source |
  | --- | --- |
  | `checkpoint_id` | Deterministic UUID derived from `run_id` (`checkpoint_id/1`), so replays of the terminal path converge on one checkpoint via the `Checkpoints` writer idempotency key |
  | repository identity, base commit, branch | `Shoestring.Worktrees.get/1` record for the run's worktree (durable), else local read-only `git` |
  | current revision, dirty flag | `git rev-parse HEAD` + `git status --porcelain` in the worktree (local `git` only, never the network) |
  | dirty diff STAT + changed-file list | `git diff HEAD --stat` + porcelain list, bounded (50 files, 32 KiB); overflow hard-fails to the floor template, never truncated silently |
  | verification evidence | the run's durable `harness.event_recorded` trajectory events (command/tool/result/error identities + exact statuses/codes) plus the in-memory OS exit status; absent input is stated explicitly as `"no verification recorded"` |
  | last completed safe boundary | latest durable `run.*` / `checkpoint.created` / `lease.*` event for the run (the same boundary rule as `Shoestring.Elves.Staleness`), plus the in-memory reactive lease checkpoint id when set |
  | outcome class + stop reason | the terminal map under commit |
  | lease snapshot | the Elf's in-memory lease bounds/grant/deadline fields |
  | provider session identity | `provider_session_id` when set (resumable), else `"none"` |
  | next action | deterministic per-class recovery instruction with a precise terminal-event pointer and a rerun verification command |

  ## Failure semantics (P2 / P3)

  Collection failure (including bound overflow) falls back to the deterministic
  no-model floor template (`fallback_inputs/3`: revision `"unknown"`, a
  precise last-failure pointer, a rerun command, no invented certainty). A
  writer failure retries once with the floor template carrying a
  `"shoestring.elf:checkpoint_error"` extension; when that also fails the
  error is returned and the caller (`commit_terminal/2`) still commits the
  terminal and logs the error with run/dispatch identity.

  ## Terminal linkage

  `run.*` payloads reject unknown keys (`EventRegistry`), and no new
  trajectory event types are admitted, so the terminal event itself is
  unchanged. The linkage is: the terminal's `run_id` deterministically yields
  the checkpoint id (`checkpoint_id/1`), and the checkpoint extensions carry
  the terminal idempotency key (`"elf-terminal:<dispatch_id>"`) and outcome.

  No timers, no lease accounting changes, no ingest changes.
  """

  import Ecto.Query

  alias Shoestring.Harness.{CheckpointFallback, Checkpoints, Clock}
  alias Shoestring.Trajectory.{Redaction, TrajectoryEvent}

  @max_changed_files 50
  @max_diff_bytes 32 * 1024
  @max_evidence_items 32
  @chunk_bytes 1_900
  @max_verification_lines 40
  @max_events_scanned 500

  @default_criteria "complete the supervised task per the goal acceptance contract"

  @doc """
  Deterministic checkpoint id for a run's terminal checkpoint.

  The SHA-256 of a namespaced run id, formatted as a UUID (version 4,
  variant 10): every replay of the terminal path for the same run offers the
  same id, so the `Checkpoints` writer (`"checkpoint-created:<id>"`) replays
  instead of duplicating.
  """
  @spec checkpoint_id(Ecto.UUID.t()) :: Ecto.UUID.t()
  def checkpoint_id(run_id) when is_binary(run_id) do
    <<b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, _::binary>> =
      :crypto.hash(:sha256, "shoestring:terminal-checkpoint:v1:#{run_id}")

    bytes =
      <<b0, b1, b2, b3, b4, b5, Bitwise.bor(Bitwise.band(b6, 0x0F), 0x40), b7,
        Bitwise.bor(Bitwise.band(b8, 0x3F), 0x80), b9, b10, b11, b12, b13, b14, b15>>

    hex = Base.encode16(bytes, case: :lower)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = hex

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  @doc """
  Collects terminal checkpoint inputs and records them through the
  `Checkpoints` writer.

  `state` is the Elf state (any map with the Elf's terminal-context keys).
  `terminal` is the classifier terminal map under commit.

  Options: `:repo`, `:clock`, `:writer` (`(goal_id, checkpoint, opts) ->
  {:ok, _} | {:error, _}`, default the `Checkpoints` writer; the
  `:terminal_checkpoint_writer` application env (arity-3 fun) is honored as a
  test seam when `:writer` is absent), `:git` (`(path, args) -> {output,
  status}`, default local `git -C`).

  Returns `{:ok, checkpoint_id}` or `{:error, reason}`. Never raises.
  """
  @spec record(map(), map(), keyword()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def record(state, terminal, opts \\ []) do
    id = checkpoint_id(state.run_id)

    result =
      case collect(state, terminal, opts) do
        {:ok, inputs} ->
          build_and_write(state, Map.put(inputs, :checkpoint_id, id), opts, nil)

        {:error, reason} ->
          build_and_write(state, fallback_inputs(state, terminal, reason), opts, nil)
      end

    case result do
      {:ok, recorded_id} -> {:ok, recorded_id}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:terminal_checkpoint_crashed, error}}
  catch
    kind, reason -> {:error, {:terminal_checkpoint_caught, {kind, reason}}}
  end

  @doc """
  Collects `CheckpointFallback.build/1` inputs with real repository evidence.

  Returns `{:ok, inputs}` or `{:error, reason}` (the caller applies the floor
  template). Never raises.
  """
  @spec collect(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def collect(state, terminal, opts \\ []) do
    with {:ok, worktree} <- resolve_worktree(state, opts),
         {:ok, git} <- git_evidence(worktree, opts),
         {:ok, verification} <- verification_evidence(state, opts),
         {:ok, boundary} <- boundary_evidence(state, opts) do
      revision = git.revision
      dirty? = git.dirty?
      outcome = outcome_class(terminal)
      stop = stop_reason(terminal, state)

      evidence =
        assemble_evidence(
          worktree: worktree,
          git: git,
          verification: verification,
          boundary: boundary,
          lease: lease_snapshot(state),
          outcome: outcome,
          stop: stop,
          provider_session: session_text(state),
          os_exit: os_exit_text(state),
          terminal_key: terminal_key(state),
          checkpoint_id: checkpoint_id(state.run_id),
          terminal_type: terminal_type(terminal)
        )

      with {:ok, evidence} <- check_evidence_budget(evidence) do
        {:ok,
         %{
           goal_id: state.goal_id,
           run_id: state.run_id,
           acceptance_criteria: [@default_criteria],
           repository_revision: revision,
           repository_dirty: dirty?,
           evidence: evidence,
           decisions: [],
           unresolved_issues: unresolved_issues(terminal, state),
           next_action: next_action(terminal, state, revision, verification),
           stop_reason: stop,
           provider_session_id: state.provider_session_id,
           artifact_ids: [],
           extensions: terminal_extensions(state, terminal, nil)
         }}
      end
    end
  rescue
    error -> {:error, {:terminal_checkpoint_collection_crashed, error}}
  catch
    kind, reason -> {:error, {:terminal_checkpoint_collection_caught, {kind, reason}}}
  end

  @doc """
  The deterministic floor template inputs (P3): used when collection finds
  nothing (e.g. failed-before-start) or a bound overflows. Revision is
  `"unknown"`, the last failure is pointed at precisely, and a rerun
  verification command is named. No certainty is invented.
  """
  @spec fallback_inputs(map(), map(), term()) :: map()
  def fallback_inputs(state, terminal, reason) do
    anchor = last_event_anchor(state)

    %{
      checkpoint_id: checkpoint_id(state.run_id),
      goal_id: state.goal_id,
      run_id: state.run_id,
      acceptance_criteria: [@default_criteria],
      repository_revision: "unknown",
      repository_dirty: false,
      evidence:
        Redaction.redact([
          "terminal checkpoint floor: repo-evidence collection failed " <>
            "(#{short_reason(reason)}); no worktree state is claimed",
          "no verification recorded",
          "last failure: #{terminal_type(terminal)} #{failure_detail(terminal)} " <>
            "(terminal key #{terminal_key(state)})",
          "last durable event: #{anchor}"
        ]),
      decisions: [],
      unresolved_issues: unresolved_issues(terminal, state),
      next_action: next_action(terminal, state, "unknown", %{lines: [], total: 0, shown: 0}),
      stop_reason: stop_reason(terminal, state),
      provider_session_id: state.provider_session_id,
      artifact_ids: [],
      extensions: terminal_extensions(state, terminal, reason)
    }
  end

  # -- Writer --

  defp build_and_write(state, inputs, opts, first_error) do
    repo = Keyword.get(opts, :repo, state.repo)
    clock = Keyword.get(opts, :clock, state.clock)

    with {:ok, checkpoint} <- CheckpointFallback.build(inputs),
         {:ok, recorded} <-
           writer(opts).(state.goal_id, checkpoint,
             repo: repo,
             now: Clock.now(clock),
             actor: "elf"
           ) do
      {:ok, recorded.checkpoint_id}
    else
      {:error, reason} ->
        case first_error do
          nil ->
            # One floor retry so a full-inputs failure still lands durable
            # evidence (carrying the first error) instead of nothing.
            floor = fallback_inputs(state, terminal_of(inputs), reason)
            build_and_write(state, floor, opts, reason)

          _already_floored ->
            {:error, {:terminal_checkpoint_write_failed, first_error, reason}}
        end
    end
  end

  # The floor retry needs the terminal class for its template; recover it
  # from the inputs that just failed (stop_reason encodes the class).
  defp terminal_of(%{stop_reason: "run.completed" <> _}), do: %{class: :completed}
  defp terminal_of(%{stop_reason: "run.cancelled" <> _}), do: %{class: :cancelled}
  defp terminal_of(%{stop_reason: "run.interrupted" <> _}), do: %{class: :interrupted}

  defp terminal_of(%{stop_reason: "run.failed" <> rest}) do
    case String.split(rest, ":", parts: 2) do
      [_empty, code] -> %{class: :failed, error_category: "unknown", error_code: code}
      _other -> %{class: :failed, error_category: "unknown", error_code: "unknown"}
    end
  end

  defp terminal_of(_inputs),
    do: %{class: :failed, error_category: "unknown", error_code: "unknown"}

  defp writer(opts) do
    cond do
      is_function(Keyword.get(opts, :writer), 3) ->
        Keyword.get(opts, :writer)

      is_function(Application.get_env(:shoestring, :terminal_checkpoint_writer), 3) ->
        Application.get_env(:shoestring, :terminal_checkpoint_writer)

      true ->
        fn goal_id, checkpoint, wopts -> Checkpoints.record(goal_id, checkpoint, wopts) end
    end
  end

  # -- Worktree identity --

  defp resolve_worktree(state, _opts) do
    workspace_ref = state.request.workspace_ref
    root = Shoestring.State.path(:worktrees)
    candidate = Path.join(root, to_string(workspace_ref))

    cond do
      not is_binary(workspace_ref) or workspace_ref == "" ->
        {:error, {:no_worktree_evidence, "workspace_ref missing"}}

      not File.dir?(candidate) ->
        {:error, {:no_worktree_evidence, "worktree directory missing for #{workspace_ref}"}}

      true ->
        case Shoestring.Worktrees.get(Path.expand(candidate)) do
          {:ok, worktree} ->
            {:ok,
             %{
               status: :recognized,
               path: worktree.path,
               branch: worktree.branch,
               base_commit: worktree.base_commit,
               repo_id: worktree.repo_id,
               repo_path: worktree.repo_path,
               workspace_ref: workspace_ref
             }}

          {:error, reason} ->
            {:ok,
             %{
               status: :unrecognized,
               path: Path.expand(candidate),
               branch: "unknown",
               base_commit: "unknown",
               repo_id: "unknown",
               repo_path: "unknown",
               workspace_ref: workspace_ref,
               record_error: inspect(reason)
             }}
        end
    end
  rescue
    error -> {:error, {:no_worktree_evidence, "worktree resolution crashed: #{inspect(error)}"}}
  catch
    kind, reason ->
      {:error, {:no_worktree_evidence, "worktree resolution caught: #{inspect({kind, reason})}"}}
  end

  # -- Git evidence (local `git` only) --

  defp git_evidence(%{status: :recognized} = worktree, opts) do
    git_evidence_in(worktree, opts)
  end

  defp git_evidence(%{status: :unrecognized} = worktree, opts) do
    git_evidence_in(worktree, opts)
  end

  defp git_evidence_in(worktree, opts) do
    git = Keyword.get(opts, :git, &default_git/2)
    path = worktree.path

    with {:ok, revision} <- git_value(git, path, ["rev-parse", "HEAD"], :revision),
         {:ok, porcelain} <-
           git_value(git, path, ["status", "--porcelain=v1", "--untracked-files=all"], :status),
         {:ok, stat} <- git_value(git, path, ["diff", "HEAD", "--stat"], :diff_stat) do
      files = porcelain |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

      if length(files) > @max_changed_files do
        {:error,
         {:checkpoint_overflow,
          %{field: :changed_files, limit: @max_changed_files, actual: length(files)}}}
      else
        if byte_size(stat) > @max_diff_bytes do
          {:error,
           {:checkpoint_overflow,
            %{field: :diff_stat, limit: @max_diff_bytes, actual: byte_size(stat)}}}
        else
          branch =
            case git.(path, ["branch", "--show-current"]) do
              {name, 0} ->
                name = String.trim(name)
                if name == "", do: worktree.branch, else: name

              _other ->
                worktree.branch
            end

          {:ok,
           %{
             revision: revision,
             branch: branch,
             porcelain: porcelain,
             files: files,
             stat: stat,
             dirty?: porcelain != "" or stat != ""
           }}
        end
      end
    end
  end

  defp default_git(path, args) do
    System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
  end

  defp git_value(git, path, args, field) do
    case git.(path, args) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, status} -> {:error, {:git_failed, field, status}}
    end
  rescue
    error -> {:error, {:git_crashed, field, error}}
  catch
    kind, reason -> {:error, {:git_caught, field, {kind, reason}}}
  end

  # -- Trajectory evidence --

  defp verification_evidence(state, opts) do
    repo = Keyword.get(opts, :repo, state.repo)

    rows =
      repo.all(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^state.goal_id and event.run_id == ^state.run_id and
              event.type == "harness.event_recorded",
          order_by: [asc: event.sequence],
          select: {event.sequence, event.payload}
      )

    lines =
      rows
      |> Enum.flat_map(&verification_line/1)
      |> Enum.filter(&is_binary/1)

    skipped =
      rows
      |> Enum.count(fn {_seq, payload} -> not verification_kind?(payload["kind"]) end)

    total = length(lines)

    shown_lines =
      if total > @max_verification_lines do
        Enum.take(lines, -@max_verification_lines)
      else
        lines
      end

    {:ok, %{lines: shown_lines, total: total, skipped: skipped}}
  rescue
    error -> {:error, {:verification_evidence_failed, error}}
  catch
    kind, reason -> {:error, {:verification_evidence_caught, {kind, reason}}}
  end

  defp verification_kind?(kind) when kind in ~w(command tool result error), do: true
  defp verification_kind?(_kind), do: false

  defp verification_line({_sequence, %{"kind" => "command"} = payload}) do
    ["command #{payload["source_event_id"]} ordinal #{payload["ordinal"]}"]
  end

  defp verification_line({_sequence, %{"kind" => "tool"} = payload}) do
    ["tool #{payload["source_event_id"]} ordinal #{payload["ordinal"]}"]
  end

  defp verification_line({_sequence, %{"kind" => "result"} = payload}) do
    ["result #{payload["source_event_id"]} status #{get_in(payload, ["result", "status"])}"]
  end

  defp verification_line({_sequence, %{"kind" => "error"} = payload}) do
    [
      "error #{payload["source_event_id"]} #{get_in(payload, ["error", "category"])}/#{get_in(payload, ["error", "code"])}"
    ]
  end

  defp verification_line(_other), do: []

  defp boundary_evidence(state, opts) do
    repo = Keyword.get(opts, :repo, state.repo)

    rows =
      repo.all(
        from event in TrajectoryEvent,
          where: event.goal_id == ^state.goal_id and event.run_id == ^state.run_id,
          order_by: [desc: event.sequence],
          limit: @max_events_scanned,
          select: {event.sequence, event.type}
      )

    boundary =
      Enum.find(rows, fn {_sequence, type} ->
        String.starts_with?(type, "run.") or type in ["checkpoint.created"] or
          String.starts_with?(type, "lease.")
      end)

    description =
      case boundary do
        nil -> "none recorded"
        {sequence, type} -> "#{type} at sequence #{sequence}"
      end

    description =
      case state.lease_checkpoint_id do
        nil -> description
        id -> "#{description}; reactive lease checkpoint #{id}"
      end

    {:ok, description}
  rescue
    error -> {:error, {:boundary_evidence_failed, error}}
  catch
    kind, reason -> {:error, {:boundary_evidence_caught, {kind, reason}}}
  end

  defp last_event_anchor(state) do
    repo = state.repo

    case repo.all(
           from event in TrajectoryEvent,
             where: event.goal_id == ^state.goal_id and event.run_id == ^state.run_id,
             order_by: [desc: event.sequence],
             limit: 1,
             select: {event.sequence, event.type}
         ) do
      [{sequence, type}] -> "#{type} at sequence #{sequence}"
      [] -> "no durable events"
    end
  rescue
    _error -> "unknown"
  catch
    _kind, _reason -> "unknown"
  end

  # -- Assembly --

  defp assemble_evidence(parts) do
    worktree = Keyword.fetch!(parts, :worktree)
    git = Keyword.fetch!(parts, :git)
    verification = Keyword.fetch!(parts, :verification)

    identity =
      "repository #{worktree.repo_id} worktree #{worktree.path} " <>
        "branch #{git.branch} base #{worktree.base_commit} " <>
        "revision #{git.revision} dirty #{git.dirty?} " <>
        "(#{worktree.status}; workspace_ref #{worktree.workspace_ref})"

    changed =
      case git.files do
        [] -> ["changed files: none"]
        files -> chunk_lines("changed files:", files)
      end

    stat =
      if git.stat == "" do
        ["diff stat: clean"]
      else
        chunk_text("diff stat:", git.stat)
      end

    verification_block = verification_block(verification, Keyword.fetch!(parts, :os_exit))

    [
      identity
      | stat ++
          changed ++
          verification_block ++
          [
            "last safe boundary: #{Keyword.fetch!(parts, :boundary)}",
            "lease: #{Keyword.fetch!(parts, :lease)}",
            "outcome #{Keyword.fetch!(parts, :outcome)} stop #{Keyword.fetch!(parts, :stop)} " <>
              "provider_session #{Keyword.fetch!(parts, :provider_session)}",
            "terminal event #{Keyword.fetch!(parts, :terminal_type)} " <>
              "key #{Keyword.fetch!(parts, :terminal_key)} " <>
              "checkpoint #{Keyword.fetch!(parts, :checkpoint_id)}"
          ]
    ]
    |> Redaction.redact()
  end

  defp verification_block(%{lines: [], total: 0}, os_exit) do
    ["verification: no verification recorded during the run; os exit #{os_exit}"]
  end

  defp verification_block(%{lines: lines, total: total, skipped: skipped}, os_exit) do
    header =
      if total > @max_verification_lines or skipped > 0 do
        "verification (newest #{length(lines)} of #{total} command/result lines shown" <>
          skipped_note(skipped) <> "; full record in trajectory harness.event_recorded):"
      else
        "verification:"
      end

    chunk_lines("#{header} os exit #{os_exit};", lines)
  end

  defp skipped_note(0), do: ""
  defp skipped_note(skipped), do: "; #{skipped} lifecycle/capacity/artifact events omitted"

  defp chunk_lines(header, lines) do
    lines
    |> Enum.reduce([""], fn line, [current | rest] ->
      candidate = if current == "", do: line, else: current <> "\n" <> line

      if byte_size(candidate) > @chunk_bytes do
        [line, current | rest]
      else
        [candidate | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {body, index} -> "#{header} (part #{index}):\n#{body}" end)
  end

  defp chunk_text(header, text) do
    text
    |> chunk_binary()
    |> Enum.with_index(1)
    |> Enum.map(fn {body, index} -> "#{header} (part #{index}):\n#{body}" end)
  end

  defp chunk_binary(text) when byte_size(text) <= @chunk_bytes, do: [text]

  defp chunk_binary(text) do
    {head, rest} = :erlang.split_binary(text, @chunk_bytes)
    [head | chunk_binary(rest)]
  end

  defp check_evidence_budget(evidence) when length(evidence) > @max_evidence_items do
    {:error,
     {:checkpoint_overflow,
      %{field: :evidence, limit: @max_evidence_items, actual: length(evidence)}}}
  end

  defp check_evidence_budget(evidence), do: {:ok, evidence}

  # -- Terminal-derived fields --

  defp outcome_class(%{class: class})
       when class in [:completed, :failed, :cancelled, :interrupted] do
    Atom.to_string(class)
  end

  defp outcome_class(_terminal), do: "failed"

  defp terminal_type(%{class: :completed}), do: "run.completed"
  defp terminal_type(%{class: :interrupted}), do: "run.interrupted"
  defp terminal_type(%{class: :cancelled}), do: "run.cancelled"
  defp terminal_type(_terminal), do: "run.failed"

  defp failure_detail(%{class: :failed, error_category: category, error_code: code}) do
    "error #{category}/#{code}"
  end

  defp failure_detail(%{class: :failed}), do: "error unknown/unknown"
  defp failure_detail(%{class: class}), do: "class #{class}"

  defp stop_reason(%{class: :completed}, _state), do: "run.completed"
  defp stop_reason(%{class: :cancelled}, _state), do: "run.cancelled"

  defp stop_reason(%{class: :interrupted} = terminal, state),
    do: "run.interrupted#{lease_suffix(state, terminal)}"

  defp stop_reason(%{class: :failed} = terminal, _state) do
    code = Map.get(terminal, :error_code, "unknown")
    String.slice("run.failed:#{code}", 0, 300)
  end

  defp stop_reason(_terminal, _state), do: "run.failed:unknown"

  defp lease_suffix(state, _terminal) do
    if state.lease_checkpointed?, do: ":lease_exhausted", else: ""
  end

  defp unresolved_issues(%{class: :failed} = terminal, state) do
    [
      "#{terminal_type(terminal)} #{failure_detail(terminal)} for run #{state.run_id}: " <>
        "inspect terminal key #{terminal_key(state)} and rerun verification before retry"
    ]
  end

  defp unresolved_issues(_terminal, _state), do: []

  defp next_action(%{class: :completed} = _terminal, state, revision, _verification) do
    "Run #{state.run_id} completed at revision #{revision}. " <>
      "Verify the worktree with `mix precommit`, then continue from " <>
      "checkpoint #{checkpoint_id(state.run_id)}."
  end

  defp next_action(%{class: :failed} = terminal, state, _revision, verification) do
    "Inspect the #{terminal_type(terminal)} terminal event for run #{state.run_id} " <>
      "(#{failure_detail(terminal)}, terminal key #{terminal_key(state)}), then " <>
      rerun_instruction(verification) <> " before retrying."
  end

  defp next_action(%{class: :cancelled}, state, revision, _verification) do
    "Run #{state.run_id} was cancelled (terminal key #{terminal_key(state)}). " <>
      "Resume only on explicit operator intent; re-verify revision #{revision} with " <>
      "`mix precommit` from checkpoint #{checkpoint_id(state.run_id)}."
  end

  defp next_action(_terminal, state, revision, _verification) do
    "Run #{state.run_id} was interrupted at the safe boundary. Resume from " <>
      "checkpoint #{checkpoint_id(state.run_id)} at revision #{revision}; " <>
      "re-verify with `mix precommit`."
  end

  defp rerun_instruction(%{lines: [], total: 0}) do
    "no verification recorded during the run — rerun `mix precommit` in the worktree to verify"
  end

  defp rerun_instruction(%{lines: lines}) do
    ids =
      lines
      |> Enum.map(fn line ->
        line |> String.split(" ", parts: 2) |> List.last() |> String.split(" ") |> List.first()
      end)
      |> Enum.uniq()
      |> Enum.take(5)
      |> Enum.join(", ")

    "rerun `mix precommit` (recorded verification: #{ids}) to verify"
  end

  defp terminal_key(state), do: "elf-terminal:#{state.dispatch_id}"

  defp terminal_extensions(state, terminal, collection_error) do
    base = %{
      "shoestring.elf:checkpoint_kind" => "terminal",
      "shoestring.elf:terminal_key" => terminal_key(state),
      "shoestring.elf:terminal_outcome" => outcome_class(terminal)
    }

    base =
      if state.lease_grant_id != nil do
        Map.put(base, "shoestring.elf:lease_grant_id", to_string(state.lease_grant_id))
      else
        base
      end

    if collection_error != nil do
      Map.put(base, "shoestring.elf:checkpoint_error", short_reason(collection_error))
    else
      base
    end
  end

  defp short_reason(reason) do
    reason |> inspect() |> String.slice(0, 200)
  end

  defp lease_snapshot(state) do
    case state.lease_bounds do
      %{
        responses: responses,
        tools: tools,
        response_budget: response_budget,
        tool_budget: tool_budget
      } ->
        "responses #{responses}/#{response_budget} tools #{tools}/#{tool_budget} " <>
          "grant #{state.lease_grant_id || "none"} deadline #{deadline_text(state)} " <>
          "reactive_checkpoint #{state.lease_checkpoint_id || "none"}"

      _other ->
        "none (no lease grant for run)"
    end
  end

  defp deadline_text(%{lease_deadline: %DateTime{} = deadline}), do: DateTime.to_iso8601(deadline)
  defp deadline_text(_state), do: "none"

  defp session_text(%{provider_session_id: id}) when is_binary(id), do: id
  defp session_text(_state), do: "none"

  defp os_exit_text(%{os_exit: {:exit_status, status}}), do: "exit_status #{status}"
  defp os_exit_text(%{os_exit: :unknown}), do: "unknown"
  defp os_exit_text(%{os_exit: :no_exit}), do: "no_exit"
  defp os_exit_text(%{os_exit: other}), do: other |> inspect() |> String.slice(0, 100)
  defp os_exit_text(_state), do: "unknown"
end
