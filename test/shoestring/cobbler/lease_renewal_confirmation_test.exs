defmodule Shoestring.Cobbler.LeaseRenewalConfirmationTest do
  @moduledoc """
  A run admitted on an attributable confirmation keeps it at renewal while
  the provider's fresh reading has every window observed (iteration 14,
  decided with the user): the confirmation then stands in only for how far
  that evidence is trusted — Claude's own usage reports are conservative —
  never for stale, missing or breached evidence, and an automatic admission
  has no confirmation to keep.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Cobbler.{Dispatcher, LeaseRenewal}
  alias Shoestring.Harness.{Capacity, ExecutionLeaseRecord, Projector}
  alias Shoestring.Test.FixedClock
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  @now ~U[2026-09-07 12:00:00.000000Z]

  @override %{
    "confirmed_by" => "grant:00000000-0000-4000-8000-0000000000aa",
    "confirmed_at" => "2026-09-07T11:59:00.000000Z",
    "intent" => "plan_capacity_confirmation",
    "target_provider_id" => "claude",
    "target_scope" => "subscription",
    "valid" => true,
    "reason" => "valid"
  }

  test "a confirmed run renews on Claude's fresh report while it has room" do
    %{goal: goal, grant_id: grant_id} = granted_lease(confirmed: true)

    assert {:ok, %{outcome: :renewed, decision: decision}} =
             renew(goal, grant_id, claude_report(five_hour: 0.2, weekly: 0.1))

    assert decision.result == :admit
    assert decision.reason_code == "confirmed_support_tier_conservative_partial"
    assert decision.override["confirmed_by"] == @override["confirmed_by"]
    assert lease_status(goal, grant_id) == "renewed"
  end

  # One account claim at a time: each case is its own test.
  for {name, report, result, reason} <- [
        {"stale", [five_hour: 0.2, weekly: 0.1, age: 600], "require_confirmation",
         "stale_observation"},
        # The tier is the first condition it fails; carried, the
        # confirmation would have admitted it.
        {"incomplete", [five_hour: 0.2, weekly: nil], "require_confirmation",
         "support_tier_conservative_partial"},
        {"breached", [five_hour: 0.9, weekly: 0.1], "defer_until", "reserve_breach_five_hour"}
      ] do
    test "the confirmation never covers a #{name} report" do
      %{goal: goal, grant_id: grant_id} = granted_lease(confirmed: true)

      assert {:ok, %{outcome: :expired}} =
               renew(goal, grant_id, claude_report(unquote(report)))

      assert %{"result" => unquote(result), "reason_code" => unquote(reason)} =
               renewal_decision(goal)

      assert lease_status(goal, grant_id) in ["expired", "checkpoint_required"]
    end
  end

  test "an automatic admission has no confirmation to keep" do
    %{goal: goal, grant_id: grant_id} = granted_lease(confirmed: false)

    assert {:ok, %{outcome: :expired}} =
             renew(goal, grant_id, claude_report(five_hour: 0.2, weekly: 0.1))

    assert %{
             "result" => "require_confirmation",
             "reason_code" => "support_tier_conservative_partial"
           } =
             renewal_decision(goal)
  end

  defp renew(goal, grant_id, report) do
    LeaseRenewal.maybe_renew(goal.id, grant_id,
      now: @now,
      clock: FixedClock,
      stop: :already_requested,
      boundary: :turn_outcome,
      observe: fn -> {:ok, report} end
    )
  end

  # Claude's own report (the 2.1.310 `rate_limit_event`) as `Session`
  # normalizes it; `weekly: nil` leaves the seven-day window out.
  defp claude_report(opts) do
    observed_at = DateTime.add(@now, -Keyword.get(opts, :age, 0))
    resets = observed_at |> DateTime.add(3_600) |> DateTime.to_unix()

    windows =
      %{
        "five_hour" => %{
          "utilization" => opts[:five_hour],
          "resetsAt" => resets,
          "status" => "allowed"
        }
      }
      |> then(fn windows ->
        case opts[:weekly] do
          nil ->
            windows

          weekly ->
            Map.put(windows, "seven_day", %{
              "utilization" => weekly,
              "resetsAt" => resets + 86_400,
              "status" => "allowed"
            })
        end
      end)

    frame = %{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{
        "status" => "allowed",
        "rateLimitType" => "five_hour",
        "unifiedWindows" => windows
      }
    }

    {:ok, report} =
      Capacity.normalize(:claude, :headless_stream_json, frame,
        version: "2.1.310",
        now: observed_at,
        captured_at: observed_at,
        adapter_id: "claude_headless_stream_json",
        scope: "subscription"
      )

    report
  end

  defp granted_lease(confirmed: confirmed?) do
    goal = create_goal!()

    task =
      %Shoestring.Trajectory.Task{}
      |> Shoestring.Trajectory.Task.changeset(%{"title" => "Confirmed renewal task"})
      |> Ecto.Changeset.put_change(:goal_id, goal.id)
      |> Repo.insert!()

    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    payload =
      admission_payload(
        provider_id: "claude",
        adapter_id: "claude_headless_stream_json",
        scope: "subscription"
      )
      |> put_in(["candidate", "support_tier"], "conservative_partial")
      |> Map.merge(%{
        "observation" => %{
          "snapshot_id" => snapshot_id,
          "confidence" => "medium",
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
      |> then(fn payload ->
        if confirmed?,
          do:
            Map.merge(payload, %{
              "reason_code" => "confirmed_support_tier_conservative_partial",
              "override" => @override
            }),
          else: payload
      end)

    admission = append_admission_event!(goal.id, payload)

    command =
      claim_command(admission, command_id: "cmd-confirmed-#{System.unique_integer([:positive])}")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               grant_lease: [task_id: task.id, clock: FixedClock, now: FixedClock.now()]
             )

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    %{goal: goal, grant_id: leased.grant_id}
  end

  defp renewal_decision(goal) do
    Repo.one!(
      from e in TrajectoryEvent,
        where:
          e.goal_id == ^goal.id and e.type == "admission.decided" and
            like(e.idempotency_key, "lease-renewal-decision:%"),
        select: e.payload
    )
  end

  defp lease_status(goal, grant_id) do
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    Repo.get!(ExecutionLeaseRecord, grant_id).status
  end
end
