defmodule Shoestring.Dispatches.Externals do
  @moduledoc """
  EXTERNAL dispatches (iteration 20): work a person or a program does
  outside Shoestring's guarantee (a desktop app driven by computer use, a
  signed-in browser session, a tool with only a GUI), in a run worktree
  Shoestring made, accepted only by Shoestring's checks.

  Shoestring owns the brief, the worktree, the grant's budget, the clock,
  the checks and the record; it never starts, watches or stops the external
  work, and nothing it does sandboxes that work. The lifecycle
  (`Shoestring.Dispatches.External`):

    * **held** at creation: an EXTERNAL always waits for the person's own
      confirmation (`confirm/3`); a grant's pre-approval never starts one.
    * **awaiting** once confirmed: a private-Git run worktree from the
      dispatch's pinned base, the brief in `<worktree>/.shoestring/brief.md`
      (never committed), and a deadline (the dispatch's seconds). Past the
      deadline it is reported expired and stays answerable: nothing is
      killed or deleted.
    * **completed** when a person completes it (`complete/4`, `human:`
      only) and the worktree is clean, holds a commit beyond the base, and
      every check passes under the gate sandbox. Otherwise **needs_you**
      with the reason; it may be completed again.
    * **abandoned** by a person (`abandon/3`); the worktree is kept.

  Units (`Shoestring.Grants` `units`) are reserved on the row when the
  dispatch is recorded, in the grant check's transaction, and settled at
  completion with the operator's reported actual; an unknown actual (none
  given, or abandoned) keeps the whole reserve counted.

  Before the work starts and at every completion or abandonment the person's
  checkout's `HEAD` and a digest of its `git status` are recorded. A change
  is reported: Shoestring cannot prevent an outside program from touching
  it, only show that it did.
  """

  import Ecto.Query

  alias Shoestring.{Authority, Repo, Trajectory, Worktrees}
  alias Shoestring.Cobbler.PlanGateRunner
  alias Shoestring.Dispatches.{Dispatch, External}
  alias Shoestring.Grants.Grant

  @max_reason 2_000
  @brief_path ".shoestring/brief.md"

  def brief_path, do: @brief_path

  # -- Recording -------------------------------------------------------------

  @doc """
  The units an EXTERNAL reserves: what it asks (`%{name => amount}`), else
  every unit of the grant at its per-dispatch reserve. A unit the grant
  does not have is refused by the grant check.
  """
  def units_for(%Grant{} = grant, nil),
    do: Map.new(grant.units || [], &{&1["name"], &1["reserve"]})

  def units_for(%Grant{} = grant, units) when units == %{}, do: units_for(grant, nil)
  def units_for(_grant, units) when is_map(units), do: units

  @doc "Parses `NAME=N` strings into a units map."
  def parse_units(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, %{}}, fn item, {:ok, acc} ->
      with [name, amount] <- String.split(to_string(item), "=", parts: 2),
           {n, ""} when n >= 0 <- Integer.parse(String.trim(amount)) do
        {:cont, {:ok, Map.put(acc, String.trim(name), n)}}
      else
        _ -> {:halt, {:error, {:invalid_dispatch, :units}}}
      end
    end)
  end

  def parse_units(_), do: {:error, {:invalid_dispatch, :units}}

  @doc "Records the EXTERNAL's row, held, with its reservation (inside the grant check's transaction)."
  def insert!(%Dispatch{} = dispatch, units) do
    Repo.insert!(%External{dispatch_id: dispatch.id, state: "held", units_reserved: units})
  end

  def get(dispatch_id), do: Repo.get_by(External, dispatch_id: dispatch_id)

  @doc "The dispatch-level state of an EXTERNAL."
  def dispatch_state(%External{state: "held"}), do: "held"
  def dispatch_state(%External{state: "awaiting"}), do: "running"
  def dispatch_state(%External{state: "needs_you"}), do: "needs_you"
  def dispatch_state(%External{state: "completed"}), do: "completed"
  def dispatch_state(%External{state: "abandoned"}), do: "cancelled"

  @doc "Whether an awaiting EXTERNAL is past its deadline (evidence only)."
  def expired?(external, now \\ DateTime.utc_now())

  def expired?(%External{state: state, deadline_at: %DateTime{} = deadline}, now)
      when state in ~w(awaiting needs_you),
      do: DateTime.compare(now, deadline) == :gt

  def expired?(%External{expired: expired}, _now), do: expired == true

  @doc "Seconds between confirmation and the end; nil when not finished."
  def took(%External{confirmed_at: %DateTime{} = from, finished_at: %DateTime{} = to}),
    do: div(max(DateTime.diff(to, from, :millisecond), 0) + 999, 1000)

  def took(%External{confirmed_at: nil}), do: 0
  def took(_external), do: nil

  @doc "Units a grant's EXTERNAL dispatches use: actual once settled, else the reserve."
  def units_used(%Grant{id: grant_id}) do
    Repo.all(
      from e in External,
        join: d in Dispatch,
        on: d.id == e.dispatch_id,
        where: d.grant_id == ^grant_id and d.state != "failed",
        select: e
    )
    |> Enum.reduce(%{}, fn external, acc ->
      Enum.reduce(external.units_reserved || %{}, acc, fn {name, reserved}, acc ->
        used =
          case external.units_actual do
            %{^name => actual} when is_integer(actual) -> actual
            _ -> reserved
          end

        Map.update(acc, name, used, &(&1 + used))
      end)
    end)
  end

  # -- Confirmation: the work may start ---------------------------------------

  @doc """
  The person confirms a held EXTERNAL: Shoestring makes its run worktree
  from the pinned base, writes the brief there and starts the clock.
  `:confirmed`, `:none` (not held) or `{:error, reason}`. Options:
  `:worktrees_dir`, `:now`.
  """
  def confirm(%Dispatch{} = dispatch, by, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with true <- Authority.human?(by) || {:error, :non_human_identity},
         %External{state: "held"} = external <- get(dispatch.id) || :none,
         run_id = run_id(dispatch),
         {:ok, worktree} <- worktree(dispatch, run_id, opts),
         :ok <- write_brief(worktree.path, dispatch) do
      deadline = DateTime.add(now, dispatch.max_duration_seconds, :second)

      {count, _} =
        Repo.update_all(
          from(e in External, where: e.id == ^external.id and e.state == "held"),
          set: [
            state: "awaiting",
            confirmed_by: by,
            confirmed_at: now,
            deadline_at: deadline,
            run_id: run_id,
            worktree_path: worktree.path,
            branch: worktree.branch,
            base_commit: worktree.base_commit,
            source_before: source(dispatch.repository_root),
            updated_at: now
          ]
        )

      if count == 1 do
        event(dispatch, "dispatch.external.started", "human", %{
          "confirmed_by" => by,
          "worktree" => worktree.path,
          "base_commit" => worktree.base_commit,
          "deadline_at" => DateTime.to_iso8601(deadline)
        })

        :confirmed
      else
        :none
      end
    else
      :none -> :none
      %External{} -> :none
      {:error, _} = error -> error
    end
  end

  defp run_id(dispatch), do: Shoestring.Dispatches.uuid_for("external-run:#{dispatch.id}")

  # The worktree survives a retry: one already made for this dispatch is reused.
  defp worktree(dispatch, run_id, opts) do
    storage = Keyword.take(opts, [:worktrees_dir])

    case Worktrees.get(run_id, storage) do
      {:ok, worktree} ->
        {:ok, worktree}

      {:error, _} ->
        # One that follows another dispatch starts from the worktree holding
        # that one's verified commit; never the person's checkout's state.
        Worktrees.create(
          dispatch.plan["base_source"] || dispatch.repository_root,
          run_id,
          dispatch.base_revision,
          Keyword.put(storage, :private_git, true)
        )
    end
  end

  defp write_brief(path, dispatch) do
    target = Path.join(path, @brief_path)

    text =
      """
      # EXTERNAL: #{dispatch.title}

      Work in this directory only: #{path}
      Nothing outside it counts. Commit your result here (git add, git commit) and
      leave the directory clean; Shoestring's checks run on your last commit.
      Shoestring does not sandbox this work: it is done outside its guarantee.

      #{dispatch.brief}
      """

    with :ok <- File.mkdir_p(Path.dirname(target)), do: File.write(target, text)
  end

  # -- Completion ----------------------------------------------------------------

  @doc """
  A person completes an EXTERNAL (`human:` only): the worktree must be clean
  and hold a commit beyond the base, then every check runs under the gate
  sandbox. Passing settles it `completed` at that commit; anything else
  leaves it `needs_you` with the reason, to be completed again. A completion
  past the deadline is allowed and recorded as expired. `units` is the
  operator's reported actual use (`%{name => n}`), for units it reserved.

  Returns `{:ok, external}` (look at its state) or `{:error, reason}`.
  Options: `:gate_runner_opts` (tests), `:worktrees_dir`, `:now`.
  """
  def complete(%Dispatch{} = dispatch, by, units \\ %{}, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with true <- Authority.human?(by) || {:error, :non_human_identity},
         %External{} = external <- get(dispatch.id) || {:error, :not_external},
         :ok <- completable(external),
         :ok <- reported_units(external, units) do
      attempt = external.attempts + 1
      expired = expired?(external, now)
      outcome = verify(dispatch, external, attempt, opts)

      fields = [
        attempts: attempt,
        expired: expired,
        completed_by: by,
        source_after: source(dispatch.repository_root),
        updated_at: now
      ]

      case outcome do
        {:ok, commit, checks} ->
          actual = if(units == %{}, do: nil, else: units)

          external =
            update!(
              external,
              fields ++
                [
                  state: "completed",
                  commit: commit,
                  checks: checks,
                  failure: nil,
                  units_actual: actual,
                  finished_at: now
                ]
            )

          event(
            dispatch,
            "dispatch.external.completed",
            "human",
            %{
              "attempt" => attempt,
              "commit" => commit,
              "completed_by" => by,
              "expired" => expired
            }
            |> then(&if(actual, do: Map.put(&1, "units_actual", actual), else: &1))
          )

          {:ok, external}

        {:error, reason, checks} ->
          external =
            update!(
              external,
              fields ++ [state: "needs_you", failure: reason, checks: checks]
            )

          event(dispatch, "dispatch.external.completion_failed", "human", %{
            "attempt" => attempt,
            "reason" => reason,
            "completed_by" => by,
            "expired" => expired
          })

          {:ok, external}
      end
    end
  end

  defp completable(%External{state: state}) when state in ~w(awaiting needs_you), do: :ok
  defp completable(%External{state: "held"}), do: {:error, :not_started}
  defp completable(_external), do: {:error, :already_finished}

  defp reported_units(external, units) do
    if Enum.all?(units, fn {name, n} ->
         Map.has_key?(external.units_reserved || %{}, name) and is_integer(n) and n >= 0
       end),
       do: :ok,
       else: {:error, :unknown_unit}
  end

  defp verify(dispatch, external, attempt, opts) do
    path = external.worktree_path

    with {:ok, commit} <- head(path),
         :ok <- if(commit == external.base_commit, do: {:error, "no_commit"}, else: :ok),
         :ok <- clean(path),
         {:ok, checks} <- run_checks(dispatch, external, commit, attempt, opts) do
      {:ok, commit, checks}
    else
      {:error, reason, checks} -> {:error, reason, checks}
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp head(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> {:ok, String.trim(sha)}
      _ -> {:error, "worktree_unreadable"}
    end
  end

  # Untracked files count: what is not committed is not the result. The
  # brief lives in `.shoestring/`, which the run's private Git excludes.
  defp clean(path) do
    case System.cmd("git", ["-C", path, "status", "--porcelain", "--untracked-files=normal"],
           stderr_to_stdout: true
         ) do
      {"", 0} -> :ok
      {_, 0} -> {:error, "gate_worktree_dirty"}
      _ -> {:error, "worktree_unreadable"}
    end
  end

  defp run_checks(dispatch, external, commit, attempt, opts) do
    gates = dispatch.plan["gates"] || []

    context = %{
      goal_id: dispatch.goal_id,
      plan_task_id: "external",
      revision_number: 1,
      plan_digest: dispatch.plan_digest,
      run_id: external.run_id,
      attempt: attempt
    }

    gate_opts =
      opts
      |> Keyword.get(:gate_runner_opts, [])
      |> Keyword.merge(worktree_path: external.worktree_path, commit: commit)
      |> Keyword.put_new(:worktrees_dir, Keyword.get(opts, :worktrees_dir))

    Enum.reduce_while(gates, {:ok, []}, fn gate, {:ok, acc} ->
      case PlanGateRunner.run(gate, context, gate_opts) do
        {:ok, %{exit_status: 0} = evidence} ->
          {:cont, {:ok, acc ++ [check(evidence)]}}

        {:ok, evidence} ->
          {:halt, {:error, "check_failed:#{evidence.gate}", acc ++ [check(evidence)]}}

        {:error, reason} ->
          {:halt, {:error, "check_error:#{gate["gate"]}:#{short(reason)}", acc}}
      end
    end)
  end

  defp check(evidence) do
    %{
      "gate" => evidence.gate,
      "argv" => Enum.join(evidence.gate_argv, " "),
      "exit_status" => evidence.exit_status,
      "duration_ms" => evidence.duration_ms,
      "sandboxed" => not is_nil(evidence.sandbox),
      "last_line" =>
        evidence.output |> to_string() |> String.split("\n", trim: true) |> List.last()
    }
  end

  defp short(reason), do: reason |> inspect(limit: 5) |> String.slice(0, 200)

  # -- Abandonment ----------------------------------------------------------------

  @doc """
  A person abandons an EXTERNAL that has not completed (`human:` only). Its
  reserved units stay counted (the actual is unknown) and its worktree is
  kept. `{:ok, external}` or `{:error, reason}`.
  """
  def abandon(%Dispatch{} = dispatch, by, reason, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    reason = reason |> to_string() |> String.trim() |> String.slice(0, @max_reason)

    with true <- Authority.human?(by) || {:error, :non_human_identity},
         true <- reason != "" || {:error, :reason_required},
         %External{} = external <- get(dispatch.id) || {:error, :not_external},
         true <- external.state in ~w(held awaiting needs_you) || {:error, :already_finished} do
      external =
        update!(external,
          state: "abandoned",
          abandon_reason: reason,
          completed_by: by,
          finished_at: now,
          source_after: if(external.worktree_path, do: source(dispatch.repository_root)),
          updated_at: now
        )

      event(dispatch, "dispatch.external.abandoned", "human", %{"by" => by, "reason" => reason})
      {:ok, external}
    end
  end

  # -- The person's checkout ------------------------------------------------------

  @doc "The checkout's `HEAD` and a digest of its `git status` (evidence)."
  def source(root) when is_binary(root) do
    head =
      case System.cmd("git", ["-C", root, "rev-parse", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} -> String.trim(sha)
        _ -> nil
      end

    status =
      case System.cmd("git", ["-C", root, "status", "--porcelain=v1", "--untracked-files=all"],
             stderr_to_stdout: true
           ) do
        {text, 0} -> :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
        _ -> nil
      end

    %{"head" => head, "status_sha256" => status}
  end

  @doc "Whether the person's checkout changed between confirmation and the latest record."
  def source_changed?(%External{source_before: %{} = before, source_after: %{} = after_}),
    do: before != after_

  def source_changed?(_external), do: false

  @doc "The commands that take a completed EXTERNAL's commit into the person's repository."
  def take(%Dispatch{repository_root: root}, %External{state: "completed"} = external),
    do: [
      "cd #{Shoestring.Shell.argument(root)}",
      "git fetch #{Shoestring.Shell.argument(external.worktree_path)} #{Shoestring.Shell.argument(external.commit)}",
      "git merge FETCH_HEAD"
    ]

  def take(_dispatch, _external), do: []

  # -- Internals -----------------------------------------------------------------

  defp update!(external, fields),
    do: external |> Ecto.Changeset.change(fields) |> Repo.update!()

  defp event(%Dispatch{goal_id: goal_id} = dispatch, type, actor, payload)
       when is_binary(goal_id) do
    Trajectory.append(goal_id, %{
      "type" => type,
      "schema_version" => 1,
      "actor" => actor,
      "occurred_at" => DateTime.utc_now(),
      "payload" => Map.put(payload, "dispatch_id", dispatch.id)
    })
  rescue
    _ -> :ok
  end

  defp event(_dispatch, _type, _actor, _payload), do: :ok
end
