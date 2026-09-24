# Live production-path driver for the iteration-5 Go Tic-Tac-Toe acceptance rerun.
#
# Runs INSIDE a production-configured node and calls only product entry points:
#
#   * a task turn is submitted through the real `/runs/new` submit handler
#     (`ShoestringWeb.RunNewLive.handle_event("start_run", ...)`), i.e. manual
#     admission -> `task.claim` -> lease grant -> durable dispatch -> Elf;
#   * a claim is released with a durable `task.release` Cobbler command;
#   * a handoff is requested with `Shoestring.Cobbler.Handoffs.request/3`
#     (durable `run.handoff` intent + `handoff`-queue delivery). The live Oban
#     `handoff` queue delivers it to `HandoffWorker`, which uses the configured
#     `:handoff_observe` probe. This script never calls `Handoffs.perform/3`,
#     never injects an observation, and never appends events itself;
#   * cancellation is the operator's explicit `Shoestring.Elves.cancel_run/1`.
#
# Usage (one phase per node boot; the state dir persists between phases):
#
#     MIX_ENV=prod SHOESTRING_STATE_DIR=<disposable dir> SECRET_KEY_BASE=<random> \
#       LIVE_PHASE=<phase> mix run tools/live_eval/prod_rerun.exs < /dev/null
#
# Phases: `turn1`, `turn2`, `handoff`, `cancel`. The disposable Go repository
# must already exist at `<state dir>/repos/ttt` (under the manual-run allowed
# root). Results are appended as JSON lines to `<state dir>/live-results.jsonl`.
# Every wait is bounded; on overrun the phase reports the timeout and stops.

import Ecto.Query

alias Shoestring.Repo
alias Shoestring.Harness.{CheckpointRecord, Continuation, Projector, RunRecord}
alias Shoestring.Trajectory.TrajectoryEvent

