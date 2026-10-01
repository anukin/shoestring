defmodule Shoestring.Cobbler.PlanGateRunner do
  @moduledoc """
  Bounded, supervised execution for named trusted plan acceptance gates.

  A plan cites gates by name only (`Shoestring.Cobbler.PlanGate`). The argv
  a name resolves to is owned by that registry — never by the plan, and
  never by a model — and this runner resolves it through
  `PlanGate.argv/1` on every run. There is no path for a plan shell string
  to reach the operating system here.

  ## Bounds

  - **Timeout.** `timeout_ms` (default 120 000, capped at 300 000). A gate
    that exceeds it fails as `{:error, {:gate_timeout, detail}}`; the
    supervised task is killed, never left running.
  - **Output.** The first `@max_output_bytes` (65 536) bytes of combined
    output are kept. Anything beyond fails the run as
    `{:error, {:gate_output_oversized, detail}}`: oversized output fails,
    it is never silently truncated.
  - **Supervision.** Execution runs under a short-lived `Task.Supervisor`
    started by this module, so a gate runs outside the caller and a stuck
    gate cannot wedge the executor. No timer here cancels useful active
    work elsewhere: the timeout applies only to this gate invocation.

  ## Evidence binding

  Every successful run returns evidence bound to the goal, the plan task,
  the revision id/number/digest, the run/attempt, the actual tested git
  commit, and the tested worktree. `verify/3` re-checks that binding:
  stale (digest moved), missing, or forged evidence is refused, and a
  successful run alone — without bound gate evidence — never unlocks a
  dependent.

  ## Test injection

  Hermetic tests pass `runner:` — an internal/test-config function
  `(argv, worktree, timeout_ms -> {:ok, %{exit_status, output, duration_ms}}
  | {:error, reason})`. It replaces the OS invocation only; gate names,
  argv resolution, and evidence binding are unchanged. A plan can never
  supply executable names or results through this option.
  """

  alias Shoestring.Cobbler.PlanGate

  @default_timeout_ms 120_000
  @max_timeout_ms 300_000
  @max_output_bytes 65_536
  @commit_timeout_ms 15_000

  @type context :: %{
          required(:goal_id) => Ecto.UUID.t(),
          required(:plan_task_id) => String.t(),
          required(:revision_number) => pos_integer(),
          required(:plan_digest) => String.t(),
          required(:run_id) => Ecto.UUID.t(),
          required(:attempt) => pos_integer()
        }

  @type evidence :: %{
          required(:goal_id) => Ecto.UUID.t(),
          required(:plan_task_id) => String.t(),
          required(:revision_number) => pos_integer(),
          required(:plan_digest) => String.t(),
          required(:run_id) => Ecto.UUID.t(),
          required(:attempt) => pos_integer(),
          required(:gate) => String.t(),
          required(:gate_argv) => [String.t()],
          required(:commit) => String.t(),
          required(:worktree) => String.t(),
          required(:exit_status) => integer(),
          required(:output) => String.t(),
          required(:duration_ms) => non_neg_integer()
        }

  @doc """
  Runs one validated gate reference and returns bound evidence.

  `gate_ref` is a validated `%{"gate" => name}` reference (optionally with
  `test_paths` for `mix_test`). `context` binds the run to its plan task.
  Options: `:worktree_path` (default `File.cwd!/0`), `:timeout_ms`,
  `:runner` (test injection, see moduledoc).
  """
  @spec run(map(), context(), keyword()) :: {:ok, evidence()} | {:error, term()}
  def run(gate_ref, context, opts \\ []) do
    with {:ok, normalized_context} <- normalize_context(context),
         {:ok, gate} <- gate_name(gate_ref),
         {:ok, argv} <- trusted_argv(gate_ref, gate),
         {:ok, worktree} <- resolve_worktree(opts),
         {:ok, commit} <- resolve_commit(worktree, opts),
         timeout <- resolve_timeout(opts),
         {:ok, result} <- invoke(argv, worktree, timeout, opts),
         :ok <- check_output_size(result, gate) do
      {:ok,
       %{
         goal_id: normalized_context.goal_id,
         plan_task_id: normalized_context.plan_task_id,
         revision_number: normalized_context.revision_number,
         plan_digest: normalized_context.plan_digest,
         run_id: normalized_context.run_id,
         attempt: normalized_context.attempt,
         gate: gate,
         gate_argv: argv,
         commit: commit,
         worktree: worktree,
         exit_status: result.exit_status,
         output: result.output,
         duration_ms: result.duration_ms
       }}
    end
  end

  @doc """
  Verifies bound gate evidence against the context that must have produced it.

  Refuses stale (digest/revision moved), missing, or forged evidence:
  every binding field must match, the argv must be exactly what the named
  gate resolves to, and the commit must be a resolved hex revision. An
  `{:ok, :accepted}` requires `exit_status == 0`; anything else is
  `{:error, {:gate_failed, detail}}` — a successful run alone never
  counts without this evidence.
  """
  @spec verify(map(), map(), context(), keyword()) ::
          {:ok, :accepted} | {:error, term()}
  def verify(gate_ref, evidence, context, _opts \\ []) do
    with {:ok, normalized_context} <- normalize_context(context),
         {:ok, gate} <- gate_name(gate_ref),
         {:ok, argv} <- trusted_argv(gate_ref, gate),
         :ok <- check_binding(evidence, normalized_context, gate, argv) do
      case Map.get(evidence, :exit_status) do
        0 -> {:ok, :accepted}
        status -> {:error, {:gate_failed, %{gate: gate, exit_status: status}}}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Internal
  # ----------------------------------------------------------------------------

  defp normalize_context(context) when is_map(context) do
    with {:ok, goal_id} <- context_uuid(context, :goal_id),
         {:ok, run_id} <- context_uuid(context, :run_id),
         {:ok, plan_task_id} <- context_task_id(context),
         {:ok, revision_number} <- context_positive_int(context, :revision_number),
         {:ok, attempt} <- context_positive_int(context, :attempt),
         {:ok, plan_digest} <- context_digest(context) do
      {:ok,
       %{
         goal_id: goal_id,
         plan_task_id: plan_task_id,
         revision_number: revision_number,
         plan_digest: plan_digest,
         run_id: run_id,
         attempt: attempt
       }}
    end
  end

  defp normalize_context(_context), do: {:error, {:invalid_gate_context, :context}}

  defp context_uuid(context, field) do
    value = Map.get(context, field) || Map.get(context, Atom.to_string(field))

    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_gate_context, field}}
    end
  end

  defp context_task_id(context) do
    value = Map.get(context, :plan_task_id) || Map.get(context, "plan_task_id")

    if is_binary(value) and byte_size(value) > 0 do
      {:ok, value}
    else
      {:error, {:invalid_gate_context, :plan_task_id}}
    end
  end

  defp context_positive_int(context, field) do
    value = Map.get(context, field) || Map.get(context, Atom.to_string(field))

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, {:invalid_gate_context, field}}
    end
  end

  defp context_digest(context) do
    value = Map.get(context, :plan_digest) || Map.get(context, "plan_digest")

    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value) do
      {:ok, value}
    else
      {:error, {:invalid_gate_context, :plan_digest}}
    end
  end

  defp gate_name(%{"gate" => gate}) when is_binary(gate) do
    if gate in PlanGate.names() do
      {:ok, gate}
    else
      {:error, {:unknown_gate, gate}}
    end
  end

  defp gate_name(_reference), do: {:error, {:unknown_gate, nil}}

  defp trusted_argv(gate_ref, _gate) do
    case PlanGate.argv(gate_ref) do
      {:ok, argv} -> {:ok, argv}
      {:error, _changeset} -> {:error, {:unknown_gate, gate_name_only(gate_ref)}}
    end
  end

  defp gate_name_only(%{"gate" => gate}), do: gate
  defp gate_name_only(_reference), do: nil

  defp resolve_worktree(opts) do
    case Keyword.get(opts, :worktree_path, File.cwd!()) do
      path when is_binary(path) and byte_size(path) > 0 ->
        expanded = Path.expand(path)

        if File.dir?(expanded) do
          {:ok, expanded}
        else
          {:error, {:gate_worktree_missing, expanded}}
        end

      _other ->
        {:error, {:gate_worktree_missing, nil}}
    end
  end

  defp resolve_commit(worktree, opts) do
    case Keyword.get(opts, :commit) do
      nil -> read_commit(worktree)
      commit when is_binary(commit) -> check_commit(commit)
      _other -> {:error, {:gate_commit_invalid, nil}}
    end
  end

  defp check_commit(commit) do
    if Regex.match?(~r/\A[0-9a-f]{7,40}\z/, commit) do
      {:ok, commit}
    else
      {:error, {:gate_commit_invalid, commit}}
    end
  end

  defp read_commit(worktree) do
    runner = fn ->
      System.cmd("git", ["rev-parse", "HEAD"], cd: worktree, stderr_to_stdout: true)
    end

    task = Task.async(runner)

    case Task.yield(task, @commit_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {output, 0} ->
        check_commit(String.trim(output))

      {_output, _status} ->
        {:error, {:gate_commit_unresolvable, worktree}}

      nil ->
        {:error, {:gate_commit_unresolvable, worktree}}
    end
  end

  defp resolve_timeout(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> min(timeout, @max_timeout_ms)
      _other -> @default_timeout_ms
    end
  end

  defp invoke(argv, worktree, timeout_ms, opts) do
    case Keyword.get(opts, :runner) do
      nil ->
        invoke_system(argv, worktree, timeout_ms)

      runner when is_function(runner, 3) ->
        normalize_injected(runner.(argv, worktree, timeout_ms))

      _other ->
        {:error, {:invalid_gate_runner, :runner}}
    end
  end

  defp normalize_injected({:ok, %{exit_status: status, output: output} = result})
       when is_integer(status) and is_binary(output) do
    duration = Map.get(result, :duration_ms, 0)

    if is_integer(duration) and duration >= 0 do
      {:ok, %{exit_status: status, output: output, duration_ms: duration}}
    else
      {:ok, %{exit_status: status, output: output, duration_ms: 0}}
    end
  end

  defp normalize_injected({:error, reason}), do: {:error, reason}
  defp normalize_injected(_other), do: {:error, {:invalid_gate_runner, :result}}

  defp invoke_system([executable | args], worktree, timeout_ms) do
    started = System.monotonic_time(:millisecond)

    {:ok, supervisor} = Task.Supervisor.start_link()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        System.cmd(executable, args, cd: worktree, stderr_to_stdout: true)
      end)

    outcome =
      case Task.yield(task, timeout_ms) do
        {output, status} ->
          {:ok,
           %{
             exit_status: status,
             output: output,
             duration_ms: System.monotonic_time(:millisecond) - started
           }}

        nil ->
          _ = Task.Supervisor.terminate_child(supervisor, task.pid)
          {:error, {:gate_timeout, %{timeout_ms: timeout_ms}}}
      end

    _ = Supervisor.stop(supervisor, :normal)
    outcome
  end

  defp check_output_size(%{output: output} = _result, gate) do
    if byte_size(output) > @max_output_bytes do
      {:error, {:gate_output_oversized, %{gate: gate, bytes: byte_size(output)}}}
    else
      :ok
    end
  end

  defp check_binding(evidence, context, gate, argv) when is_map(evidence) do
    expected = [
      {:goal_id, context.goal_id},
      {:plan_task_id, context.plan_task_id},
      {:revision_number, context.revision_number},
      {:plan_digest, context.plan_digest},
      {:run_id, context.run_id},
      {:attempt, context.attempt},
      {:gate, gate},
      {:gate_argv, argv}
    ]

    Enum.reduce_while(expected, :ok, fn {field, want}, :ok ->
      if Map.get(evidence, field) == want do
        {:cont, :ok}
      else
        {:halt, {:error, {:gate_evidence_forged, %{field: field}}}}
      end
    end)
    |> case do
      :ok ->
        case check_commit(Map.get(evidence, :commit)) do
          {:ok, _commit} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  defp check_binding(_evidence, _context, _gate, _argv),
    do: {:error, {:gate_evidence_missing, :evidence}}
end
