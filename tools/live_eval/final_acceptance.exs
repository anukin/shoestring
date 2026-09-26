# Live production-path driver for the final iteration-4/5 acceptance run
# (one disposable Go Tic-Tac-Toe task).
#
# Runs INSIDE a production-configured node and calls only product entry points,
# exactly as `prod_rerun.exs` (#83) did:
#
#   * turns and the two context-ablated arms: the real `/runs/new` submit
#     handler (`ShoestringWeb.RunNewLive.handle_event("start_run", ...)`):
#     manual admission -> `task.claim` -> lease grant -> durable dispatch -> Elf;
#   * claim release: a durable `task.release` Cobbler command;
#   * the handoff (arm trajectory_projection): `Shoestring.Cobbler.Handoffs.request/3`;
#     the live `handoff` queue delivers it to `HandoffWorker` (configured
#     `:handoff_observe` probe), the live `dispatch` queue starts the receiver;
#   * cancellation: the operator's explicit `Shoestring.Elves.cancel_run/1`.
#
# It never calls `Handoffs.perform/3`, never injects an observation or a
# capacity reading, never appends events and never calls the projector.
#
# Usage (one phase per node boot; the state dir persists between phases):
#
#     MIX_ENV=prod SHOESTRING_STATE_DIR=<disposable dir> SECRET_KEY_BASE=<random> \
#       LIVE_PHASE=<phase> mix run tools/live_eval/final_acceptance.exs < /dev/null
#
# Phases: `selftest` (measure functions on synthetic input; no provider),
# `setup`, `turn1`, `turn2`, `handoff`, `arm` (LIVE_ARM=worktree_only |
# naive_summary), `lease_stop`, `cancel`, `audit` (no provider; includes the
# handoff replay). Results are appended as JSON lines to
# `<state dir>/live-results.jsonl`. Every wait is bounded; on overrun the phase
# records the timeout and stops. Nothing here stops a run on staleness: the only
# stops this script causes are the explicit `cancel_run/1` calls, each recorded.
#
# The fixture, prompts, arm inputs and every measure below were fixed and
# committed BEFORE the first live call. See
# `plans/evidence/05-quota-aware-mvp/final-acceptance.md` §2.

import Ecto.Query

alias Shoestring.Repo
alias Shoestring.Harness.{CheckpointRecord, Continuation, RunRecord}
alias Shoestring.Trajectory.TrajectoryEvent

