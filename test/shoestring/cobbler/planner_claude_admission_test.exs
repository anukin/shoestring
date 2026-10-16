defmodule Shoestring.Cobbler.PlannerClaudeAdmissionTest do
  @moduledoc """
  The Claude planner through the real planner boundary, with a scripted
  stand-in executable (never the real CLI). Claude plans on the subscription
  scope, so admission reads Claude's subscription observation, and its support
  tier makes every call need an explicit single-decision confirmation.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{Commands, Planner, Plans}
  alias Shoestring.Harness.CapacitySnapshot
  import Shoestring.Test.CobblerHelpers, only: [create_goal!: 0]
  import Shoestring.Test.PlanFixtures

  @now ~U[2026-10-04 12:00:00.000000Z]

  setup do
    dir = Path.join(System.tmp_dir!(), "shoestring-claude-admission-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "plan.json"), Jason.encode!(plan()))
    script = Path.join(dir, "claude")

    File.write!(script, """
    #!/usr/bin/env python3
    import json, os, sys
    here = os.path.dirname(os.path.abspath(__file__))
    open(os.path.join(here, "calls"), "a").write("call\\n")
    plan = open(os.path.join(here, "plan.json")).read()
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False,
                      "result": plan, "usage": {"output_tokens": 40}}))
    """)

    File.chmod!(script, 0o755)

    {:ok,
     supervisor: start_supervised!(Task.Supervisor),
     goal: create_goal!(),
     dir: dir,
     script: script}
  end

  defp options(context, extra \\ []) do
    Keyword.merge(
      [
        now: @now,
        task_supervisor: context.supervisor,
        snapshot: snapshot(),
        config: [adapter: :claude, model: "opus", command: context.script, timeout_ms: 30_000]
      ],
      extra
    )
  end

  defp snapshot do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :unknown,
          windows: [],
          observed_at: @now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "claude_headless_stream_json",
            provider_id: "claude",
            invocation_mode: "headless_stream_json",
            event: :explicit_read
          },
          scope: "subscription",
          confidence: :none,
          support_tier: :conservative_partial,
          compatibility_state: :compatible,
          reason: "no_rate_limit_observation",
          extensions: %{}
        },
        now: @now
      )

    snapshot
  end

  defp calls(context) do
    case File.read(Path.join(context.dir, "calls")) do
      {:ok, text} -> length(String.split(text, "\n", trim: true))
      _ -> 0
    end
  end

  test "Claude planning needs a confirmation per call, then yields a ready candidate", context do
    attrs = %{request_key: "initial-1", requested_by: "human:operator", goal_contract: goal()}

    assert {:ok, %{request: request}} = Planner.request(context.goal.id, attrs, options(context))
    assert request.configuration["provider_id"] == "claude"
    assert request.configuration["scope"] == "subscription"
    assert request.configuration["support_tier"] == "conservative_partial"

    # Without confirmation: blocked before any call or charge.
    assert {:ok, %{request: blocked, outcome: :blocked}} =
             Planner.generate(context.goal.id, "initial-1", options(context))

    assert blocked.state == "blocked"
    assert blocked.charged_output_tokens == 0
    assert calls(context) == 0

    assert {:ok, %{request: ready, outcome: :finished}} =
             Planner.generate(
               context.goal.id,
               "initial-1",
               options(context, confirm_unknown_capacity: true)
             )

    assert ready.state == "ready"
    assert ready.charged_output_tokens == 4096
    assert calls(context) == 1
    assert Plans.list_revisions(context.goal.id) == []
    assert Commands.active_claim() == nil
  end

  test "a different executable cannot replay a recorded Claude request", context do
    attrs = %{request_key: "initial-1", requested_by: "human:operator", goal_contract: goal()}
    assert {:ok, _} = Planner.request(context.goal.id, attrs, options(context))

    moved =
      Keyword.put(options(context), :config,
        adapter: :claude,
        model: "opus",
        command: "/bin/echo",
        timeout_ms: 30_000
      )

    assert {:error, :planner_configuration_changed} =
             Planner.generate(
               context.goal.id,
               "initial-1",
               Keyword.put(moved, :confirm_unknown_capacity, true)
             )

    assert calls(context) == 0
  end
end
