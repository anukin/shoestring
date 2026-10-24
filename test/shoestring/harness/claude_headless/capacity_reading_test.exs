defmodule Shoestring.Harness.ClaudeHeadless.CapacityReadingTest do
  @moduledoc """
  A Claude worker run's own `rate_limit_event` reaches the durable
  Observatory ledger, and admission reads it from there: it holds Claude work
  until the window resets, then lets the confirmation rules decide.
  """

  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{AdmissionEvaluation, WakeupObserve}
  alias Shoestring.Harness.ClaudeHeadless.Session
  alias Shoestring.Harness.ClaudeScriptedTransport, as: ScriptedTransport
  alias Shoestring.Harness.{Observatory, RunRequest}

  # FixedClock reads 2026-08-30 12:00Z: the five-hour window resets at 14:30Z.
  @five_hour_reset 1_788_100_200
  @seven_day_reset 1_788_480_000

  @candidate %{
    provider_id: "claude",
    adapter_id: "claude_headless_stream_json",
    support_tier: :conservative_partial,
    compatibility_state: :compatible,
    scope: "subscription",
    capabilities: ["supervised_execution", "read_only"]
  }

  defp lines do
    session_id = "aaaaaaaa-0000-4000-a000-000000000201"

    Enum.map(
      [
        %{
          "type" => "system",
          "subtype" => "init",
          "claude_code_version" => "2.1.310",
          "session_id" => session_id
        },
        %{
          "type" => "rate_limit_event",
          "rate_limit_info" => %{
            "status" => "allowed_warning",
            "rateLimitType" => "five_hour",
            "unifiedWindows" => %{
              "five_hour" => %{
                "utilization" => 0.83,
                "resetsAt" => @five_hour_reset,
                "status" => "allowed_warning"
              },
              "seven_day" => %{
                "utilization" => 0.4,
                "resetsAt" => @seven_day_reset,
                "status" => "allowed"
              }
            }
          },
          "session_id" => session_id
        },
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "terminal_reason" => "completed",
          "result" => "OK",
          "session_id" => session_id
        }
      ],
      &Jason.encode!/1
    )
  end

  defp run_claude do
    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000201",
        task_id: "00000000-0000-4000-8000-000000000202",
        workspace_ref: "workspace/contract-test",
        prompt: "Reply OK",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: [],
        dispatch_id: "00000000-0000-4000-8000-000000000203"
      })

    {:ok, transport} = start_supervised({ScriptedTransport, [owner: nil, lines: lines()]})

    session =
      start_supervised!(
        {Session,
         [
           run_request: request,
           run_id: request.dispatch_id,
           transport_pid: transport,
           transport: ScriptedTransport,
           owner: self(),
           capacity_sink: Observatory,
           clock: Shoestring.Test.FixedClock
         ]}
      )

    :sys.replace_state(transport, fn state -> %{state | owner: session} end)
    :ok = ScriptedTransport.replay_all(transport)
    {:ok, summary} = Session.await_terminal(session, 5_000)
    summary
  end

  test "the reading is durable and admission holds Claude until the reset" do
    assert run_claude().status == :completed

    # A later decision reads the ledger, not the finished session.
    assert {:ok, reading} = WakeupObserve.observe(%{provider_id: "claude", scope: "subscription"})
    assert reading.source.invocation_mode == "headless_stream_json"
    assert reading.extensions["claude:rate_limit_status"] == "allowed_warning"

    five_hour = Enum.find(reading.windows, &(&1.kind == "five_hour"))
    assert five_hour.used_percent == 83.0
    assert DateTime.compare(five_hour.reset_at, ~U[2026-08-30 14:30:00Z]) == :eq

    assert {:ok, held} =
             AdmissionEvaluation.evaluate(%{}, @candidate, reading, nil,
               now: ~U[2026-08-30 12:05:00Z]
             )

    assert held.result == :defer_until
    assert held.reason_code == "reserve_breach_five_hour"
    assert DateTime.compare(held.defer_until, ~U[2026-08-30 14:30:00Z]) == :eq

    assert {:ok, after_reset} =
             AdmissionEvaluation.evaluate(%{}, @candidate, reading, nil,
               now: ~U[2026-08-31 09:00:00Z]
             )

    assert after_reset.result == :require_confirmation
  end
end