defmodule FinalEval do
  @terminals ["run.completed", "run.failed", "run.cancelled", "run.interrupted"]

  def terminals, do: @terminals
  def state_root, do: Shoestring.State.root()
  def repo_path, do: Path.join(state_root(), "repos/ttt")

  def record(phase, map) do
    line = Jason.encode!(Map.merge(%{"phase" => phase, "at" => DateTime.utc_now()}, map))
    File.write!(Path.join(state_root(), "live-results.jsonl"), line <> "\n", [:append])
    IO.puts("RESULT " <> line)
  end

  def say(label, term),
    do: IO.puts("#{label}: #{inspect(term, limit: :infinity, printable_limit: 4000)}")

  def latest_results do
    path = Path.join(state_root(), "live-results.jsonl")

    if File.exists?(path) do
      path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end

  def result_for(phase), do: Enum.find(Enum.reverse(latest_results()), &(&1["phase"] == phase))

  # ---------------------------------------------------------------------------
  # Product entry points
  # ---------------------------------------------------------------------------

  # The real `/runs/new` submit handler, invoked in-process with the form's
  # params (the websocket/HTML transport is not exercised).
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

  def release_claim(goal_id, label) do
    Shoestring.Cobbler.submit_command(goal_id, %{
      "type" => "task.release",
      "command_id" => "live-release-#{label}",
      "payload" => %{"reason" => "operator release after #{label}"}
    })
  end

  # ---------------------------------------------------------------------------
  # Reads (committed trajectory + worktree; never projections as truth)
  # ---------------------------------------------------------------------------

  def run!(run_id), do: Repo.get!(RunRecord, run_id)

  def run_events(goal_id, run_id, types) do
    Repo.all(
      from e in TrajectoryEvent,
        where:
          e.goal_id == ^goal_id and e.type in ^types and
            fragment("json_extract(?, '$.run_id')", e.payload) == ^run_id,
        order_by: e.sequence,
        select: %{type: e.type, sequence: e.sequence, at: e.occurred_at, payload: e.payload}
    )
  end

  def terminal_event(goal_id, run_id) do
    case run_events(goal_id, run_id, @terminals) do
      [] -> nil
      [first | _] -> %{type: first.type, payload: first.payload}
    end
  end

  def suspended?(goal_id, run_id), do: run_events(goal_id, run_id, ["run.suspended"]) != []

  def wait_stop(run_id, bound_s) do
    deadline = System.monotonic_time(:second) + bound_s
    do_wait(run_id, deadline)
  end

  # A stop is read from the COMMITTED trajectory (a terminal or a
  # `run.suspended` for this run) plus the Elf having exited.
  defp do_wait(run_id, deadline) do
    run = Repo.get!(RunRecord, run_id)
    stopped? = terminal_event(run.goal_id, run_id) != nil or suspended?(run.goal_id, run_id)
    elf_alive? = Shoestring.Elves.whereis(run_id) != nil

    cond do
      stopped? and not elf_alive? -> {:ok, run}
      System.monotonic_time(:second) > deadline -> {:timeout, run}
      true -> Process.sleep(2_000) && do_wait(run_id, deadline)
    end
  end

  def wait_run_created(goal_id, run_id, bound_s) do
    deadline = System.monotonic_time(:second) + bound_s

    Stream.repeatedly(fn -> Repo.get(RunRecord, run_id) end)
    |> Enum.reduce_while(nil, fn run, _acc ->
      cond do
        run != nil and run.goal_id == goal_id -> {:halt, {:ok, run}}
        System.monotonic_time(:second) > deadline -> {:halt, {:timeout, nil}}
        true -> Process.sleep(2_000) && {:cont, nil}
      end
    end)
  end

  def event_types(goal_id) do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id,
        order_by: e.sequence,
        select: e.type
    )
  end

  def normalized(goal_id, run_id) do
    Repo.all(
      from e in TrajectoryEvent,
        where:
          e.goal_id == ^goal_id and e.run_id == ^run_id and e.type == "harness.event_recorded",
        order_by: e.sequence,
        select: e.payload
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

  def projector_position(goal_id) do
    case Repo.get_by(Shoestring.Trajectory.ProjectorPosition,
           goal_id: goal_id,
           projector: "harness"
         ) do
      nil -> nil
      p -> %{"last_sequence" => p.last_sequence, "status" => p.status}
    end
  end

  def running_process_id(goal_id, run_id) do
    case run_events(goal_id, run_id, ["run.running"]) do
      [%{payload: p} | _] -> p["process_id"]
      [] -> nil
    end
  end

  def worktree_path(run), do: Path.join(Shoestring.State.path(:worktrees), "run-" <> run.id)

  def worktree_head(run) do
    path = worktree_path(run)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)

    {status, 0} =
      System.cmd("git", ["status", "--porcelain"], cd: path, env: [{"GIT_OPTIONAL_LOCKS", "0"}])

    %{"head" => String.trim(sha), "dirty" => status != "", "status" => status}
  end

  def lease_row(run_id) do
    case Repo.get_by(Shoestring.Harness.ExecutionLeaseRecord, run_id: run_id) do
      nil ->
        nil

      lease ->
        lease
        |> Map.take([
          :status,
          :response_budget,
          :tool_budget,
          :checkpoint_cadence,
          :response_reserve,
          :tool_reserve,
          :deadline
        ])
    end
  end

  # Bounded command: argument array, stdin closed, killed on overrun.
  def run_bounded(exe, args, dir, seconds) do
    System.cmd("timeout", [Integer.to_string(seconds), exe | args],
      cd: dir,
      stderr_to_stdout: true
    )
  end

  # ---------------------------------------------------------------------------
  # Predefined measures (fixed before execution; each arm measured by exactly
  # this code). See final-acceptance.md §2.3 for the definitions.
  # ---------------------------------------------------------------------------

  def cli_games do
    [
      {"x_row", ["1 1", "2 1", "1 2", "2 2", "1 3"], "X wins"},
      {"o_row", ["1 1", "2 1", "1 2", "2 2", "3 3", "2 3"], "O wins"},
      {"x_diagonal", ["1 1", "1 2", "2 2", "1 3", "3 3"], "X wins"},
      {"draw", ["1 1", "1 2", "1 3", "2 2", "2 1", "2 3", "3 2", "3 1", "3 3"], "Draw"},
      {"invalid_then_x", ["foo", "4 1", "1 1", "1 1", "2 1", "1 2", "2 2", "1 3"], "X wins"}
    ]
  end

  @board_row ~r/^[XO.] [XO.] [XO.]$/

  # M2 (constraint C1): every output line is a board row, a line beginning
  # `invalid`, or — only as the last line — the expected final result. Blank
  # lines, prompts and banners are violations. Output is stdout and stderr
  # combined, as the games are run.
  def c1_violations(output, expected) do
    lines = output |> String.split("\n") |> drop_final_empty()
    last_index = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.reject(fn {line, index} ->
      Regex.match?(@board_row, line) or String.starts_with?(line, "invalid") or
        (index == last_index and line == expected)
    end)
    |> Enum.map(fn {line, _index} -> line end)
  end

  defp drop_final_empty(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  def go_verify(dir, turn1_head, turn2_head) do
    cmd = fn args -> run_bounded(Enum.at(args, 0), tl(args), dir, 300) end
    {gofmt_out, gofmt_code} = cmd.(["gofmt", "-l", "."])
    {vet_out, vet_code} = cmd.(["go", "vet", "./..."])
    {test_out, test_code} = cmd.(["go", "test", "-count=1", "./..."])
    {list_out, _} = cmd.(["go", "list", "./..."])
    {status_out, _} = cmd.(["git", "status", "--porcelain"])
    {head, _} = cmd.(["git", "rev-parse", "HEAD"])
    {log_out, _} = cmd.(["git", "log", "--oneline", "-n", "12"])
    {game_diff, _} = cmd.(["git", "diff", "--stat", turn1_head, "--", "game/"])
    {rework, _} = cmd.(["git", "diff", "--numstat", turn2_head, "--", "game/", "main_test.go"])
    {legacy_status, _} = cmd.(["git", "diff", "--name-status", turn2_head, "--", "legacy/"])

    main_src = read_or_empty(Path.join(dir, "main.go"))
    legacy_file = Path.join(dir, "legacy/scoreboard/scoreboard.go")

    legacy_sources =
      Path.wildcard(Path.join(dir, "legacy/**/*.go")) |> Enum.map_join("\n", &File.read!/1)

    bin = Path.join(System.tmp_dir!(), "ttt-final-#{System.unique_integer([:positive])}")
    {build_out, build_code} = cmd.(["go", "build", "-o", bin, "."])

    games =
      if build_code == 0 do
        Enum.map(cli_games(), fn {name, moves, expected} ->
          input = Enum.join(moves, "\n") <> "\n"

          {out, code} =
            run_bounded("sh", ["-c", "printf '%s' \"$1\" | \"$2\"", "sh", input, bin], dir, 10)

          lines =
            out |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

          last = List.last(lines)
          invalid_lines = Enum.count(lines, &String.starts_with?(&1, "invalid"))
          violations = c1_violations(out, expected)

          %{
            "game" => name,
            "exit" => code,
            "last_line" => last,
            "expected" => expected,
            "invalid_lines" => invalid_lines,
            "pass" =>
              code == 0 and last == expected and (name != "invalid_then_x" or invalid_lines >= 3),
            "c1_violations" => Enum.take(violations, 5),
            "c1_violation_count" => length(violations),
            "output" => String.slice(out, 0, 1200)
          }
        end)
      else
        []
      end

    File.rm(bin)

    rework_deleted =
      rework
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> String.split("\t") |> Enum.at(1) end)
      |> Enum.map(fn n -> if n in [nil, "-"], do: 0, else: String.to_integer(n) end)
      |> Enum.sum()

    %{
      "head" => String.trim(head),
      "dirty" => String.trim(status_out) != "",
      "log" => String.split(String.trim(log_out), "\n"),
      # M1 acceptance
      "gofmt_clean" => gofmt_code == 0 and String.trim(gofmt_out) == "",
      "vet_pass" => vet_code == 0,
      "vet_output" => String.slice(vet_out, 0, 2000),
      "test_pass" => test_code == 0,
      "test_output" => String.slice(test_out, 0, 3000),
      "build_pass" => build_code == 0,
      "build_output" => String.slice(build_out, 0, 1500),
      "game_package_changed" => String.trim(game_diff) != "",
      "main_imports_game" => String.contains?(main_src, "\"example.com/tictactoe/game\""),
      "cli_games" => games,
      "cli_all_pass" => games != [] and Enum.all?(games, & &1["pass"]),
      "acceptance" =>
        gofmt_code == 0 and String.trim(gofmt_out) == "" and vet_code == 0 and test_code == 0 and
          build_code == 0 and games != [] and Enum.all?(games, & &1["pass"]) and
          String.trim(game_diff) == "" and
          String.contains?(main_src, "\"example.com/tictactoe/game\""),
      # M2 constraint C1
      "c1_preserved" => games != [] and Enum.all?(games, &(&1["c1_violation_count"] == 0)),
      "c1_violation_total" => Enum.sum(Enum.map(games, & &1["c1_violation_count"])),
      # M3 rejected approach R1
      "r1_legacy_file_present" => File.exists?(legacy_file),
      "r1_no_build_constraint" => not Regex.match?(~r{^//\s*(go:build|\+build)}m, legacy_sources),
      "r1_listed" => String.contains?(list_out, "example.com/tictactoe/legacy/scoreboard"),
      "r1_legacy_name_status" => String.trim(legacy_status),
      "r1_honored" =>
        File.exists?(legacy_file) and
          not Regex.match?(~r{^//\s*(go:build|\+build)}m, legacy_sources) and
          String.contains?(list_out, "example.com/tictactoe/legacy/scoreboard") and vet_code == 0,
      # M4 rework of completed work
      "rework_deleted_lines" => rework_deleted,
      "parse_move_defined" => String.contains?(main_src, "func parseMove(")
    }
  end

  defp read_or_empty(path), do: if(File.exists?(path), do: File.read!(path), else: "")

  # M6 first mutation: a file-mutating tool start (Write, Edit, MultiEdit,
  # NotebookEdit), or a Bash start whose command matches @mutation.
  @mutation ~r/(\b(cat|tee|printf|echo)\b[^|;&]*>{1,2}\s*(?!\/dev\/null)[^&\s])|(\b(sed|perl)\s+-i)|(\bgofmt\s+-w)|(\bgo\s+(fix|mod\s+tidy))|(\b(mv|cp|rm)\s)|(\bgit\s+(apply|checkout\s+--|restore))|(\bpython3?\b.*open\()/
  @writes ~w(Write Edit MultiEdit NotebookEdit)
  @verify ~r/\bgo\s+(test|vet|build)\b|\bgofmt\s+-l\b/
  @game_read ~r/\b(cat|head|tail|sed\s+-n|less|nl|bat)\b[^|;&]*\bgame\//

  def mutation?(tool, command) do
    tool in @writes or
      (tool == "Bash" and is_binary(command) and Regex.match?(@mutation, command))
  end

  # Handoff tax for one Claude receiver run, from its committed normalized
  # events only.
  def tax(goal_id, run_id) do
    events = normalized(goal_id, run_id)
    starting = run_events(goal_id, run_id, ["run.starting"]) |> List.first()
    terminal = run_events(goal_id, run_id, @terminals) |> List.first()

    tool = fn p -> get_in(p, ["extensions", "claude-headless:tool_name"]) end
    command = fn p -> get_in(p, ["extensions", "claude-headless:command"]) end

    start? = fn p ->
      get_in(p, ["extensions", "claude-headless:boundary"]) == "start" and tool.(p) != nil
    end

    starts = Enum.filter(events, start?)

    first_index =
      Enum.find_index(events, fn p -> start?.(p) and mutation?(tool.(p), command.(p)) end)

    before = if first_index, do: Enum.take(events, first_index), else: events
    before_starts = Enum.filter(before, start?)

    first_at =
      if first_index do
        {:ok, at, _} = DateTime.from_iso8601(Enum.at(events, first_index)["occurred_at"])
        at
      end

    result =
      Enum.find(events, &(get_in(&1, ["extensions", "claude-headless:frame_type"]) == "result"))

    utilization =
      events
      |> Enum.map(&get_in(&1, ["extensions", "claude-headless:five_hour_utilization"]))
      |> Enum.reject(&is_nil/1)

    %{
      "normalized_events" => length(events),
      "tool_starts" => length(starts),
      "tool_starts_by_name" => Enum.frequencies_by(starts, tool),
      "first_mutation_found" => first_index != nil,
      "first_mutation_command" =>
        first_index && String.slice(command.(Enum.at(events, first_index)) || "", 0, 300),
      "before_first_mutation_events" => length(before),
      "before_first_mutation_tool_starts" => length(before_starts),
      "before_first_mutation_verify_commands" =>
        Enum.count(
          before_starts,
          &(tool.(&1) == "Bash" and Regex.match?(@verify, command.(&1) || ""))
        ),
      "before_first_mutation_game_reads" =>
        Enum.count(
          before_starts,
          &(tool.(&1) == "Bash" and Regex.match?(@game_read, command.(&1) || ""))
        ),
      "ms_to_first_mutation" =>
        starting && first_at && DateTime.diff(first_at, starting.at, :millisecond),
      "ms_run" => starting && terminal && DateTime.diff(terminal.at, starting.at, :millisecond),
      "verify_commands_total" =>
        Enum.count(starts, &(tool.(&1) == "Bash" and Regex.match?(@verify, command.(&1) || ""))),
      "mix_commands" =>
        Enum.count(
          starts,
          &(tool.(&1) == "Bash" and String.contains?(command.(&1) || "", "mix "))
        ),
      "cli_num_turns" => result && get_in(result, ["extensions", "claude-headless:num_turns"]),
      "cli_total_cost_usd" =>
        result && get_in(result, ["extensions", "claude-headless:total_cost_usd"]),
      "five_hour_utilization_first" => List.first(utilization),
      "five_hour_utilization_last" => List.last(utilization),
      "terminal" => terminal && terminal.type,
      "receiver_models" =>
        events
        |> Enum.map(&get_in(&1, ["extensions", "claude-headless:model"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq(),
      "bash_commands" => starts |> Enum.map(&String.slice(command.(&1) || "", 0, 200))
    }
  end

  # The owned process group as `ps` sees it right now.
  def group_members(pgid) do
    case System.cmd("pgrep", ["-g", pgid], stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\n", trim: true)
      _ -> []
    end
  end

  def group_leader?(pgid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", pgid], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) == pgid
      _ -> false
    end
  end

  def group_alive?(pgid),
    do:
      pgid != nil and
        match?({_, 0}, System.cmd("kill", ["-0", "-" <> pgid], stderr_to_stdout: true))

  def pgid_of(process_id) when is_binary(process_id),
    do: String.replace_prefix(process_id, "pgid:", "")

  def pgid_of(_), do: nil
end

:logger.update_formatter_config(:default, %{metadata: :all})

phase = System.fetch_env!("LIVE_PHASE")
FinalEval.say("phase", phase)
FinalEval.say("environment", Application.get_env(:shoestring, :environment))
FinalEval.say("handoff_observe", Application.get_env(:shoestring, :handoff_observe))
FinalEval.say("dispatch_effect", Application.get_env(:shoestring, :dispatch_effect))

# ---------------------------------------------------------------------------
# The fixture (fixed before execution)
# ---------------------------------------------------------------------------

task_md = """
# Tic-Tac-Toe CLI

Build a command-line Tic-Tac-Toe game in this Go module (`example.com/tictactoe`),
standard library only. The work is staged across sessions:

1. Package `game/`: board, moves, turn order, winner and draw detection,
   rendering, with table-driven tests.
2. `main.go`: `parseMove(line string) (row, col int, err error)` with tests.
3. The interactive game loop in `main()`, which completes the program.

## Program contract (stage 3)

- Players alternate, X first. Each move is read from standard input as one line
  holding two 1-based integers, row then column, separated by whitespace, for
  example `2 3`.
- After every accepted move, print the board (`game.Render`).
- On input that is not a valid move (unparseable, out of range, or an occupied
  cell), print one line beginning with `invalid` and read the next line; the
  same player moves again.
- When the game ends, print exactly one final line: `X wins`, `O wins`, or
  `Draw`, and exit with status 0.
- Reuse package `game`; do not reimplement its rules in `main.go`.
- `gofmt -l .` prints nothing; `go vet ./...` and `go test ./...` pass.
"""

# Irrelevant material the sender will see and must not be distracted by. The
# scoreboard carries one real `go vet` defect (copylocks), invisible to
# `go build` and `go test`.
legacy_go = """
// Package scoreboard is an older score keeper from a previous prototype.
// It is kept for reference and is not used by the game.
package scoreboard

import "sync"

// Board counts wins per player name.
type Board struct {
\tmu   sync.Mutex
\twins map[string]int
}

// Add records one win for name.
func (b *Board) Add(name string) {
\tb.mu.Lock()
\tdefer b.mu.Unlock()
\tif b.wins == nil {
\t\tb.wins = map[string]int{}
\t}
\tb.wins[name]++
}

// Total returns the number of recorded wins.
func (b Board) Total() int {
\tb.mu.Lock()
\tdefer b.mu.Unlock()
\tn := 0
\tfor _, w := range b.wins {
\t\tn += w
\t}
\treturn n
}
"""

history_md = """
# History

An earlier prototype of this game was a Python script with a curses board and a
scoreboard file. It was abandoned; only `legacy/scoreboard` survives, for
reference. Nothing in this directory is part of the current program.
"""

turn1_prompt = """
You are working in the Go module `example.com/tictactoe` (see go.mod). Implement ONLY a package `game` in the directory `game/`: a 3x3 Tic-Tac-Toe board for players X and O, X moving first. Required API: `type Player rune` with constants `X` and `O`; `func New() *Game`; `func (g *Game) Move(row, col int) error` (0-based row and column; returns an error for out-of-range coordinates, an occupied cell, or any move after the game is over; players alternate); `func (g *Game) Turn() Player`; `func (g *Game) Winner() (Player, bool)`; `func (g *Game) Full() bool`; `func (g *Game) Render() string` (three lines, cells shown as `X`, `O` or `.`, separated by single spaces). Add table-driven tests in `game/game_test.go` covering every row, every column, both diagonals, a draw, and each error case. Constraints: standard library only, no third-party modules; do NOT create main.go or any command-line program in this turn. Run `gofmt -l .` (it must print nothing) and `go test ./...` (it must pass), then commit all changes on the current branch with a descriptive message, and stop.
"""

# The scripted partial-work session (milestone semantic fixture): it inspects
# the repository (relevant and irrelevant files), carries one constraint and
# one rejected approach that are NOT written in the repository, partially
# implements the stage, runs a check that exposes a second failure (`go vet`
# in legacy/), and stops at a scripted point without fixing it.
turn2_prompt = """
Goal: finish the command-line Tic-Tac-Toe program described in TASK.md. The goal is split across sessions. The package `game` in `game/` is finished and tested: read it, do not change its API and do not reimplement its rules.

THIS session does only these steps, then stops; a later session finishes the goal:
1. Start `main.go` (package main at the module root) with `func parseMove(line string) (row, col int, err error)`: exactly two 1-based integers from 1 to 3 separated by whitespace (`2 3` is row 2, column 3, returned 0-based as 1, 2); anything else is an error. Add a table-driven `main_test.go` for it. Leave `func main()` as a minimal placeholder.
2. Run `gofmt -l .`, `go test ./...` and `go vet ./...`. If `go vet` reports a problem outside `main.go`, do NOT fix it in this session; the next session will.
3. Commit your changes on the current branch and stop.

Standing decisions for whoever finishes this goal. They are deliberately not written in the repository; do not add them to any file:
- Constraint: the finished program prints nothing except the board after each accepted move, one line beginning `invalid` for each rejected input, and the one final line `X wins`, `O wins` or `Draw`: no prompts, no banners, no blank lines.
- Rejected approach: silencing `go vet` by deleting, moving or excluding `legacy/` (including build tags) was considered and rejected; `legacy/` must stay and must build. Fix the reported code instead.
Standard library only.
"""

lease_stop_prompt = """
In this Go module, write a thorough design note `DESIGN.md` for a Tic-Tac-Toe engine with minimax search, then implement the engine in a new package `engine/` with exhaustive tests. Work carefully in small steps and verify each step with `go test ./engine/...`. Do not modify `game/`, `main.go` or `legacy/`.
"""

cancel_prompt = """
In this Go module, write a thorough design note `DESIGN.md` for a Tic-Tac-Toe engine with minimax search, then implement the engine in a new package `engine/` with exhaustive tests. Work carefully and verify each step with `go test ./...`.
"""

# Arm inputs (fixed before execution). The trajectory_projection arm's input
# is whatever the product composes for the handoff; these two differ from it
# only in what context accompanies the same committed state. naive_summary is
# byte-identical to #83's.
arm_prompts = %{
  "worktree_only" => "Continue the work in this repository.",
  "naive_summary" =>
    "Continue the work in this repository. Summary of previous work: package game " <>
      "(board, moves, winner and draw detection, rendering, tests) and parseMove in " <>
      "main.go with its tests are done and committed; main() is still a placeholder."
}

# Receiver lease for the transfer, unchanged from #83 (production-unblock.md
# §3.3): `ClaudeHeadless.probe/1`'s scope/id make a Claude receiver unrenewable
# under the transfer's `subscription` scope, so the default cadence 1 would
# decline it after its first response. Deadline unchanged at 2700 s; budgets
# finite; exhaustion still declines.
handoff_lease_policy = %{
  "deadline_seconds" => 2700,
  "response_budget" => 150,
  "tool_budget" => 300,
  "checkpoint_cadence" => 150,
  "reserves" => %{"response" => 1, "tool" => 1}
}

# Harness-side settle so boot-time writers (reconcilers, the first monitor
# ingest) finish before submitting. Changes no product behaviour.
Process.sleep(String.to_integer(System.get_env("LIVE_SETTLE_S", "10")) * 1000)

case phase do
  "selftest" ->
    # Measure functions on synthetic input; no provider, no product call.
    board = "X . .\n. . .\n. . .\n"
    ok = board <> "invalid move\n" <> board <> "X wins\n"
    prompts = "Player X, enter move: " <> board <> "X wins\n"
    blank = board <> "\n" <> "X wins\n"

    checks = %{
      "c1_clean" => FinalEval.c1_violations(ok, "X wins") == [],
      "c1_prompt" => FinalEval.c1_violations(prompts, "X wins") != [],
      "c1_blank" => FinalEval.c1_violations(blank, "X wins") == [""],
      "c1_final_not_last" => FinalEval.c1_violations("X wins\n" <> board, "X wins") == ["X wins"],
      "mut_heredoc" => FinalEval.mutation?("Bash", "cat > main.go <<'EOF'\npackage main\nEOF"),
      "mut_append" => FinalEval.mutation?("Bash", "printf 'x' >> notes.txt"),
      "mut_sed" => FinalEval.mutation?("Bash", "sed -i '' 's/a/b/' main.go"),
      "mut_gofmt" => FinalEval.mutation?("Bash", "gofmt -w ."),
      "mut_write_tool" => FinalEval.mutation?("Write", nil),
      "not_redirect_devnull" => not FinalEval.mutation?("Bash", "go vet ./... > /dev/null"),
      "not_2to1" => not FinalEval.mutation?("Bash", "go test ./... 2>&1 | tail -5"),
      "not_read" => not FinalEval.mutation?("Bash", "cat game/game.go; git status --short"),
      "not_echo" => not FinalEval.mutation?("Bash", "echo \"== vet\"; go vet ./...")
    }

    FinalEval.record("selftest", %{
      "checks" => checks,
      "all_pass" => Enum.all?(Map.values(checks))
    })

  "setup" ->
    dir = FinalEval.repo_path()
    if File.exists?(dir), do: raise("refusing to overwrite existing #{dir}")
    File.mkdir_p!(Path.join(dir, "legacy/scoreboard"))
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "go.mod"), "module example.com/tictactoe\n\ngo 1.24\n")
    File.write!(Path.join(dir, "TASK.md"), task_md)
    File.write!(Path.join(dir, "legacy/scoreboard/scoreboard.go"), String.trim_leading(legacy_go))
    File.write!(Path.join(dir, "docs/HISTORY.md"), String.trim_leading(history_md))

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
      out
    end

    git.(["init", "-b", "main"])
    git.(["config", "user.name", "Live Eval"])
    git.(["config", "user.email", "live-eval@example.invalid"])
    git.(["add", "."])

    git.([
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-m",
      "Baseline: module, task and legacy material"
    ])

    {vet, vet_code} = FinalEval.run_bounded("go", ["vet", "./..."], dir, 120)
    {test, test_code} = FinalEval.run_bounded("go", ["test", "./..."], dir, 120)

    FinalEval.record("setup", %{
      "head" => String.trim(git.(["rev-parse", "HEAD"])),
      "files" => String.split(String.trim(git.(["ls-files"])), "\n"),
      "remotes" => String.trim(git.(["remote"])),
      "baseline_vet_exit" => vet_code,
      "baseline_vet" => vet,
      "baseline_test_exit" => test_code,
      "baseline_test" => test
    })

  "release" ->
    goal_id = System.fetch_env!("LIVE_RELEASE_GOAL")
    label = System.fetch_env!("LIVE_RELEASE_LABEL")
    {:ok, released} = FinalEval.release_claim(goal_id, label)

    FinalEval.record("release", %{
      "goal_id" => goal_id,
      "label" => label,
      "result" => released.command.result
    })

  turn when turn in ["turn1", "turn2"] ->
    {prompt, base} =
      case turn do
        "turn1" -> {turn1_prompt, FinalEval.result_for("setup")["head"]}
        "turn2" -> {turn2_prompt, FinalEval.result_for("turn1")["worktree"]["head"]}
      end

    {:ok, run_id} = FinalEval.submit_turn("codex", String.trim(prompt), base)
    FinalEval.say("#{turn}_run", run_id)
    {status, run} = FinalEval.wait_stop(run_id, 900)

    FinalEval.record(turn, %{
      "wait" => status,
      "base_revision" => base,
      "run_id" => run.id,
      "goal_id" => run.goal_id,
      "provider_id" => run.provider_id,
      "terminal" => FinalEval.terminal_event(run.goal_id, run.id),
      "normalized_events" => FinalEval.normalized_count(run.id),
      "run_row_status" => run.status,
      "projector" => FinalEval.projector_position(run.goal_id),
      "worktree" => FinalEval.worktree_head(run),
      "lease" => FinalEval.lease_row(run.id),
      "event_types" => FinalEval.event_types(run.goal_id)
    })

    # turn 2's goal keeps its claim: the handoff dispatches under it.
    if turn == "turn1",
      do: FinalEval.say("release", FinalEval.release_claim(run.goal_id, turn) |> elem(0))

  "handoff" ->
    sender = FinalEval.result_for("turn2")
    run = FinalEval.run!(sender["run_id"])

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
    initial_state = FinalEval.worktree_head(run)

    # Attempt 2 only (LIVE_RECLAIM=1). Attempt 1 failed every delivery with
    # `handoff_claim_lost`: this driver had released turn 2's claim, which
    # #83's driver never did. The intent stayed unsettled by design, so this
    # boot's `HandoffReconciler` re-enqueued it. Re-establish the goal's claim
    # with a product `task.claim` command against the goal's own manual
    # admission event, then replay the identical request below; the product
    # converges both on the one intent.
    reclaim =
      if System.get_env("LIVE_RECLAIM") == "1" do
        admission =
          Repo.one!(
            from e in TrajectoryEvent,
              where: e.goal_id == ^run.goal_id and e.type == "admission.decided",
              order_by: [asc: e.sequence],
              limit: 1
          )

        jobs_at_boot =
          Repo.all(
            from j in Oban.Job,
              where: j.queue == "handoff",
              order_by: j.id,
              select: %{id: j.id, state: j.state, attempt: j.attempt}
          )

        claimed =
          Shoestring.Cobbler.submit_command(run.goal_id, %{
            "type" => "task.claim",
            "command_id" => "live-reclaim-#{run.id}",
            "payload" => %{
              "intent" => admission.payload["requested_capability"],
              "scope" => admission.payload["scope"],
              "candidate" =>
                Map.take(admission.payload["candidate"], ["provider_id", "adapter_id"]),
              "admission_event_id" => admission.id
            }
          })

        %{
          "handoff_jobs_at_boot" => jobs_at_boot,
          "claim" =>
            case claimed do
              {:ok, c} -> %{"status" => c.command.status, "result" => c.command.result}
              {:error, reason} -> %{"error" => inspect(reason)}
            end
        }
      end

    FinalEval.say("reclaim", reclaim)
    refs = Continuation.decision_refs(Repo, run.goal_id)
    command_id = "live-handoff-#{run.id}"

    request =
      Shoestring.Cobbler.Handoffs.request(run.goal_id, %{
        "command_id" => command_id,
        "payload" => %{
          "run_id" => run.id,
          "checkpoint_id" => checkpoint_id,
          "decision_refs" => refs,
          "to_provider_id" => "claude",
          "to_adapter_id" => "claude_headless_stream_json",
          "scope" => "subscription",
          "reason" => "continue the Go Tic-Tac-Toe CLI on the other provider",
          "requested_by" => "operator",
          "confirmation" => %{"intent" => "supervised_execution"},
          "lease_policy" => handoff_lease_policy
        }
      })

    {command_status, command_result, job?} =
      case request do
        {:ok, req} -> {req.command.status, req.command.result, req.job != nil}
        {:error, reason} -> {"error", %{"error" => inspect(reason)}, false}
      end

    FinalEval.say("handoff_command", %{status: command_status, result: command_result, job?: job?})

    # A replayed request returns the existing incomplete delivery (the worker
    # is unique per handoff id), so "no job inserted" is not "no delivery".
    delivery? =
      job? or
        Repo.exists?(
          from j in Oban.Job,
            where:
              j.queue == "handoff" and
                j.state in ["available", "scheduled", "executing", "retryable"]
        )

    deadline = System.monotonic_time(:second) + if(delivery?, do: 480, else: 0)

    wait = fn wait ->
      job =
        Repo.one(
          from j in Oban.Job, where: j.queue == "handoff", order_by: [desc: j.id], limit: 1
        )

      created =
        Repo.aggregate(
          from(e in TrajectoryEvent,
            where: e.goal_id == ^run.goal_id and e.type == "handoff.created"
          ),
          :count
        )

      cond do
        created > 0 -> {:handoff_created, job}
        not delivery? -> {:no_delivery_attempt, job}
        job && job.state in ["discarded", "cancelled", "completed"] -> {:settled, job}
        System.monotonic_time(:second) > deadline -> {:timeout, job}
        true -> Process.sleep(3_000) && wait.(wait)
      end
    end

    {outcome, job} = wait.(wait)

    receiver =
      case {outcome, request} do
        {:handoff_created, {:ok, req}} ->
          receiver_run_id = req.handoff_id
          {created, _} = FinalEval.wait_run_created(run.goal_id, receiver_run_id, 300)

          {wait_status, _row} =
            if created == :ok,
              do: FinalEval.wait_stop(receiver_run_id, 2800),
              else: {:not_created, nil}

          receiver_row = Repo.get(RunRecord, receiver_run_id)

          %{
            "run_id" => receiver_run_id,
            "wait" => wait_status,
            "terminal" => FinalEval.terminal_event(run.goal_id, receiver_run_id),
            "suspended" => FinalEval.suspended?(run.goal_id, receiver_run_id),
            "lease" => FinalEval.lease_row(receiver_run_id),
            "prompt" => receiver_row && receiver_row.prompt,
            "prompt_chars" => receiver_row && String.length(receiver_row.prompt || ""),
            "tax" => FinalEval.tax(run.goal_id, receiver_run_id),
            "go" =>
              FinalEval.go_verify(
                FinalEval.worktree_path(run),
                FinalEval.result_for("turn1")["worktree"]["head"],
                sender["worktree"]["head"]
              )
          }

        _other ->
          nil
      end

    command_row =
      Repo.one(
        from c in Shoestring.Cobbler.CommandRecord,
          where: c.goal_id == ^run.goal_id and c.command_id == ^command_id,
          limit: 1
      )

    timing =
      case receiver do
        %{"run_id" => rid} ->
          handoff_at = FinalEval.run_events(run.goal_id, rid, ["handoff.created"]) |> List.first()
          starting_at = FinalEval.run_events(run.goal_id, rid, ["run.starting"]) |> List.first()
          running_at = FinalEval.run_events(run.goal_id, rid, ["run.running"]) |> List.first()
          accepted = command_row && command_row.inserted_at

          %{
            "command_inserted_at" => accepted,
            "handoff_created_at" => handoff_at && handoff_at.at,
            "receiver_starting_at" => starting_at && starting_at.at,
            "receiver_running_at" => running_at && running_at.at
          }

        _ ->
          nil
      end

    FinalEval.record("handoff", %{
      "outcome" => outcome,
      "attempt" => if(reclaim, do: 2, else: 1),
      "reclaim" => reclaim,
      "goal_id" => run.goal_id,
      "sender_run_id" => run.id,
      "checkpoint_id" => checkpoint_id,
      "checkpoint_projected_before_request" => checkpoint_row != nil,
      "checkpoint_projected_after_request" => Repo.get(CheckpointRecord, checkpoint_id) != nil,
      "initial_state" => initial_state,
      "decision_refs" => refs,
      "lease_policy_requested" => handoff_lease_policy,
      "receiver" => receiver,
      "timing" => timing,
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
      "projector" => FinalEval.projector_position(run.goal_id),
      "event_types" => FinalEval.event_types(run.goal_id)
    })

    FinalEval.say(
      "release_handoff_goal",
      FinalEval.release_claim(run.goal_id, "handoff") |> elem(0)
    )

  "arm" ->
    arm = System.fetch_env!("LIVE_ARM")
    prompt = Map.fetch!(arm_prompts, arm)
    turn2 = FinalEval.result_for("turn2")
    base = turn2["worktree"]["head"]

    {:ok, run_id} =
      FinalEval.submit_turn("claude", prompt, base,
        timeout_seconds: "2700",
        max_events: "5000",
        lease_seconds: "300"
      )

    FinalEval.say("arm_run", {arm, run_id})
    {status, run} = FinalEval.wait_stop(run_id, 2800)

    FinalEval.record("arm:" <> arm, %{
      "arm" => arm,
      "wait" => status,
      "run_id" => run.id,
      "goal_id" => run.goal_id,
      "base_revision" => base,
      "initial_state" => %{"head" => base},
      "prompt" => prompt,
      "prompt_chars" => String.length(prompt),
      "terminal" => FinalEval.terminal_event(run.goal_id, run.id),
      "suspended" => FinalEval.suspended?(run.goal_id, run.id),
      "lease" => FinalEval.lease_row(run.id),
      "tax" => FinalEval.tax(run.goal_id, run.id),
      "go" =>
        FinalEval.go_verify(
          FinalEval.worktree_path(run),
          FinalEval.result_for("turn1")["worktree"]["head"],
          base
        ),
      "event_types" => FinalEval.event_types(run.goal_id)
    })

    FinalEval.say("release_arm", FinalEval.release_claim(run.goal_id, "arm-" <> arm) |> elem(0))

  "lease_stop" ->
    # A planned stop by the lease: the operator's 60 s manual lease deadline
    # passes mid-task, renewal (manual scope) cannot be admitted, and the Elf
    # must decline at the next safe boundary — checkpoint, suspend, request a
    # safe session stop — without interrupting an in-flight item. The durable
    # decline wake is observed, not driven. If the product dispatches a
    # continuation, it is recorded and then explicitly cancelled once it has
    # run, to bound spend: an operator act, recorded as such.
    base = FinalEval.result_for("turn2")["worktree"]["head"]

    {:ok, run_id} =
      FinalEval.submit_turn("codex", String.trim(lease_stop_prompt), base,
        lease_seconds: "60",
        timeout_seconds: "900",
        max_events: "4000"
      )

    FinalEval.say("lease_stop_run", run_id)
    {status, run} = FinalEval.wait_stop(run_id, 900)
    goal_id = run.goal_id

    lifecycle =
      FinalEval.run_events(
        goal_id,
        run_id,
        ["run.starting", "run.running", "run.pausing", "run.suspended", "checkpoint.created"] ++
          FinalEval.terminals()
      )

    lease_events =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and like(e.type, "lease.%"),
          order_by: e.sequence,
          select: %{type: e.type, sequence: e.sequence, at: e.occurred_at}
      )

    events = FinalEval.normalized(goal_id, run_id)

    # Items started but never completed before the stop: Codex command items
    # are `inProgress` then `completed`, keyed by item id.
    item_state =
      Enum.reduce(events, %{}, fn p, acc ->
        ext = p["extensions"] || %{}

        case {p["kind"], ext["codex-app-server:item_id"], ext["codex-app-server:status"]} do
          {kind, id, st} when kind in ["command", "file_change", "tool"] and is_binary(id) ->
            Map.put(acc, id, st)

          _ ->
            acc
        end
      end)

    suspended_seq =
      Enum.find_value(lifecycle, fn e -> if e.type == "run.suspended", do: e.sequence end)

    Process.sleep(String.to_integer(System.get_env("LIVE_WAKE_OBSERVE_S", "150")) * 1000)

    wakeups =
      Repo.all(
        from w in Shoestring.Cobbler.WakeupRecord,
          where: w.goal_id == ^goal_id,
          select: map(w, [:id, :status, :reason, :wake_at, :run_id])
      )

    runs_in_goal =
      Repo.all(
        from r in RunRecord,
          where: r.goal_id == ^goal_id,
          select: %{id: r.id, provider_id: r.provider_id}
      )

    continuation =
      case Enum.reject(runs_in_goal, &(&1.id == run_id)) do
        [] ->
          nil

        [cont | _] ->
          ready_deadline = System.monotonic_time(:second) + 300

          ready = fn ready ->
            pid = FinalEval.running_process_id(goal_id, cont.id)
            n = FinalEval.normalized_count(cont.id)

            cond do
              FinalEval.terminal_event(goal_id, cont.id) != nil -> :already_stopped
              is_binary(pid) and n >= 5 -> :ok
              System.monotonic_time(:second) > ready_deadline -> :timeout
              true -> Process.sleep(1_000) && ready.(ready)
            end
          end

          readiness = ready.(ready)

          cancel =
            if readiness == :ok, do: inspect(Shoestring.Elves.cancel_run(cont.id)), else: nil

          {cstatus, _} = FinalEval.wait_stop(cont.id, 180)

          %{
            "run_id" => cont.id,
            "provider_id" => cont.provider_id,
            "readiness" => readiness,
            "operator_cancel" => cancel,
            "wait" => cstatus,
            "prompt" => FinalEval.run!(cont.id).prompt,
            "normalized_events" => FinalEval.normalized_count(cont.id),
            "terminal" => FinalEval.terminal_event(goal_id, cont.id),
            "lifecycle" =>
              FinalEval.run_events(
                goal_id,
                cont.id,
                ["run.starting", "run.running", "checkpoint.created"] ++ FinalEval.terminals()
              )
              |> Enum.map(&Map.take(&1, [:type, :sequence]))
          }
      end

    FinalEval.record("lease_stop", %{
      "wait" => status,
      "run_id" => run_id,
      "goal_id" => goal_id,
      "lease" => FinalEval.lease_row(run_id),
      "lifecycle" => Enum.map(lifecycle, &Map.take(&1, [:type, :sequence, :at])),
      "lease_events" => lease_events,
      "normalized_events" => length(events),
      "items_not_completed" =>
        item_state
        |> Enum.reject(fn {_id, st} -> st in ["completed", "failed", "declined"] end)
        |> Map.new(),
      "suspended_sequence" => suspended_seq,
      "terminal" => FinalEval.terminal_event(goal_id, run_id),
      "worktree" => FinalEval.worktree_head(run),
      "wakeups" => wakeups,
      "runs_in_goal" => runs_in_goal,
      "continuation" => continuation,
      "event_types" => FinalEval.event_types(goal_id)
    })

    FinalEval.say("release_lease_stop", FinalEval.release_claim(goal_id, "lease-stop") |> elem(0))

  "cancel" ->
    base = FinalEval.result_for("turn2")["worktree"]["head"]
    {:ok, run_id} = FinalEval.submit_turn("codex", String.trim(cancel_prompt), base)
    FinalEval.say("cancel_run_submitted", run_id)
    deadline = System.monotonic_time(:second) + 300

    ready = fn ready ->
      run = FinalEval.run!(run_id)
      pid = FinalEval.running_process_id(run.goal_id, run_id)
      n = FinalEval.normalized_count(run_id)

      cond do
        is_binary(pid) and n >= 5 -> {:ok, pid, n}
        System.monotonic_time(:second) > deadline -> {:timeout, pid, n}
        true -> Process.sleep(1_000) && ready.(ready)
      end
    end

    {ready?, process_id, n_before} = ready.(ready)
    pgid = FinalEval.pgid_of(process_id)

    # The launch handshake's claim, measured live: the recorded group id is a
    # live process that leads its own group, with members.
    leader_before = pgid && FinalEval.group_leader?(pgid)
    members_before = pgid && FinalEval.group_members(pgid)
    alive_before = FinalEval.group_alive?(pgid)
    {us, first} = :timer.tc(fn -> Shoestring.Elves.cancel_run(run_id) end)
    {status, run} = FinalEval.wait_stop(run_id, 120)
    second = Shoestring.Elves.cancel_run(run_id)

    FinalEval.record("cancel", %{
      "ready" => ready?,
      "run_id" => run_id,
      "goal_id" => run.goal_id,
      "normalized_before_cancel" => n_before,
      "group_leader_before" => leader_before,
      "group_member_count_before" => members_before && length(members_before),
      "group_alive_before" => alive_before,
      "first_cancel" => inspect(first),
      "first_cancel_ms" => div(us, 1000),
      "wait" => status,
      "second_cancel" => inspect(second),
      "group_alive_after" => FinalEval.group_alive?(pgid),
      "group_member_count_after" => pgid && length(FinalEval.group_members(pgid)),
      "elf_registered_after" => Shoestring.Elves.whereis(run_id) != nil,
      "terminal" => FinalEval.terminal_event(run.goal_id, run_id),
      "run_cancelled_events" =>
        length(FinalEval.run_events(run.goal_id, run_id, ["run.cancelled"])),
      "checkpoints" => length(FinalEval.run_events(run.goal_id, run_id, ["checkpoint.created"])),
      "event_types" => FinalEval.event_types(run.goal_id)
    })

    FinalEval.say("release_cancel", FinalEval.release_claim(run.goal_id, "cancel") |> elem(0))

  "audit" ->
    # No provider spend. Every node boot before this one ran the boot
    # reconcilers over the same database, so these invariants hold across
    # restarts or they do not.
    runs =
      Repo.all(
        from r in RunRecord, select: %{id: r.id, goal_id: r.goal_id, provider_id: r.provider_id}
      )

    per_run =
      Enum.map(runs, fn r ->
        count = fn types -> length(FinalEval.run_events(r.goal_id, r.id, types)) end

        dispatch_rows =
          Repo.all(
            from d in Shoestring.Harness.DispatchRecord,
              where: d.run_id == ^r.id,
              select: map(d, [:status, :outcome_code])
          )

        terminal = FinalEval.run_events(r.goal_id, r.id, FinalEval.terminals()) |> List.first()
        suspended = FinalEval.run_events(r.goal_id, r.id, ["run.suspended"]) |> List.first()
        checkpoints = FinalEval.run_events(r.goal_id, r.id, ["checkpoint.created"])

        stop_seq = (terminal && terminal.sequence) || (suspended && suspended.sequence)

        %{
          "run_id" => r.id,
          "provider_id" => r.provider_id,
          "starting" => count.(["run.starting"]),
          "running" => count.(["run.running"]),
          "terminals" => count.(FinalEval.terminals()),
          "terminal" => terminal && terminal.type,
          "suspended" => suspended != nil,
          "checkpoints" => length(checkpoints),
          "checkpoint_before_stop" =>
            stop_seq != nil and Enum.any?(checkpoints, &(&1.sequence < stop_seq)),
          "dispatch_rows" => dispatch_rows
        }
      end)

    handoff = FinalEval.result_for("handoff")

    replay =
      case handoff do
        %{
          "goal_id" => goal_id,
          "sender_run_id" => sender,
          "checkpoint_id" => cid,
          "decision_refs" => refs
        } ->
          jobs_before = Repo.aggregate(from(j in Oban.Job, where: j.queue == "handoff"), :count)
          runs_before = Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal_id), :count)

          again =
            Shoestring.Cobbler.Handoffs.request(goal_id, %{
              "command_id" => "live-handoff-#{sender}",
              "payload" => %{
                "run_id" => sender,
                "checkpoint_id" => cid,
                "decision_refs" => refs,
                "to_provider_id" => "claude",
                "to_adapter_id" => "claude_headless_stream_json",
                "scope" => "subscription",
                "reason" => "continue the Go Tic-Tac-Toe CLI on the other provider",
                "requested_by" => "operator",
                "confirmation" => %{"intent" => "supervised_execution"},
                "lease_policy" => handoff_lease_policy
              }
            })

          Process.sleep(10_000)

          %{
            "result" =>
              case again do
                {:ok, req} ->
                  %{
                    "handoff_id" => req.handoff_id,
                    "status" => req.command.status,
                    "job?" => req.job != nil
                  }

                {:error, reason} ->
                  %{"error" => inspect(reason)}
              end,
            "original_receiver" => handoff["receiver"] && handoff["receiver"]["run_id"],
            "handoff_jobs_before" => jobs_before,
            "handoff_jobs_after" =>
              Repo.aggregate(from(j in Oban.Job, where: j.queue == "handoff"), :count),
            "runs_in_goal_before" => runs_before,
            "runs_in_goal_after" =>
              Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal_id), :count),
            "handoff_created_events" =>
              Repo.aggregate(
                from(e in TrajectoryEvent,
                  where: e.goal_id == ^goal_id and e.type == "handoff.created"
                ),
                :count
              )
          }

        _ ->
          nil
      end

    jobs =
      Repo.all(
        from j in Oban.Job,
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id)}
      )
      |> Enum.map(fn {q, s, n} -> %{"queue" => q, "state" => s, "count" => n} end)

    FinalEval.record("audit", %{
      "runs" => per_run,
      "replay" => replay,
      "jobs" => jobs,
      "invariants" => %{
        "at_most_one_starting_per_run" => Enum.all?(per_run, &(&1["starting"] <= 1)),
        "at_most_one_terminal_per_run" => Enum.all?(per_run, &(&1["terminals"] <= 1)),
        "every_stop_has_checkpoint_before_it" =>
          per_run
          |> Enum.filter(&(&1["terminal"] != nil or &1["suspended"]))
          |> Enum.all?(& &1["checkpoint_before_stop"]),
        "one_dispatch_row_per_started_run" =>
          per_run
          |> Enum.filter(&(&1["starting"] > 0))
          |> Enum.all?(&(length(&1["dispatch_rows"]) == 1))
      }
    })
end