defmodule LiveEval do
  def state_root, do: Shoestring.State.root()
  def repo_path, do: Path.join(state_root(), "repos/ttt")

  def record(phase, map) do
    line = Jason.encode!(Map.merge(%{"phase" => phase, "at" => DateTime.utc_now()}, map))
    File.write!(Path.join(state_root(), "live-results.jsonl"), line <> "\n", [:append])
    IO.puts("RESULT " <> line)
  end

  def say(label, term),
    do: IO.puts("#{label}: #{inspect(term, limit: :infinity, printable_limit: 4000)}")

  # The real `/runs/new` submit handler, invoked in-process with the form's
  # params. The websocket/HTML transport is not exercised; the handler's
  # admission -> claim -> lease -> dispatch -> Elf path is.
  def submit_turn(provider, prompt, base_revision, opts \\ []) do
    params = %{
      "repo_path" => repo_path(),
      "base_revision" => base_revision,
      "provider" => provider,
      "prompt" => prompt,
      "timeout_seconds" => Keyword.get(opts, :timeout_seconds, "900"),
      "max_events" => Keyword.get(opts, :max_events, "4000"),
      "lease_seconds" => Keyword.get(opts, :lease_seconds, "300"),
      "scenario" => "success"
    }

    socket = %Phoenix.LiveView.Socket{
      endpoint: ShoestringWeb.Endpoint,
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_scope: nil,
        claim_held: nil,
        form_errors: %{},
        form: Phoenix.Component.to_form(params, as: :run)
      }
    }

    {:noreply, socket} =
      ShoestringWeb.RunNewLive.handle_event("start_run", %{"run" => params}, socket)

    case socket.redirected do
      {:live, :redirect, %{to: "/runs/" <> run_id}} ->
        {:ok, run_id}

      other ->
        {:error,
         %{
           redirected: other,
           flash: socket.assigns.flash,
           claim_held: socket.assigns[:claim_held]
         }}
    end
  end

  def run!(run_id), do: Repo.get!(RunRecord, run_id)

  # The driver only READS projections; a projection attempt that raises
  # (e.g. a raw `Exqlite.Error` "Database busy") must not crash the node and
  # take a supervised Elf down with it. The error is reported, not hidden.
  def project(goal_id) do
    Projector.project(goal_id)
  rescue
    error ->
      IO.puts(("PROJECT-RAISED " <> Exception.message(error)) |> String.slice(0, 200))
      {:raised, Exception.message(error) |> String.slice(0, 200)}
  end

  def wait_stop(run_id, bound_s) do
    deadline = System.monotonic_time(:second) + bound_s
    do_wait(run_id, deadline)
  end

  # A stop is read from the COMMITTED trajectory (a terminal or a
  # `run.suspended` for this run) plus the Elf having exited, not from the run
  # row: the row is a projection, and a failed projector leaves it stale.
  defp do_wait(run_id, deadline) do
    run = Repo.get!(RunRecord, run_id)
    _ = LiveEval.project(run.goal_id)
    stopped? = terminal_event(run.goal_id, run_id) != nil or suspended?(run.goal_id, run_id)
    elf_alive? = Shoestring.Elves.whereis(run_id) != nil

    cond do
      stopped? and not elf_alive? -> {:ok, Repo.get!(RunRecord, run_id)}
      System.monotonic_time(:second) > deadline -> {:timeout, Repo.get!(RunRecord, run_id)}
      true -> Process.sleep(2_000) && do_wait(run_id, deadline)
    end
  end

  def suspended?(goal_id, run_id) do
    Repo.exists?(
      from e in TrajectoryEvent,
        where:
          e.goal_id == ^goal_id and e.type == "run.suspended" and
            fragment("json_extract(?, '$.run_id')", e.payload) == ^run_id
    )
  end

  def projector_position(goal_id) do
    case Repo.get_by(Shoestring.Trajectory.ProjectorPosition,
           goal_id: goal_id,
           projector: "harness"
         ) do
      nil -> nil
      p -> %{"last_sequence" => p.last_sequence, "status" => p.status}
    end
  end

  def projector_error(goal_id) do
    case Repo.get_by(Shoestring.Trajectory.ProjectorPosition,
           goal_id: goal_id,
           projector: "harness"
         ) do
      %{error_detail: detail} when is_binary(detail) ->
        detail |> Base.decode64!() |> :erlang.binary_to_term() |> inspect()

      _ ->
        nil
    end
  end

  def event_types(goal_id) do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id,
        order_by: e.sequence,
        select: e.type
    )
  end

  def normalized_count(run_id) do
    Repo.one(
      from e in TrajectoryEvent,
        where:
          e.type == "harness.event_recorded" and
            fragment("json_extract(?, '$.run_id')", e.payload) == ^run_id,
        select: count(e.id)
    )
  end

  def terminal_event(goal_id, run_id) do
    Repo.one(
      from e in TrajectoryEvent,
        where:
          e.goal_id == ^goal_id and
            e.type in ["run.completed", "run.failed", "run.cancelled", "run.interrupted"] and
            fragment("json_extract(?, '$.run_id')", e.payload) == ^run_id,
        select: %{type: e.type, payload: e.payload}
    )
  end

  def worktree_head(run) do
    path = worktree_path(run)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: path)
    %{"head" => String.trim(sha), "dirty" => status != "", "path" => path}
  end

  # `Shoestring.Worktrees.create/3`'s default location for a run.
  def worktree_path(run), do: Path.join(Shoestring.State.path(:worktrees), "run-" <> run.id)

  # The owned process group, as the Elf recorded it on `run.running`.
  def running_process_id(goal_id, run_id) do
    Repo.one(
      from e in TrajectoryEvent,
        where:
          e.goal_id == ^goal_id and e.type == "run.running" and
            fragment("json_extract(?, '$.run_id')", e.payload) == ^run_id,
        select: fragment("json_extract(?, '$.process_id')", e.payload)
    )
  end

  def release_claim(goal_id, label) do
    Shoestring.Cobbler.submit_command(goal_id, %{
      "type" => "task.release",
      "command_id" => "live-release-#{label}",
      "payload" => %{"reason" => "operator release after #{label}"}
    })
  end

  def latest_results do
    Path.join(state_root(), "live-results.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  def result_for(phase), do: Enum.find(Enum.reverse(latest_results()), &(&1["phase"] == phase))
end

# Harness-side log configuration only: show warning metadata (reason codes)
# that the default production formatter omits.
:logger.update_formatter_config(:default, %{metadata: :all})

phase = System.fetch_env!("LIVE_PHASE")
LiveEval.say("phase", phase)
LiveEval.say("environment", Application.get_env(:shoestring, :environment))
LiveEval.say("handoff_observe", Application.get_env(:shoestring, :handoff_observe))
LiveEval.say("dispatch_effect", Application.get_env(:shoestring, :dispatch_effect))

turn1_prompt = """
You are working in the Go module `example.com/tictactoe` (see go.mod). Implement ONLY a package `game` in the directory `game/`: a 3x3 Tic-Tac-Toe board for players X and O, X moving first. Required API: `type Player rune` with constants `X` and `O`; `func New() *Game`; `func (g *Game) Move(row, col int) error` (0-based row and column; returns an error for out-of-range coordinates, an occupied cell, or any move after the game is over; players alternate); `func (g *Game) Turn() Player`; `func (g *Game) Winner() (Player, bool)`; `func (g *Game) Full() bool`; `func (g *Game) Render() string` (three lines, cells shown as `X`, `O` or `.`, separated by single spaces). Add table-driven tests in `game/game_test.go` covering every row, every column, both diagonals, a draw, and each error case. Constraints: standard library only, no third-party modules; do NOT create main.go or any command-line program in this turn. Run `gofmt -l .` (it must print nothing) and `go test ./...` (it must pass), then commit all changes on the current branch with a descriptive message, and stop.
"""

turn2_prompt = """
This Go module `example.com/tictactoe` already contains a finished, tested package `game` in `game/`. Read it first; do not change its API and do not reimplement its rules. Start the command-line program in `main.go` (package main at the module root). In THIS turn implement only input parsing: `func parseMove(line string) (row, col int, err error)`, accepting exactly two 1-based integers from 1 to 3 separated by whitespace (for example `2 3` is row 2, column 3, returned 0-based as 1, 2) and rejecting anything else, plus a table-driven `main_test.go` for it. Leave `func main()` as a minimal placeholder; the interactive game loop is intentionally left for a later turn. Constraints: standard library only; do not modify package `game`. Run `gofmt -l .` (it must print nothing) and `go test ./...` (it must pass), commit all changes on the current branch, and stop.
"""

cancel_prompt = """
In this Go module, write a thorough design note `DESIGN.md` for a Tic-Tac-Toe engine with minimax search, then implement the engine in a new package `engine/` with exhaustive tests. Work carefully and verify each step with `go test ./...`.
"""

# Harness-side settle: let boot-time writers (reconcilers, the first monitor
# ingest) finish before submitting. Disclosed in the evidence; it changes no
# product behaviour.
Process.sleep(String.to_integer(System.get_env("LIVE_SETTLE_S", "10")) * 1000)

case phase do
  "release" ->
    goal_id = System.fetch_env!("LIVE_RELEASE_GOAL")
    label = System.fetch_env!("LIVE_RELEASE_LABEL")
    {:ok, released} = LiveEval.release_claim(goal_id, label)

    LiveEval.record("release", %{
      "goal_id" => goal_id,
      "label" => label,
      "result" => released.command.result
    })

  "turn1" ->
    run_id =
      case System.get_env("LIVE_RECORD_RUN") do
        nil -> elem({:ok, _} = LiveEval.submit_turn("codex", turn1_prompt, "HEAD"), 1)
        existing -> existing
      end

    LiveEval.say("turn1_run", run_id)
    {status, run} = LiveEval.wait_stop(run_id, 520)

    LiveEval.record("turn1", %{
      "wait" => status,
      "run_id" => run.id,
      "goal_id" => run.goal_id,
      "status" => run.status,
      "provider_id" => run.provider_id,
      "terminal" => LiveEval.terminal_event(run.goal_id, run.id),
      "normalized_events" => LiveEval.normalized_count(run.id),
      "run_row_status" => run.status,
      "projector" => LiveEval.projector_position(run.goal_id),
      "projector_error" => LiveEval.projector_error(run.goal_id),
      "worktree" => LiveEval.worktree_head(run),
      "event_types" => LiveEval.event_types(run.goal_id)
    })

    LiveEval.say("release", LiveEval.release_claim(run.goal_id, "turn1") |> elem(0))

  "turn2" ->
    base = LiveEval.result_for("turn1")["worktree"]["head"]

    run_id =
      case System.get_env("LIVE_RECORD_RUN") do
        nil -> elem({:ok, _} = LiveEval.submit_turn("codex", turn2_prompt, base), 1)
        existing -> existing
      end

    LiveEval.say("turn2_run", run_id)
    {status, run} = LiveEval.wait_stop(run_id, 520)

    LiveEval.record("turn2", %{
      "wait" => status,
      "base_revision" => base,
      "run_id" => run.id,
      "goal_id" => run.goal_id,
      "status" => run.status,
      "provider_id" => run.provider_id,
      "terminal" => LiveEval.terminal_event(run.goal_id, run.id),
      "normalized_events" => LiveEval.normalized_count(run.id),
      "run_row_status" => run.status,
      "projector" => LiveEval.projector_position(run.goal_id),
      "projector_error" => LiveEval.projector_error(run.goal_id),
      "worktree" => LiveEval.worktree_head(run),
      "event_types" => LiveEval.event_types(run.goal_id)
    })

  "handoff" ->
    # The sender is the latest recorded turn named by LIVE_SENDER_PHASE
    # (default `turn2`) — the most recent Codex turn that actually ran.
    sender = LiveEval.result_for(System.get_env("LIVE_SENDER_PHASE", "turn2"))
    run = LiveEval.run!(sender["run_id"])
    _ = LiveEval.project(run.goal_id)

    # The canonical checkpoint is the sender Elf's own terminal checkpoint.
    # Its id is read from the committed `checkpoint.created` event, because a
    # failed projector means it may never have been projected into a row.
    checkpoint_id =
      Repo.one!(
        from e in TrajectoryEvent,
          where:
            e.goal_id == ^run.goal_id and e.type == "checkpoint.created" and
              fragment("json_extract(?, '$.run_id')", e.payload) == ^run.id,
          order_by: [desc: e.sequence],
          limit: 1,
          select: fragment("json_extract(?, '$.checkpoint_id')", e.payload)
      )

    checkpoint_row = Repo.get(CheckpointRecord, checkpoint_id)
    LiveEval.say("checkpoint_projected?", checkpoint_row != nil)

    refs = Continuation.decision_refs(Repo, run.goal_id)

    # The merged default policy: no `lease_policy` on the intent, so
    # `HandoffLeasePolicy.from_intent/1` supplies the durable default.
    policy = Shoestring.Cobbler.HandoffLeasePolicy.default()
    LiveEval.say("handoff_default_lease_policy", policy)

    request =
      Shoestring.Cobbler.Handoffs.request(run.goal_id, %{
        "command_id" => "live-handoff-#{run.id}",
        "payload" => %{
          "run_id" => run.id,
          "checkpoint_id" => checkpoint_id,
          "decision_refs" => refs,
          "to_provider_id" => "claude",
          "to_adapter_id" => "claude_headless_stream_json",
          "scope" => "subscription",
          "reason" => "continue the Go Tic-Tac-Toe CLI on the other provider",
          "requested_by" => "operator",
          "confirmation" => %{"intent" => "supervised_execution"}
        }
      })

    {command_status, command_result, job_inserted?} =
      case request do
        {:ok, req} -> {req.command.status, req.command.result, req.job != nil}
        {:error, reason} -> {"error", %{"error" => inspect(reason)}, false}
      end

    LiveEval.say("handoff_command", %{
      status: command_status,
      result: command_result,
      job?: job_inserted?
    })

    # Let the live `handoff` queue deliver, with a bounded wait for every
    # attempt Oban's backoff schedules (max_attempts 5).
    deadline =
      System.monotonic_time(:second) +
        if(job_inserted?,
          do: String.to_integer(System.get_env("LIVE_HANDOFF_WAIT", "480")),
          else: 0
        )

    wait = fn wait ->
      job =
        Repo.one(
          from j in Oban.Job, where: j.queue == "handoff", order_by: [desc: j.id], limit: 1
        )

      handoffs =
        Repo.aggregate(
          from(e in TrajectoryEvent,
            where: e.goal_id == ^run.goal_id and e.type == "handoff.created"
          ),
          :count
        )

      cond do
        handoffs > 0 -> {:handoff_created, job}
        not job_inserted? -> {:no_delivery_attempt, job}
        job && job.state in ["discarded", "cancelled", "completed"] -> {:settled, job}
        System.monotonic_time(:second) > deadline -> {:timeout, job}
        true -> Process.sleep(5_000) && wait.(wait)
      end
    end

    {outcome, job} = wait.(wait)

    runs_in_goal =
      Repo.all(
        from r in RunRecord,
          where: r.goal_id == ^run.goal_id,
          select: %{id: r.id, provider_id: r.provider_id, status: r.status}
      )

    LiveEval.record("handoff", %{
      "outcome" => outcome,
      "goal_id" => run.goal_id,
      "sender_run_id" => run.id,
      "checkpoint_id" => checkpoint_id,
      "checkpoint_projected" => checkpoint_row != nil,
      "decision_refs" => refs,
      "lease_policy_default" => Map.from_struct(policy),
      "command_status" => command_status,
      "command_result" => command_result,
      "job" =>
        job &&
          %{
            "state" => job.state,
            "attempt" => job.attempt,
            "max_attempts" => job.max_attempts,
            "errors" => Enum.map(job.errors, & &1["error"])
          },
      "runs_in_goal" => runs_in_goal,
      "ledger" =>
        Enum.map(
          Shoestring.Harness.Observatory.latest_observations(),
          &%{
            "provider" => &1.source.provider_id,
            "scope" => &1.scope,
            "state" => &1.capacity_state,
            "tier" => &1.support_tier
          }
        ),
      "projector" => LiveEval.projector_position(run.goal_id),
      "projector_error" => LiveEval.projector_error(run.goal_id),
      "event_types" => LiveEval.event_types(run.goal_id)
    })

  "cancel_stranded" ->
    # Explicit cancellation of a run whose Elf no longer exists (its node was
    # stopped mid-launch). Waits for the live `dispatch` queue to settle the
    # pending delivery first, so the observed outcome is the product's own.
    run_id = System.fetch_env!("LIVE_CANCEL_RUN")
    run = LiveEval.run!(run_id)
    Process.sleep(15_000)
    dispatch = Repo.get_by(Shoestring.Harness.DispatchRecord, run_id: run_id)
    elf_before = Shoestring.Elves.whereis(run_id) != nil
    first = Shoestring.Elves.cancel_run(run_id)
    second = Shoestring.Elves.cancel_run(run_id)
    _ = LiveEval.project(run.goal_id)

    LiveEval.record("cancel_stranded", %{
      "run_id" => run_id,
      "goal_id" => run.goal_id,
      "dispatch_status_before_cancel" => dispatch && dispatch.status,
      "dispatch_outcome_code" => dispatch && dispatch.outcome_code,
      "elf_registered_before" => elf_before,
      "first_cancel" => inspect(first),
      "second_cancel" => inspect(second),
      "terminal" => LiveEval.terminal_event(run.goal_id, run_id),
      "run_row_status" => LiveEval.run!(run_id).status,
      "projector" => LiveEval.projector_position(run.goal_id),
      "projector_error" => LiveEval.projector_error(run.goal_id),
      "event_types" => LiveEval.event_types(run.goal_id)
    })

    LiveEval.say(
      "release_stranded",
      LiveEval.release_claim(run.goal_id, "cancel-stranded") |> elem(0)
    )

  "cancel" ->
    t2 = LiveEval.result_for("turn2")
    {:ok, run_id} = LiveEval.submit_turn("codex", cancel_prompt, t2["worktree"]["head"])
    LiveEval.say("cancel_run_submitted", run_id)

    # Cancel only once the owned process group is observed alive and the run
    # has produced durable normalized progress. No timer decides anything: the
    # trigger is the explicit operator call below.
    deadline = System.monotonic_time(:second) + 300

    ready = fn ready ->
      run = LiveEval.run!(run_id)
      _ = LiveEval.project(run.goal_id)
      pgid = LiveEval.running_process_id(run.goal_id, run_id)
      n = LiveEval.normalized_count(run_id)

      cond do
        is_binary(pgid) and n >= 5 -> {:ok, pgid, n}
        System.monotonic_time(:second) > deadline -> {:timeout, pgid, n}
        true -> Process.sleep(1_000) && ready.(ready)
      end
    end

    {ready?, process_id, n_before} = ready.(ready)
    pgid = process_id && String.replace_prefix(process_id, "pgid:", "")

    group_alive = fn ->
      pgid && match?({_, 0}, System.cmd("kill", ["-0", "-" <> pgid], stderr_to_stdout: true))
    end

    alive_before = group_alive.()
    {us, first} = :timer.tc(fn -> Shoestring.Elves.cancel_run(run_id) end)
    {status, run} = LiveEval.wait_stop(run_id, 120)
    second = Shoestring.Elves.cancel_run(run_id)
    _ = LiveEval.project(run.goal_id)
    run = LiveEval.run!(run_id)

    cancelled_events =
      Repo.aggregate(
        from(e in TrajectoryEvent,
          where: e.goal_id == ^run.goal_id and e.type == "run.cancelled"
        ),
        :count
      )

    LiveEval.record("cancel", %{
      "ready" => ready?,
      "run_id" => run_id,
      "goal_id" => run.goal_id,
      "normalized_before_cancel" => n_before,
      "group_alive_before" => alive_before,
      "first_cancel" => inspect(first),
      "first_cancel_ms" => div(us, 1000),
      "wait" => status,
      "second_cancel" => inspect(second),
      "group_alive_after" => group_alive.(),
      "elf_registered_after" => Shoestring.Elves.whereis(run_id) != nil,
      "run_status" => run.status,
      "terminal" => LiveEval.terminal_event(run.goal_id, run_id),
      "run_cancelled_events" => cancelled_events,
      "event_types" => LiveEval.event_types(run.goal_id)
    })

    LiveEval.say("release_cancel", LiveEval.release_claim(run.goal_id, "cancel") |> elem(0))
end
