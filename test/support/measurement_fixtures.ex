defmodule Shoestring.Test.MeasurementFixtures do
  @moduledoc "Synthetic canonical histories only; no provider CLI or network."
  alias Shoestring.Trajectory.TrajectoryEvent
  @time ~U[2026-10-01 12:00:00.000000Z]

  def time(seconds), do: DateTime.add(@time, seconds, :second)

  def history(opts \\ []) do
    goal = Keyword.get(opts, :goal_id, Ecto.UUID.generate())
    task = Keyword.get(opts, :task_id, Ecto.UUID.generate())
    run = Ecto.UUID.generate()
    snapshot = Ecto.UUID.generate()
    grant = Ecto.UUID.generate()

    request = %{
      "run_id" => run,
      "dispatch_id" => Ecto.UUID.generate(),
      "provider_id" => "codex_app_server_stdio",
      "workspace_ref" => "workspace/fixture",
      "request_version" => 1,
      "prompt" => "Synthetic task text excluded from measurements",
      "continuation" => %{},
      "policy" => %{"mode" => "supervised"},
      "requested_capabilities" => %{"items" => []},
      "extensions" => %{}
    }

    events = [
      event(goal, task, nil, 1, "capacity.snapshot_observed", 0, capacity(snapshot, 0, 10.0), 2),
      event(goal, task, run, 2, "run.requested", 1, request),
      event(goal, task, run, 3, "lease.proposed", 1, %{
        "grant_id" => grant,
        "run_id" => run,
        "admitted_snapshot_id" => snapshot,
        "contract_version" => 1,
        "reserves" => %{"response" => 1, "tool" => 2},
        "response_budget" => 5,
        "tool_budget" => 8,
        "deadline" => DateTime.to_iso8601(time(120)),
        "checkpoint_cadence" => 2,
        "renewal_state" => "none",
        "extensions" => %{}
      }),
      event(goal, task, run, 4, "run.running", 2, %{"run_id" => run}),
      event(goal, task, run, 5, "run.completed", 10, %{"run_id" => run}),
      event(
        goal,
        task,
        nil,
        6,
        "capacity.snapshot_observed",
        11,
        capacity(Ecto.UUID.generate(), 11, 12.0),
        2
      )
    ]

    %{goal_id: goal, task_id: task, run_id: run, events: events}
  end

  def event(goal, task, run, seq, type, seconds, payload, version \\ 1) do
    %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: goal,
      task_id: task,
      run_id: run,
      sequence: seq,
      type: type,
      actor: "fixture",
      schema_version: version,
      occurred_at: time(seconds),
      payload: payload
    }
  end

  def capacity(id, seconds, used) do
    %{
      "snapshot_id" => id,
      "contract_version" => 2,
      "capacity_state" => "observed",
      "windows" => %{
        "items" => [
          %{
            "kind" => "primary",
            "state" => "observed",
            "used_percent" => used,
            "reset_at" => DateTime.to_iso8601(time(3600))
          }
        ]
      },
      "observed_at" => DateTime.to_iso8601(time(seconds)),
      "expires_at" => DateTime.to_iso8601(time(seconds + 60)),
      "freshness" => %{"max_age_seconds" => 60},
      "source" => %{
        "adapter_id" => "codex_app_server_stdio",
        "provider_id" => "codex",
        "invocation_mode" => "app_server",
        "event" => "explicit_read"
      },
      "scope" => "synthetic-account",
      "confidence" => "high",
      "support_tier" => "proactive",
      "compatibility_state" => "compatible",
      "reason" => nil,
      "extensions" => %{"capacity:cli_version" => "0.163.0"}
    }
  end
end
