defmodule Shoestring.Dispatches.Calls do
  @moduledoc """
  EXPLORE and REVIEW dispatches (iteration 14 package D): one model call
  each, made by the service (`Shoestring.Dispatches.CallWorker`), never an
  Elf run.

  1. A pending call is admitted as a `read_only` call of its provider on the
     subscription scope, against that provider's latest usage reading, as
     iteration 8's reviewer is: Claude and Codex calls are conservative
     candidates, so without a confirmation a call is `held`, and a breached
     reserve defers it (`waiting`). A held call is confirmed by one of the
     grant's unread-usage pre-approvals (`Shoestring.Dispatches.advance/2`),
     never by the coordinator itself.
  2. Admitted, it runs once, within its timeout. A call found `running` when
     its job starts again was lost in a crash and fails as `call_lost`; it is
     never sent twice.
  3. Code checks the output. An EXPLORE report is checked by
     `Shoestring.Dispatches.Explore.validate/2` against the private copy it
     read, which must be unchanged afterwards (`explorer_wrote` otherwise). A
     REVIEW's findings are checked by iteration 8's
     `Shoestring.Cobbler.Review.Findings`, whose rules, not the reviewer,
     decide the outcome (`approved` or `changes_requested`).

  Explore calls end within four minutes and review calls within three, so a
  call never outlives `Oban.Lifeline`'s five-minute rescue of its job.
  Cancelling a running call discards its result; the call itself ends within
  its timeout.
  """
  import Ecto.Query

  alias Shoestring.{Repo, Worktrees}
  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionEvaluation, PlanContract, Plans}
  alias Shoestring.Cobbler.{WakeupObserve}
  alias Shoestring.Cobbler.Review.{Findings, Packet}
  alias Shoestring.Dispatches.{Call, CallWorker, Dispatch, Explore}
  alias Shoestring.Trajectory.TrajectoryEvent

  @scope "subscription"
  @held_recheck_seconds 30
  @explore %{"max_output_tokens" => 8192, "timeout_ms" => 240_000}
  @review %{"max_output_tokens" => 4096, "timeout_ms" => 180_000}

  def get(dispatch_id), do: Repo.get_by(Call, dispatch_id: dispatch_id)

  @doc "How long a call of `purpose` may take, in seconds (the grant reserves it)."
  def seconds("explore"), do: div(@explore["timeout_ms"], 1000)
  def seconds("review"), do: div(@review["timeout_ms"], 1000)

  # -- Inputs --------------------------------------------------------------

  @doc "The immutable input of an EXPLORE call at `base`."
  def explore_input(request, title, brief, base) do
    Map.merge(@explore, %{
      "version" => 1,
      "purpose" => "explore",
      "provider" => request.provider,
      "model" => request.model,
      "effort" => Map.get(request, :effort),
      "base" => base,
      "prompt" => Explore.prompt(%{title: title, brief: brief}),
      "schema" => Explore.schema()
    })
  end

  @doc """
  The immutable input of a REVIEW call of `target`, a completed IMPLEMENT
  dispatch: iteration 8's packet (the change's diff from its base, the goal
  and task contract, and the checks recorded at its completion).
  """
  def review_input(request, %Dispatch{} = target) do
    with %TrajectoryEvent{payload: completed} <- completion(target.goal_id),
         %{revision: revision} <- Plans.authority(target.goal_id),
         [task] <- revision.content["tasks"],
         base = revision.content["goal"]["repository"]["base_revision"],
         commit when is_binary(commit) <- completed["commit"],
         {:ok, worktree} <- worktree_with(target.goal_id, commit),
         {:ok, built} <-
           Packet.build(%{
             goal: revision.content["goal"],
             task: task,
             revision_number: revision.revision_number,
             plan_digest: revision.digest,
             base: base,
             commit: commit,
             worktree: worktree,
             gates: get_in(completed, ["evidence", "gates"]) || []
           }) do
      {:ok,
       Map.merge(@review, %{
         "version" => 1,
         "purpose" => "review",
         "provider" => request.provider,
         "model" => request.model,
         "target_dispatch_id" => target.id,
         "base" => base,
         "commit" => commit,
         "packet_digest" => built.digest,
         "packet_json" => built.json
       })}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :review_target_unavailable}
    end
  end

  defp completion(goal_id) do
    Repo.one(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type == "cobbler.plan.execution.completed",
        order_by: [desc: e.sequence],
        limit: 1
    )
  end

  # The private worktree of the accepted run that holds `commit`.
  defp worktree_with(goal_id, commit) do
    Repo.all(
      from e in TrajectoryEvent,
        where:
          e.goal_id == ^goal_id and e.type == "cobbler.plan.task.accepted" and
            fragment("json_extract(?, '$.commit')", e.payload) == ^commit,
        select: fragment("json_extract(?, '$.run_id')", e.payload)
    )
    |> Enum.find_value({:error, :review_worktree_missing}, fn run_id ->
      case Worktrees.get(run_id) do
        {:ok, worktree} -> {:ok, worktree.path}
        _ -> nil
      end
    end)
  end

  @doc "What a dispatch row records of a call's input: everything but the packet."
  def contract(input), do: Map.delete(input, "packet_json")

  # -- Lifecycle -------------------------------------------------------------

  @doc "Records `dispatch`'s call (once) and queues it. Options: `:oban`."
  def start(%Dispatch{} = dispatch, input, opts \\ []) do
    json = PlanContract.canonical_json(input)

    Repo.insert(
      %Call{
        dispatch_id: dispatch.id,
        target_dispatch_id: input["target_dispatch_id"],
        state: "pending",
        input_json: json,
        input_digest: PlanContract.digest(input)
      },
      on_conflict: :nothing,
      conflict_target: [:dispatch_id]
    )

    case Oban.insert(
           Keyword.get(opts, :oban, Oban),
           CallWorker.new(%{"dispatch_id" => dispatch.id})
         ) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One step of the call of dispatch `id`, as its job runs it: `:done`,
  `{:snooze, seconds}` (held or waiting) or `{:error, reason}`. Options:
  `:now`, `:adapters` and `:adapter_opts` (else the `:dispatch_calls`
  application environment).
  """
  def step(id, opts \\ []) do
    case {Repo.get(Dispatch, id), get(id)} do
      {%Dispatch{} = dispatch, %Call{} = call} -> step(dispatch, call, opts)
      _ -> {:error, :call_not_found}
    end
  end

  defp step(dispatch, %Call{state: "pending"} = call, opts), do: admit(dispatch, call, opts)

  defp step(dispatch, %Call{state: "held"} = call, opts) do
    if call.confirmed_by,
      do: admit(dispatch, call, opts),
      else: {:snooze, @held_recheck_seconds}
  end

  defp step(dispatch, %Call{state: "waiting"} = call, opts) do
    case DateTime.compare(call.defer_until, now(opts)) do
      :gt -> {:snooze, max(DateTime.diff(call.defer_until, now(opts)), 1)}
      _ -> admit(dispatch, call, opts)
    end
  end

  defp step(_dispatch, %Call{state: "running"} = call, opts) do
    finish(call, {:failed, "call_lost", nil}, opts)
    :done
  end

  defp step(_dispatch, _call, _opts), do: :done

  defp admit(dispatch, call, opts) do
    input = Jason.decode!(call.input_json)
    now = now(opts)

    {:ok, decision} =
      AdmissionEvaluation.evaluate(
        %{requested_capability: "read_only", scope: @scope, override: override(call)},
        candidate(input),
        observation(input["provider"]),
        nil,
        now: now
      )

    admission = AdmissionDecision.to_payload(decision)

    case decision.result do
      :admit ->
        case transition(call, "held_or_pending", %{
               state: "running",
               admission: admission,
               started_at: now
             }) do
          {:ok, call} -> run(dispatch, call, input, opts)
          :stale -> :done
        end

      :defer_until ->
        transition(call, "held_or_pending", %{
          state: "waiting",
          admission: admission,
          defer_until: decision.defer_until
        })

        {:snooze, max(DateTime.diff(decision.defer_until, now), 1)}

      :require_confirmation ->
        transition(call, "held_or_pending", %{
          state: "held",
          admission: admission,
          confirmed_by: nil,
          confirmed_at: nil
        })

        {:snooze, @held_recheck_seconds}

      _reject ->
        finish(call, {:failed, decision.reason_code, nil}, opts)
        :done
    end
  end

  defp candidate(input) do
    %{
      provider_id: input["provider"],
      adapter_id: "#{input["purpose"]}.#{input["provider"]}",
      scope: @scope,
      support_tier: :conservative_partial,
      compatibility_state: :compatible,
      capabilities: ["read_only"]
    }
  end

  defp observation(provider) do
    case WakeupObserve.observe(%{provider_id: provider, scope: @scope}) do
      {:ok, snapshot} -> snapshot
      _ -> nil
    end
  end

  defp override(%Call{confirmed_by: nil}), do: nil

  defp override(call) do
    %{
      "confirmed_by" => call.confirmed_by,
      "confirmed_at" => DateTime.to_iso8601(call.confirmed_at),
      "intent" => "coordinator_call"
    }
  end

  defp run(dispatch, call, %{"purpose" => "explore"} = input, opts) do
    result =
      with {:ok, workdir} <- copy(dispatch, call, input) do
        explored =
          bounded(input, fn ->
            adapter(input, opts).explore(Map.put(input, "workdir", workdir), adapter_opts(opts))
          end)

        with {:ok, json, tokens} <- explored,
             :ok <- unchanged(workdir, input["base"]),
             {:ok, report} <- Explore.validate(json, workdir) do
          {:ok, report, tokens}
        else
          {:error, :explorer_wrote} -> {:failed, "explorer_wrote", tokens(explored)}
          {:error, code} -> {:failed, Atom.to_string(code), tokens(explored)}
          {:failed, _, _} = failed -> failed
        end
      else
        {:error, code} -> {:failed, Atom.to_string(code), nil}
      end

    finish(call, result, opts)
    :done
  end

  defp run(_dispatch, call, %{"purpose" => "review"} = input, opts) do
    result =
      case bounded(input, fn ->
             adapter(input, opts).review(
               %{
                 "packet_json" => input["packet_json"],
                 "schema" => Findings.schema(),
                 "model" => input["model"],
                 "max_output_tokens" => input["max_output_tokens"],
                 "timeout_ms" => input["timeout_ms"]
               },
               adapter_opts(opts)
             )
           end) do
        {:ok, json, tokens} ->
          case Findings.validate(json, Jason.decode!(input["packet_json"])) do
            {:ok, findings} -> {:ok, findings, tokens}
            {:error, {kind, _field}} -> {:failed, Atom.to_string(kind), tokens}
          end

        failed ->
          failed
      end

    finish(call, result, opts)
    :done
  end

  # The adapter runs in a task bounded by the call's timeout; its output
  # allowance is checked here too.
  defp bounded(input, fun) do
    task = Task.Supervisor.async_nolink(Shoestring.Cobbler.PlannerTasks, fun)

    case Task.yield(task, input["timeout_ms"]) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{json: json, output_tokens: tokens}}}
      when is_binary(json) and is_integer(tokens) and tokens >= 0 ->
        if tokens <= input["max_output_tokens"],
          do: {:ok, json, tokens},
          else: {:failed, "output_limit", tokens}

      {:ok, {:error, code}} when is_atom(code) ->
        {:failed, Atom.to_string(code), nil}

      {:ok, _other} ->
        {:failed, "invalid_adapter_result", nil}

      {:exit, _} ->
        {:failed, "adapter_exit", nil}

      nil ->
        {:failed, "transport_timeout", nil}
    end
  end

  defp tokens({:ok, _json, tokens}), do: tokens
  defp tokens({:failed, _code, tokens}), do: tokens

  # A private copy of the repository at the dispatch's base commit, in
  # Shoestring's own storage; the user's checkout is never touched.
  defp copy(dispatch, call, input) do
    case Worktrees.create(dispatch.repository_root, "explore-#{call.id}", input["base"],
           private_git: true
         ) do
      {:ok, worktree} ->
        call |> Ecto.Changeset.change(workdir: worktree.path) |> Repo.update!()
        {:ok, worktree.path}

      {:error, _reason} ->
        {:error, :explore_copy_failed}
    end
  end

  defp unchanged(workdir, base) do
    with {head, 0} <- System.cmd("git", ["-C", workdir, "rev-parse", "HEAD"]),
         true <- String.trim(head) == base,
         {"", 0} <-
           System.cmd("git", ["-C", workdir, "status", "--porcelain", "--untracked-files=all"]) do
      :ok
    else
      _ -> {:error, :explorer_wrote}
    end
  end

  defp finish(call, result, opts) do
    {state, changes} =
      case result do
        {:ok, report, tokens} ->
          {"completed",
           %{
             report_json: PlanContract.canonical_json(report),
             report_digest: PlanContract.digest(report),
             output_tokens: tokens
           }}

        {:failed, code, tokens} ->
          {"failed", %{error_code: code, output_tokens: tokens}}
      end

    # A call cancelled while it ran keeps its cancellation; the result is
    # discarded.
    transition(
      call,
      "running",
      Map.merge(changes, %{state: state, finished_at: now(opts)})
    )
  end

  # Compare-and-set on the call's state, so a stale step never overwrites
  # a newer one (a cancellation, or another job's progress).
  defp transition(call, from, changes) do
    from = if from == "held_or_pending", do: ["pending", "held", "waiting"], else: [from]

    {count, _} =
      from(c in Call, where: c.id == ^call.id and c.state in ^from)
      |> Repo.update_all(set: Enum.to_list(Map.put(changes, :updated_at, DateTime.utc_now())))

    if count == 1, do: {:ok, Repo.get!(Call, call.id)}, else: :stale
  end

  @doc """
  Confirms a held call under `identity` (a grant's, through
  `Shoestring.Dispatches.advance/2`); its job admits it at its next check.
  """
  def confirm(%Call{state: "held"} = call, identity) do
    case transition(call, "held", %{confirmed_by: identity, confirmed_at: DateTime.utc_now()}) do
      {:ok, call} -> {:ok, call}
      :stale -> {:error, :not_held}
    end
  end

  def confirm(_call, _identity), do: {:error, :not_held}

  @doc "Cancels a call that has not finished."
  def cancel(%Call{} = call) do
    case transition(call, "held_or_pending", %{
           state: "cancelled",
           finished_at: DateTime.utc_now()
         }) do
      {:ok, call} ->
        {:ok, call}

      :stale ->
        case transition(call, "running", %{state: "cancelled", finished_at: DateTime.utc_now()}) do
          {:ok, call} -> {:ok, call}
          :stale -> {:error, :already_finished}
        end
    end
  end

  @doc "The dispatch state of a call."
  def state(%Call{state: "pending"}), do: "queued"
  def state(%Call{state: "held"}), do: "held"

  def state(%Call{state: "waiting", defer_until: until}),
    do: if(DateTime.compare(until, DateTime.utc_now()) == :gt, do: "waiting", else: "queued")

  def state(%Call{state: state}), do: state

  @doc "The call's report (an EXPLORE report or REVIEW findings), once completed."
  def report(%Call{state: "completed", report_json: json}) when is_binary(json),
    do: Jason.decode!(json)

  def report(_call), do: nil

  defp adapter(%{"purpose" => purpose, "provider" => provider}, opts) do
    configured =
      Keyword.get(opts, :adapters) ||
        Keyword.get(Application.get_env(:shoestring, :dispatch_calls, []), :adapters, %{})

    Map.get(configured, {purpose, provider}) || default_adapter(purpose, provider)
  end

  defp default_adapter("explore", "claude"), do: Explore.ClaudeHeadless
  defp default_adapter("explore", "codex"), do: Explore.CodexExec
  defp default_adapter("review", "claude"), do: Shoestring.Cobbler.Review.ClaudeHeadless
  defp default_adapter("review", "codex"), do: Shoestring.Cobbler.Review.CodexExec

  defp adapter_opts(opts) do
    Keyword.get(opts, :adapter_opts) ||
      Keyword.get(Application.get_env(:shoestring, :dispatch_calls, []), :adapter_opts, [])
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
