defmodule Shoestring.Test.EvalMatrixHelpers do
  @moduledoc """
  Hermetic drivers for the Milestone 05 deterministic eval matrix (T6) and
  the loop-closure evals (I7).

  Test support only: Fake scenarios, FixedClock/ManualClock, synthetic
  identifiers, and thin wrappers over the real T1–T5 producer interfaces.
  No provider CLI, no network, no production semantics of its own.

  I7 loop-closure drivers (genuine resumed execution): `drive_leg_to_terminal!/2`
  binds a supervised Elf to an existing run row through the durable dispatch
  pipeline (`Dispatches.enqueue_for_run/1` + `Elves.start_elf/3`), so
  `run.starting` / `run.running` / terminal events arrive via the Elf's
  production commit path (I1 dispatch, I2 lease loop, I3 terminal checkpoint)
  and are never hand-appended in the eval tests. `fixture_leg_scenario/0`,
  `arm_next_action/1`, and `score_arm/1` drive the milestone's three ablation
  arms plus the retained fallback arm.

  Scoring normalization (documented here and in
  `plans/evidence/05-quota-aware-mvp/ablation.md`): scripted Fake legs always
  complete in a fixed number of turns, so the harness synthesizes the milestone
  rubric deterministically from genuine run outputs only — the Elf-reported
  terminal class, the composed handoff prompt bytes recorded by the Fake
  `RequestLog`, the arm `next_action` content class, decision-ref counts, and
  genuine trajectory event counts. No model judgment is involved; semantic
  redo differences beyond these proxies remain human-judged (`UNVERIFIED`).
  """

  import Ecto.Query

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Shoestring.Elves
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Harness.Dispatches
  alias Shoestring.Harness.Error
  alias Shoestring.Harness.Fake
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @now ~U[2026-09-07 12:00:00.000000Z]

  @doc "Fixed deterministic timestamp for eval tests."
  @spec now() :: DateTime.t()
  def now, do: @now

  @doc "Default admission candidate (codex, proactive, compatible)."
  @spec candidate(keyword()) :: map()
  def candidate(opts \\ []) do
    %{
      provider_id: Keyword.get(opts, :provider_id, "codex"),
      adapter_id: Keyword.get(opts, :adapter_id, "codex_app_server"),
      support_tier: Keyword.get(opts, :support_tier, :proactive),
      compatibility_state: Keyword.get(opts, :compatibility_state, :compatible),
      scope: Keyword.get(opts, :scope, "account:codex-default"),
      capabilities: ["supervised_execution", "read_only"]
    }
  end

  @doc "Builds a `CapacitySnapshot` from a string-keyed payload (admission-test shape)."
  @spec build_snapshot(map()) :: CapacitySnapshot.t()
  def build_snapshot(overrides \\ %{}) do
    string_overrides =
      overrides |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Map.new()

    base = %{
      "contract_version" => 2,
      "snapshot_id" => Ecto.UUID.generate(),
      "capacity_state" => "observed",
      "windows" => %{
        "items" => [
          %{
            "kind" => "five_hour",
            "state" => "observed",
            "used_percent" => 20.0,
            "reset_at" => "2026-09-07T18:00:00Z"
          },
          %{
            "kind" => "weekly",
            "state" => "observed",
            "used_percent" => 20.0,
            "reset_at" => "2026-09-14T00:00:00Z"
          }
        ]
      },
      "freshness" => %{"max_age_seconds" => 300},
      "source" => %{
        "adapter_id" => "codex_app_server",
        "provider_id" => "codex",
        "invocation_mode" => "app_server",
        "event" => "explicit_read"
      },
      "scope" => "account:codex-default",
      "confidence" => "high",
      "support_tier" => "proactive",
      "compatibility_state" => "compatible",
      "observed_at" => "2026-09-07T11:58:00Z",
      "expires_at" => "2026-09-07T12:03:00Z",
      "extensions" => %{}
    }

    {:ok, snapshot} =
      CapacitySnapshot.from_payload(Map.merge(base, string_overrides), now: @now)

    snapshot
  end

  @doc "Snapshot with the five_hour window at the given usage percent."
  @spec used_snapshot(float(), float()) :: CapacitySnapshot.t()
  def used_snapshot(five_hour_used, weekly_used \\ 20.0) do
    build_snapshot(%{
      windows: %{
        "items" => [
          %{
            "kind" => "five_hour",
            "state" => "observed",
            "used_percent" => five_hour_used,
            "reset_at" => "2026-09-07T18:00:00Z"
          },
          %{
            "kind" => "weekly",
            "state" => "observed",
            "used_percent" => weekly_used,
            "reset_at" => "2026-09-14T00:00:00Z"
          }
        ]
      }
    })
  end

  @doc "Admission-eligible snapshot struct for wake/renew paths (atom-keyed `new/2` shape)."
  @spec eligible_snapshot(DateTime.t()) :: CapacitySnapshot.t()
  def eligible_snapshot(now \\ @now) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :observed,
          windows: [
            %{
              kind: "five_hour",
              state: :observed,
              used_percent: 10.0,
              reset_at: DateTime.add(now, 7_200, :second)
            },
            %{
              kind: "weekly",
              state: :observed,
              used_percent: 12.0,
              reset_at: DateTime.add(now, 7_200, :second)
            }
          ],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "shoestring.harness.fake",
            provider_id: "codex",
            invocation_mode: "headless",
            event: :explicit_read
          },
          scope: "account:codex",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  @doc "Provider-refused snapshot struct for wake/renew paths."
  @spec refused_snapshot(DateTime.t()) :: CapacitySnapshot.t()
  def refused_snapshot(now \\ @now) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :refused,
          windows: [
            %{kind: "five_hour", state: :unknown, reason: "quota refused by provider"},
            %{kind: "weekly", state: :unknown, reason: "quota refused by provider"}
          ],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "shoestring.harness.fake",
            provider_id: "codex",
            invocation_mode: "headless",
            event: :explicit_read
          },
          scope: "account:codex",
          confidence: :medium,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: "provider reported quota refusal",
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  @doc "Grant-style admission payload referencing a snapshot id (wake-test shape)."
  @spec grant_payload(String.t(), String.t(), String.t(), keyword()) :: map()
  def grant_payload(snapshot_id, result, reason_code, opts \\ []) do
    Shoestring.Test.CobblerHelpers.admission_payload()
    |> Map.merge(%{
      "decision_id" => Keyword.get(opts, :decision_id, Ecto.UUID.generate()),
      "result" => result,
      "reason_code" => reason_code,
      "explanation" => "Eval matrix decision: #{reason_code}",
      "observation" => %{
        "snapshot_id" => snapshot_id,
        "confidence" => "high",
        "freshness" => "fresh"
      },
      "proposed_bounds" => %{
        "response_budget" => 10,
        "tool_budget" => 25,
        "deadline" => DateTime.to_iso8601(DateTime.add(@now, 300, :second)),
        "checkpoint_cadence" => 1,
        "reserves" => %{"response" => 1, "tool" => 1}
      }
    })
  end

  @doc "Inserts a task row for a goal."
  @spec insert_task!(map()) :: map()
  def insert_task!(goal) do
    %Shoestring.Trajectory.Task{}
    |> Shoestring.Trajectory.Task.changeset(%{"title" => "Eval matrix task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  @doc "Suspends a run through the canonical run.* event path."
  @spec suspend_run!(String.t(), String.t(), DateTime.t()) :: :ok
  def suspend_run!(goal_id, run_id, now \\ @now) do
    for type <- ["run.starting", "run.running", "run.pausing", "run.suspended"] do
      {:ok, _} =
        Trajectory.append(
          goal_id,
          %{
            "type" => type,
            "schema_version" => 1,
            "actor" => "eval-matrix",
            "occurred_at" => now,
            "payload" => %{"run_id" => run_id}
          },
          trusted: [run_id: run_id]
        )
    end

    :ok
  end

  @doc "Appends a canonical run-scoped trajectory event with a unique key."
  @spec append_event!(String.t(), String.t(), String.t(), map(), DateTime.t(), pos_integer()) ::
          :ok
  def append_event!(goal_id, run_id, type, payload, occurred_at \\ @now, schema_version \\ 1) do
    {:ok, _} =
      Trajectory.append(
        goal_id,
        %{
          "type" => type,
          "schema_version" => schema_version,
          "actor" => "eval-matrix",
          "occurred_at" => occurred_at,
          "idempotency_key" => "#{type}:#{System.unique_integer([:positive])}",
          "payload" => payload
        },
        trusted: [run_id: run_id]
      )

    :ok
  end

  @doc "Schedules an immediately-due wake intent for a goal/run."
  @spec schedule_wake!(map(), map(), String.t(), DateTime.t()) :: map()
  def schedule_wake!(goal, run, command_id, now \\ @now) do
    {:ok, %{wakeup: wakeup, outcome: :recorded}} =
      Shoestring.Cobbler.Wakeups.schedule(goal.id,
        command_id: command_id,
        run_id: run.id,
        wake_at: now,
        now: now
      )

    wakeup
  end

  @doc "Adapter opts for Fake resume/start calls with a request log."
  @spec adapter_opts(pid(), map()) :: map()
  def adapter_opts(log, scenario) do
    %{scenario: scenario, clock: Shoestring.Test.FixedClock, request_log: log}
  end

  # ----------------------------------------------------------------------------
  # I7 loop-closure drivers: genuine resumed execution (no hand-appended terminals)
  # ----------------------------------------------------------------------------

  @doc "Marker for the recorded quota constraint in arm inputs."
  @spec fixture_constraint() :: String.t()
  def fixture_constraint, do: "five-hour reserve"

  @doc "Marker for the concrete next step in arm inputs."
  @spec fixture_step() :: String.t()
  def fixture_step, do: "run the suite"

  @doc """
  Scripted leg-A scenario for the fixture task: inspect relevant + irrelevant
  files, record the constraint + rejected approach, partial implement, a
  failing test, then the scripted quota refusal. Hermetic Fake leg only.
  """
  @spec fixture_leg_scenario() :: Scenario.t()
  def fixture_leg_scenario do
    %Scenario{
      name: :fixture_task_partial,
      capacity: nil,
      provider_session_id: "fake-session-fixture-a",
      events: [
        Scenario.lifecycle_event(offset_ms: 0, source_event_id: "fx-life"),
        Scenario.output_event(
          "inspected lib/widget.ex (relevant) and lib/unrelated.ex (irrelevant)",
          offset_ms: 100,
          source_event_id: "fx-inspect"
        ),
        Scenario.output_event(
          "recorded constraint: five-hour reserve; rejected approach B (in-memory cache)",
          offset_ms: 150,
          source_event_id: "fx-constraint"
        ),
        Scenario.output_event(
          "partial implement: widget steps 1-2; WidgetTest second case FAILING",
          offset_ms: 180,
          source_event_id: "fx-partial"
        ),
        Scenario.error_event(
          Error.new(:quota_refused, "rate_limit_exceeded", "subscription limit reached"),
          offset_ms: 200,
          source_event_id: "fx-refusal"
        )
      ]
    }
  end

  @doc """
  Arm `next_action` inputs for the milestone ablation. The three milestone arms
  differ ONLY here (everything else — fixture leg, checkpoint evidence,
  handoff plumbing, leg-B scenario — is identical); the fourth arm is the
  retained deterministic fallback template (see `P3` in the brief).
  """
  @spec arm_next_action(atom()) :: String.t()
  def arm_next_action(:worktree_only) do
    "Explore the worktree and continue the task."
  end

  def arm_next_action(:naive_summary) do
    "Summary of prior work: inspected lib/widget.ex and lib/unrelated.ex, did " <>
      "partial work on the widget (the first transcript said 'partial work on the widget'), " <>
      "recorded constraint five-hour reserve after three re-reads of the quota docs, tried " <>
      "approach B then rejected it after a long thread debating caches, partially implemented " <>
      "widget steps 1-2 with several reverts, WidgetTest second case is FAILING with an " <>
      "assertion error on line 42 after 3 attempts with full output pasted above and below, " <>
      "also noted unrelated.ex helpers might matter, next: continue implementing the widget " <>
      "and run the suite until green, then re-verify, then clean up, then re-run everything " <>
      "again to be sure, plus review all files once more for completeness and confidence."
  end

  def arm_next_action(:trajectory_projection) do
    "continue from step 3: implement the widget and run the suite " <>
      "(constraint: five-hour reserve; rejected: approach B in-memory cache)"
  end

  @doc """
  Drives one Fake leg to its terminal through the real supervised Elf loop.

  Binds an Elf to the existing run row via the durable dispatch pipeline
  (`Dispatches.enqueue_for_run/1`: dispatch record + Oban job + stable
  `dispatch.requested` intent, never a direct spawn) and `Elves.start_elf/3`
  with a trivial local command. The Elf appends `run.starting` / `run.running`
  itself, streams the scripted Fake scenario, classifies the terminal verdict,
  and commits the terminal event plus the I3 terminal checkpoint through its
  production path. Returns `%{dispatch:, terminal:}` where `terminal` is the
  Elf-reported `%{class: ...}` map.

  Hermetic: Fake scenario + `["python3", "-c", "pass"]`, FixedClock for
  trajectory timestamps. No provider CLI, no network.

  Options: `:scenario` (required), `:supervisor` (a supervised
  `Shoestring.Elves.Supervisor` pid; one is started when absent — pass an
  explicit supervisor when driving several legs in one test, since the test
  supervisor starts each child id only once), `:timeout` (default 10s).
  """
  @spec drive_leg_to_terminal!(RunRecord.t(), keyword()) :: %{
          dispatch: map(),
          terminal: map()
        }
  def drive_leg_to_terminal!(%RunRecord{} = run, opts \\ []) do
    scenario = Keyword.fetch!(opts, :scenario)
    timeout = Keyword.get(opts, :timeout, 10_000)

    sup =
      case Keyword.fetch(opts, :supervisor) do
        {:ok, pid} when is_pid(pid) -> pid
        :error -> start_supervised!({Shoestring.Elves.Supervisor, name: nil})
      end

    assert {:ok, dispatch, _job} = Dispatches.enqueue_for_run(run)
    assert {:ok, request} = Elves.request_from_run(run)

    assert {:ok, _pid} =
             Elves.start_elf(request, dispatch,
               supervisor: sup,
               adapter: Fake,
               adapter_opts: %{scenario: scenario, clock: Shoestring.Test.FixedClock},
               command: ["python3", "-c", "pass"],
               event_interval_ms: 0,
               notify: self(),
               clock: Shoestring.Test.FixedClock
             )

    run_id = run.id
    assert_receive {:elf_terminal, ^run_id, terminal}, timeout

    %{dispatch: dispatch, terminal: terminal}
  end

  @doc """
  Genuine per-run tax metrics: trajectory event counts for the run plus the
  handoff `RequestLog` delivery counts. All inputs are production-persisted
  rows or Fake-recorded adapter calls — never synthesized.
  """
  @spec leg_tax(String.t(), String.t(), pid()) :: map()
  def leg_tax(goal_id, run_id, log) do
    pairs =
      Repo.all(import_query(goal_id, run_id))

    by_type =
      pairs
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {type, actors} -> {type, length(actors)} end)

    %{
      trajectory_by_type: by_type,
      harness_events: Map.get(by_type, "harness.event_recorded", 0),
      adapter_starts: length(Shoestring.Harness.Fake.RequestLog.starts(log)),
      adapter_resumes: length(Shoestring.Harness.Fake.RequestLog.resumes(log)),
      actors: pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp import_query(goal_id, run_id) do
    from event in TrajectoryEvent,
      where: event.goal_id == ^goal_id and event.run_id == ^run_id,
      select: {event.type, event.actor}
  end

  # ----------------------------------------------------------------------------
  # Deterministic rubric scoring (I7 normalization — see moduledoc)
  # ----------------------------------------------------------------------------

  @concise_bytes 800
  @efficient_bytes 500
  @verbose_bytes 1200
  @max_scripted_leg_events 5

  @doc """
  Scores one ablation arm against the milestone rubric (0–2 per dimension).

  Deterministic normalization over genuine run outputs (see moduledoc):
  `terminal_class` is the Elf-reported terminal; `prompt` is the composed
  handoff prompt recorded by the Fake `RequestLog`; `next_action` is the arm
  checkpoint input; `decision_ref_count` comes from the persisted
  `handoff.created` event; `leg_b_event_count` is the genuine
  `harness.event_recorded` count for the leg-B run; `starts`/`resumes` are the
  Fake delivery counts. Returns the per-dimension scores plus `:total`.
  """
  @spec score_arm(map()) :: map()
  def score_arm(%{
        terminal_class: terminal_class,
        prompt: prompt,
        next_action: next_action,
        decision_ref_count: decision_ref_count,
        leg_b_event_count: leg_b_event_count,
        starts: starts,
        resumes: resumes
      }) do
    prompt_bytes = byte_size(prompt)
    has_constraint? = String.contains?(prompt, fixture_constraint())
    has_step? = String.contains?(next_action, fixture_step())

    acceptance =
      cond do
        terminal_class == :completed -> 2
        terminal_class == :interrupted -> 1
        true -> 0
      end

    constraint =
      cond do
        has_constraint? and prompt_bytes <= @concise_bytes -> 2
        has_constraint? -> 1
        true -> 0
      end

    recognition =
      cond do
        decision_ref_count > 0 and has_step? and prompt_bytes <= @concise_bytes -> 2
        decision_ref_count > 0 or has_step? -> 1
        true -> 0
      end

    repeated =
      cond do
        prompt_bytes <= @efficient_bytes -> 2
        prompt_bytes <= @verbose_bytes -> 1
        true -> 0
      end

    turns =
      cond do
        terminal_class == :completed and leg_b_event_count <= @max_scripted_leg_events -> 2
        terminal_class == :completed -> 1
        true -> 0
      end

    capacity =
      cond do
        starts == 1 and resumes == 0 -> 2
        starts <= 2 and resumes == 0 -> 1
        true -> 0
      end

    scores = %{
      acceptance: acceptance,
      constraint: constraint,
      recognition: recognition,
      repeated: repeated,
      turns: turns,
      capacity: capacity
    }

    Map.put(scores, :total, Enum.sum(Map.values(scores)))
  end
end
