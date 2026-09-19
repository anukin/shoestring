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
  | decisions | the goal's recent `admission.decided` history (decision_id + reason_code + admission source event id, newest last, at most `@max_decision_entries`); empty history is honestly `[]`, never invented |
  | artifact ids | the run's recorded `harness.event_recorded` kind-`"artifact"` payload `artifact_id`s (the run link — `artifacts` rows are goal-scoped with no run column), filtered to goal-owned rows so the `Checkpoints` writer pre-check cannot fail, at most `@max_artifact_ids`; see the artifact inventory below |
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

  ## Artifact inventory (why event references, not an artifact pipeline)

  `artifacts` rows are goal-scoped (`goal_id`, optional `task_id`) with no
  run column, so there is no cheap "artifacts of this run" row query. The
  run linkage that does exist is the durable `harness.event_recorded`
  kind-`"artifact"` payload (`artifact_id`, `run_id`) — including the Elf's
  own terminal log artifact, whose `persist_log_artifact/1` runs
  synchronously *before* the checkpoint attempt in `commit_terminal/2`, so
  it is visible to this collection. This slice therefore populates
  `artifact_ids` from those recorded references only (latest 32, goal
  ownership re-checked in one query), and deliberately builds no artifact
  discovery pipeline: content hashing, media-type filtering, and
  cross-goal joins are out of scope. The deterministic floor template keeps
  `artifact_ids: []` so the writer ownership pre-check cannot fail when the
  artifact linkage itself is what failed.
  """

  import Ecto.Query

  alias Shoestring.Harness.{CheckpointFallback, Checkpoints, Clock}
  alias Shoestring.Trajectory.{Artifact, Goal, Redaction, TrajectoryEvent}
  alias Shoestring.Trajectory.Task, as: TaskSchema

  @max_changed_files 50
  @max_diff_bytes 32 * 1024
  @max_evidence_items 32
  @chunk_bytes 1_900
  @max_verification_lines 40
  @max_events_scanned 500
  @max_decision_entries 8
  @max_artifact_ids 32

  @default_criteria "complete the supervised task per the goal acceptance contract"

  @doc "Maximum `admission.decided` history entries carried as checkpoint decisions."
  @spec max_decision_entries() :: 8
  def max_decision_entries, do: @max_decision_entries

  @doc "Maximum recorded artifact references carried as checkpoint `artifact_ids`."
  @spec max_artifact_ids() :: 32
  def max_artifact_ids, do: @max_artifact_ids

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
  Deterministic checkpoint id for a run's reactive (lease-decline)
  checkpoint.

  Same construction as `checkpoint_id/1` under a distinct namespace, so a
  run's reactive and terminal checkpoints never collide while every retry
  of the decline path converges on one idempotent row via the
  `Checkpoints` writer (`"checkpoint-created:<id>"` replays instead of
  duplicating). Callers pin `state.lease_checkpoint_id` to this before
  writing; `record_reactive/3` derives it from `state.run_id` when the
  caller has not pinned one.
  """
  @spec reactive_checkpoint_id(Ecto.UUID.t()) :: Ecto.UUID.t()
  def reactive_checkpoint_id(run_id) when is_binary(run_id) do
    <<b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, _::binary>> =
      :crypto.hash(:sha256, "shoestring:reactive-checkpoint:v1:#{run_id}")

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
          build_and_write(state, fallback_inputs(state, terminal, reason, opts), opts, nil)
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
  Collects reactive (lease-decline) checkpoint inputs with real repository
  evidence.

  Same deterministic collectors as `collect/3` (worktree identity, git
  revision/dirty/diff/changed files, verification trajectory, last safe
  boundary, lease snapshot, goal/task acceptance contract), but keyed for
  the lease path: `stop_reason` is the caller-supplied lease reason
  (e.g. `"lease_exhausted"`), the checkpoint id is the Elf's
  `lease_checkpoint_id` (stable per run so retries replay), the extension
  kind is `"reactive"`, and the next action is the deterministic
  decline-resume instruction. Unavailable facts are stated explicitly;
  nothing is inferred.

  Returns `{:ok, inputs}` or `{:error, reason}` (the caller applies the
  reactive floor template). Never raises.
  """
  @spec collect_reactive(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def collect_reactive(state, reason, opts \\ []) do
    checkpoint_id = reactive_id(state)

    with {:ok, worktree} <- resolve_worktree(state, opts),
         {:ok, git} <- git_evidence(worktree, opts),
         {:ok, verification} <- verification_evidence(state, opts),
         {:ok, boundary} <- boundary_evidence(state, opts) do
      revision = git.revision
      dirty? = git.dirty?
      stop = reactive_stop_reason(reason)

      evidence =
        assemble_evidence(
          worktree: worktree,
          git: git,
          verification: verification,
          boundary: boundary,
          lease: lease_snapshot(state),
          outcome: "interrupted",
          stop: stop,
          provider_session: session_text(state),
          os_exit: os_exit_text(state),
          terminal_key: reactive_key(state),
          checkpoint_id: checkpoint_id,
          terminal_type: "lease.decline"
        )

      with {:ok, evidence} <- check_evidence_budget(evidence) do
        {:ok,
         %{
           checkpoint_id: checkpoint_id,
           goal_id: state.goal_id,
           run_id: state.run_id,
           acceptance_criteria: acceptance_criteria(state, opts),
           repository_revision: revision,
           repository_dirty: dirty?,
           evidence: evidence,
           decisions: terminal_decisions(state, opts),
           unresolved_issues: reactive_unresolved(state, reason),
           next_action: reactive_next_action(state, reason, revision, checkpoint_id),
           stop_reason: stop,
           provider_session_id: state.provider_session_id,
           artifact_ids: terminal_artifact_ids(state, opts),
           extensions: reactive_extensions(state, reason, nil)
         }}
      end
    end
  rescue
    error -> {:error, {:reactive_checkpoint_collection_crashed, error}}
  catch
    kind, reason -> {:error, {:reactive_checkpoint_collection_caught, {kind, reason}}}
  end

  @doc """
  Collects reactive checkpoint inputs and records them through the
  `Checkpoints` writer.

  Mirrors `record/3`: full collection first, deterministic reactive floor
  template on collection failure, one floor retry when the first write
  fails. Returns `{:ok, checkpoint_id}` or `{:error, reason}`. Never
  raises.
  """
  @spec record_reactive(map(), String.t(), keyword()) ::
          {:ok, Ecto.UUID.t()} | {:error, term()}
  def record_reactive(state, reason, opts \\ []) do
    checkpoint_id = reactive_id(state)
    state = Map.put(state, :lease_checkpoint_id, checkpoint_id)

    result =
      case collect_reactive(state, reason, opts) do
        {:ok, inputs} ->
          build_and_write(state, inputs, opts, nil)

        {:error, collection_error} ->
          build_and_write(
            state,
            reactive_floor_inputs(state, reason, collection_error, opts),
            opts,
            nil
          )
      end

    case result do
      {:ok, recorded_id} -> {:ok, recorded_id}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:reactive_checkpoint_crashed, error}}
  catch
    kind, reason -> {:error, {:reactive_checkpoint_caught, {kind, reason}}}
  end

  @doc """
  The deterministic reactive floor template: used when collection finds
  nothing. Revision is `"unknown"`, the lease reason and last durable
  event are pointed at precisely, and a rerun verification command is
  named. No certainty is invented.
  """
  @spec reactive_floor_inputs(map(), String.t(), term(), keyword()) :: map()
  def reactive_floor_inputs(state, reason, collection_error, opts \\ []) do
    anchor = last_event_anchor(state)
    checkpoint_id = reactive_id(state)
    stop = reactive_stop_reason(reason)

    %{
      checkpoint_id: checkpoint_id,
      goal_id: state.goal_id,
      run_id: state.run_id,
      acceptance_criteria: acceptance_criteria(state, opts),
      repository_revision: "unknown",
      repository_dirty: false,
      evidence:
        Redaction.redact([
          "reactive checkpoint floor: repo-evidence collection failed " <>
            "(#{short_reason(collection_error)}); no worktree state is claimed",
          "no verification recorded",
          "lease #{stop} for run #{state.run_id} " <>
            "(decline key #{reactive_key(state)}); last durable event: #{anchor}"
        ]),
      decisions: terminal_decisions(state, opts),
      unresolved_issues: reactive_unresolved(state, reason),
      next_action: reactive_next_action(state, reason, "unknown", checkpoint_id),
      stop_reason: stop,
      provider_session_id: state.provider_session_id,
      artifact_ids: [],
      extensions: reactive_extensions(state, reason, collection_error)
    }
  end

  # -- Acceptance contract (goal/task rows, never invented) --

  # Stable reactive id: the pinned `lease_checkpoint_id` when the caller
  # set one, otherwise derived deterministically from the run id so every
  # retry of the decline path converges on one idempotent row. A random id
  # is only the last resort for states without a run id (never the Elf,
  # which always has one).
  defp reactive_id(state) do
    case Map.get(state, :lease_checkpoint_id) do
      id when is_binary(id) ->
        id

      _other ->
        case Map.get(state, :run_id) do
          run_id when is_binary(run_id) -> reactive_checkpoint_id(run_id)
          _other -> Ecto.UUID.generate()
        end
    end
  end

  # Deterministic acceptance criteria from the durable goal/task rows: one
  # bounded entry per row so a long goal can never drop the task contract.
  # Each entry is redacted BEFORE truncation (a replacement can expand past
  # the budget, so truncate-then-redact could overflow the writer). Order
  # is fixed (goal, then task). Unavailable facts are stated explicitly
  # ("unknown"/"not found"); no model inference, no transcript. Always a
  # non-empty list within the fallback text budget.
  defp acceptance_criteria(state, opts) do
    repo = Keyword.get(opts, :repo, Map.get(state, :repo))
    goal_id = Map.get(state, :goal_id)
    task_id = Map.get(state, :task_id)

    [
      "accept #{goal_criterion(repo, goal_id)}",
      "accept #{task_criterion(repo, goal_id, task_id)}"
    ]
    |> Redaction.redact()
    |> Enum.map(&truncate_criterion/1)
  rescue
    _error -> [@default_criteria]
  catch
    _kind, _reason -> [@default_criteria]
  end

  defp goal_criterion(repo, goal_id) when is_atom(repo) and is_binary(goal_id) do
    case repo.get(Goal, goal_id) do
      %Goal{title: title, description: description} ->
        "goal #{goal_id} #{criterion_title(title)} — #{criterion_description(description)}"

      nil ->
        "goal #{goal_id} unavailable: goal row not found"

      _other ->
        "goal #{goal_id} unavailable: goal row unreadable"
    end
  rescue
    _error -> "goal #{inspect(goal_id)} unavailable: goal lookup failed"
  catch
    _kind, _reason -> "goal unavailable: goal lookup failed"
  end

  defp goal_criterion(_repo, goal_id),
    do: "goal #{inspect(goal_id)} unavailable: goal id missing"

  defp task_criterion(repo, goal_id, task_id) when is_atom(repo) and is_binary(task_id) do
    case repo.get(TaskSchema, task_id) do
      %TaskSchema{goal_id: ^goal_id, title: title, description: description} ->
        "task #{task_id} #{criterion_title(title)} — #{criterion_description(description)}"

      %TaskSchema{goal_id: other_goal} when is_binary(other_goal) ->
        "task #{task_id} unavailable: task belongs to another goal"

      nil ->
        "task #{task_id} unavailable: task row not found"

      _other ->
        "task #{task_id} unavailable: task row unreadable"
    end
  rescue
    _error -> "task #{inspect(task_id)} unavailable: task lookup failed"
  catch
    _kind, _reason -> "task unavailable: task lookup failed"
  end

  defp task_criterion(_repo, _goal_id, task_id),
    do: "task #{inspect(task_id)} unavailable: task id missing"

  defp criterion_title(title) when is_binary(title) and title != "", do: inspect(title)
  defp criterion_title(_title), do: "(unknown title)"

  defp criterion_description(description) when is_binary(description) and description != "",
    do: description

  defp criterion_description(_description), do: "no description stated"

  defp truncate_criterion(text) when byte_size(text) <= 2_000, do: text

  defp truncate_criterion(text),
    do: String.slice(text, 0, 2_000 - String.length("…[truncated]")) <> "…[truncated]"

  defp reactive_stop_reason(reason) when is_binary(reason) and reason != "" do
    String.slice(reason, 0, 300)
  end

  defp reactive_stop_reason(_reason), do: "lease_exhausted"

  defp reactive_key(state), do: "elf-lease-decline:#{Map.get(state, :dispatch_id)}"

  defp reactive_unresolved(state, reason) do
    [
      "lease #{reactive_stop_reason(reason)} for run #{state.run_id}: " <>
        "inspect decline key #{reactive_key(state)} and rerun verification before retry"
    ]
  end

  defp reactive_next_action(state, reason, revision, checkpoint_id) do
    "Lease #{reactive_stop_reason(reason)} for run #{state.run_id} at revision #{revision}. " <>
      "Resume from checkpoint #{checkpoint_id} after re-observing capacity and " <>
      "re-evaluating admission; re-verify with `mix precommit`."
  end

  defp reactive_extensions(state, reason, collection_error) do
    base = %{
      "shoestring.elf:checkpoint_kind" => "reactive",
      "shoestring.elf:lease_decline_reason" => reactive_stop_reason(reason)
    }

    base =
      if Map.get(state, :lease_grant_id) != nil do
        Map.put(base, "shoestring.elf:lease_grant_id", to_string(Map.get(state, :lease_grant_id)))
      else
        base
      end

    if collection_error != nil do
      Map.put(base, "shoestring.elf:checkpoint_error", short_reason(collection_error))
    else
      base
    end
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
           acceptance_criteria: acceptance_criteria(state, opts),
           repository_revision: revision,
           repository_dirty: dirty?,
           evidence: evidence,
           decisions: terminal_decisions(state, opts),
           unresolved_issues: unresolved_issues(terminal, state),
           next_action: next_action(terminal, state, revision, verification),
           stop_reason: stop,
           provider_session_id: state.provider_session_id,
           artifact_ids: terminal_artifact_ids(state, opts),
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
  @spec fallback_inputs(map(), map(), term(), keyword()) :: map()
  def fallback_inputs(state, terminal, reason, opts \\ []) do
    anchor = last_event_anchor(state)

    %{
      checkpoint_id: checkpoint_id(state.run_id),
      goal_id: state.goal_id,
      run_id: state.run_id,
      acceptance_criteria: acceptance_criteria(state, opts),
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
      # The floor still attempts the durable admission history (honestly []
      # when absent) but keeps artifact_ids [] so the writer ownership
      # pre-check cannot fail on the retry path.
      decisions: terminal_decisions(state, opts),
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
            # Reactive inputs retry with the reactive floor (stable lease
            # checkpoint id); terminal inputs retry with the terminal floor.
            floor = floor_for(inputs, state, reason, opts)
            build_and_write(state, floor, opts, reason)

          _already_floored ->
            {:error, {:terminal_checkpoint_write_failed, first_error, reason}}
        end
    end
  end

  defp floor_for(
         %{extensions: %{"shoestring.elf:checkpoint_kind" => "reactive"}} = inputs,
         state,
         reason,
         opts
       ) do
    lease_reason =
      inputs[:stop_reason] || Map.get(inputs, "stop_reason", "lease_exhausted")

    reactive_floor_inputs(state, to_string(lease_reason), reason, opts)
  end

  defp floor_for(inputs, state, reason, opts) do
    fallback_inputs(state, terminal_of(inputs), reason, opts)
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

  # Recent admission history as checkpoint decisions: `decision_id` +
  # `reason_code` with the admission source event id, oldest first. Empty
  # history is honestly [] — nothing is invented. Query failure degrades to
  # [] (enrichment must never fail the checkpoint); callers that need a
  # hard failure use the evidence-budget path instead.
  defp terminal_decisions(state, opts) do
    repo = Keyword.get(opts, :repo, state.repo)

    rows =
      repo.all(
        from event in TrajectoryEvent,
          where: event.goal_id == ^state.goal_id and event.type == "admission.decided",
          order_by: [desc: event.sequence],
          limit: ^@max_decision_entries,
          select: {event.id, event.payload}
      )

    rows
    |> Enum.reverse()
    |> Enum.map(&decision_line/1)
    |> Enum.filter(&is_binary/1)
    |> Redaction.redact()
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp decision_line({event_id, %{"decision_id" => decision_id} = payload})
       when is_binary(decision_id) do
    reason_code = Map.get(payload, "reason_code")

    reason_text =
      if is_binary(reason_code) and reason_code != "", do: reason_code, else: "unknown"

    "decision #{decision_id} (#{reason_text}; admission event #{event_id})"
  end

  defp decision_line(_other), do: nil

  # Recorded artifact references for the run (see the artifact inventory in
  # the module doc): `harness.event_recorded` kind-`"artifact"` payloads
  # carry the only run-scoped artifact linkage. Candidates are re-checked
  # against goal-owned artifact rows in one query so the `Checkpoints`
  # writer ownership pre-check cannot fail; anything unowned or
  # unqueryable is dropped, never invented.
  defp terminal_artifact_ids(state, opts) do
    repo = Keyword.get(opts, :repo, state.repo)

    candidates =
      repo.all(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^state.goal_id and event.run_id == ^state.run_id and
              event.type == "harness.event_recorded",
          order_by: [asc: event.sequence],
          select: event.payload
      )
      |> Enum.map(&artifact_candidate/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.take(-@max_artifact_ids)

    case candidates do
      [] ->
        []

      _candidates ->
        owned =
          MapSet.new(
            repo.all(
              from artifact in Artifact,
                where: artifact.goal_id == ^state.goal_id and artifact.id in ^candidates,
                select: artifact.id
            )
          )

        Enum.filter(candidates, &MapSet.member?(owned, &1))
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp artifact_candidate(%{"kind" => "artifact", "artifact_id" => artifact_id}), do: artifact_id
  defp artifact_candidate(%{kind: "artifact", artifact_id: artifact_id}), do: artifact_id
  defp artifact_candidate(_payload), do: nil

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
