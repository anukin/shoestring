defmodule Shoestring.Test.EvalMatrixHelpers do
  @moduledoc """
  Hermetic drivers for the Milestone 05 deterministic eval matrix (T6).

  Test support only: Fake scenarios, FixedClock/ManualClock, synthetic
  identifiers, and thin wrappers over the real T1–T5 producer interfaces.
  No provider CLI, no network, no production semantics of its own.
  """

  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Repo
  alias Shoestring.Trajectory

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
end
