defmodule ShoestringWeb.CobblerPresentationTest do
  use ExUnit.Case, async: true

  alias ShoestringWeb.CobblerPresentation

  describe "derive_goal_state/2" do
    test "a fresh goal with no decisions or commands is evaluating" do
      assert CobblerPresentation.derive_goal_state([], []) == :evaluating
    end

    test "admit moves a goal to queued" do
      assert CobblerPresentation.derive_goal_state(["admit"], []) == :queued
    end

    test "defer_until moves a goal to sleeping" do
      assert CobblerPresentation.derive_goal_state(["defer_until"], []) == :sleeping
    end

    test "reject moves a goal to handing_off" do
      assert CobblerPresentation.derive_goal_state(["reject"], []) == :handing_off
    end

    test "require_confirmation waits in evaluating" do
      assert CobblerPresentation.derive_goal_state(["require_confirmation"], []) ==
               :evaluating
    end

    test "a claimed command moves a queued goal to dispatching" do
      assert CobblerPresentation.derive_goal_state(["admit"], ["claimed"]) == :dispatching
    end

    test "a needs_user command waits recoverably in queued" do
      assert CobblerPresentation.derive_goal_state(["admit"], ["needs_user"]) == :queued
    end

    test "an abandoned recovery returns the goal to evaluating" do
      assert CobblerPresentation.derive_goal_state(["admit"], ["needs_user", "abandoned"]) ==
               :evaluating
    end

    test "unrecognized decision results and command kinds fold to unknown, never raise" do
      assert CobblerPresentation.derive_goal_state(["future_result"], []) == :unknown
      assert CobblerPresentation.derive_goal_state(["admit"], ["future_kind"]) == :unknown
      assert CobblerPresentation.derive_goal_state([nil], [nil]) == :unknown
      assert CobblerPresentation.derive_goal_state("nope", "nope") == :unknown
    end
  end

  describe "presentational fallbacks" do
    test "every lifecycle state maps to a distinct status tag" do
      statuses =
        [:evaluating, :queued, :dispatching, :working, :checkpointing, :sleeping, :handing_off]
        |> Enum.map(&CobblerPresentation.lifecycle_presentation(&1).status)

      assert length(Enum.uniq(statuses)) == length(statuses)
    end

    test "unrecognized lifecycle, decision, command, lease, and renewal values render unknown" do
      assert CobblerPresentation.lifecycle_presentation(:future_state).status == "unknown"
      assert CobblerPresentation.lifecycle_presentation("zzz").status == "unknown"
      assert CobblerPresentation.decision_presentation("future_result").status == "unknown"
      assert CobblerPresentation.decision_presentation(nil).status == "unknown"
      assert CobblerPresentation.command_presentation("future_status").status == "unknown"
      assert CobblerPresentation.command_presentation(nil).status == "unknown"
      assert CobblerPresentation.lease_presentation("future_status").status == "unknown"
      assert CobblerPresentation.lease_presentation(nil).status == "unknown"
      assert CobblerPresentation.renewal_presentation("future_state").status == "unknown"
      assert CobblerPresentation.renewal_presentation(nil).status == "unknown"
    end

    test "run statuses keep distinct tags and only live turns count as executing" do
      run_statuses =
        [
          "requested",
          "starting",
          "running",
          "pausing",
          "suspended",
          "completed",
          "failed",
          "interrupted",
          "cancelling",
          "cancelled"
        ]
        |> Enum.map(&CobblerPresentation.run_provider_presentation(&1).status)

      assert length(Enum.uniq(run_statuses)) == length(run_statuses)

      for status <- ["starting", "running", "pausing", "cancelling"] do
        assert CobblerPresentation.run_provider_presentation(status).executing?,
               "#{status} must count as executing"
      end

      for status <- [
            "requested",
            "suspended",
            "completed",
            "failed",
            "interrupted",
            "cancelled"
          ] do
        refute CobblerPresentation.run_provider_presentation(status).executing?,
               "#{status} must not count as executing"
      end
    end

    test "unrecognized run and worktree values render unknown and never executing" do
      assert CobblerPresentation.run_provider_presentation("future_status").status == "unknown"
      assert CobblerPresentation.run_provider_presentation(nil).status == "unknown"
      refute CobblerPresentation.run_provider_presentation("future_status").executing?
      refute CobblerPresentation.run_provider_presentation(nil).executing?
      assert CobblerPresentation.worktree_presentation("future_status").status == "unknown"
      assert CobblerPresentation.worktree_presentation(nil).status == "unknown"
    end

    test "known worktree statuses keep distinct tags" do
      worktree_statuses =
        ["active", "completed", "failed", "suspended", "cancelled"]
        |> Enum.map(&CobblerPresentation.worktree_presentation(&1).status)

      assert length(Enum.uniq(worktree_statuses)) == length(worktree_statuses)
      assert CobblerPresentation.worktree_presentation(:active).status == "active"
    end

    test "known lease statuses and renewal states keep distinct tags" do
      lease_statuses =
        [
          "proposed",
          "granted",
          "active",
          "renewal_due",
          "renewed",
          "expired",
          "revoked",
          "checkpoint_required"
        ]
        |> Enum.map(&CobblerPresentation.lease_presentation(&1).status)

      assert length(Enum.uniq(lease_statuses)) == length(lease_statuses)

      renewal_statuses =
        ["none", "eligible", "due", "renewed", "expired", "revoked"]
        |> Enum.map(&CobblerPresentation.renewal_presentation(&1).status)

      assert length(Enum.uniq(renewal_statuses)) == length(renewal_statuses)
    end
  end

  describe "countdown_presentation/2" do
    @now ~U[2026-09-19 12:00:00.000000Z]

    test "coarsens a future instant to its largest whole unit" do
      for {seconds, expected} <- [
            {30, "in 30 seconds"},
            {1, "in 1 second"},
            {60, "in 1 minute"},
            {150, "in 2 minutes"},
            {3600, "in 1 hour"},
            {7200, "in 2 hours"},
            {86_400, "in 1 day"},
            {172_800, "in 2 days"}
          ] do
        target = DateTime.add(@now, seconds, :second)
        countdown = CobblerPresentation.countdown_presentation(target, @now)

        assert countdown.relative == expected
        assert countdown.elapsed? == false
        assert countdown.absolute == DateTime.to_iso8601(target)
      end
    end

    test "marks a past instant elapsed and words it in the past" do
      countdown =
        CobblerPresentation.countdown_presentation(DateTime.add(@now, -300, :second), @now)

      assert countdown.relative == "5 minutes ago"
      assert countdown.elapsed? == true
    end

    test "the instant itself is neither future nor elapsed" do
      countdown = CobblerPresentation.countdown_presentation(@now, @now)

      assert countdown.relative == "now"
      assert countdown.elapsed? == false
    end

    # No time is invented for an absent one: a nil instant yields nil, and
    # the caller falls back to whatever it actually recorded.
    test "an absent instant yields no countdown" do
      assert CobblerPresentation.countdown_presentation(nil, @now) == nil
      assert CobblerPresentation.countdown_presentation("2026-09-19T12:00:00Z", @now) == nil
    end

    # The absolute instant always survives, so it stays reachable through
    # the `datetime`/`title` attributes even when the relative text is coarse.
    test "keeps the exact instant alongside the coarsened text" do
      target = DateTime.add(@now, 5401, :second)
      countdown = CobblerPresentation.countdown_presentation(target, @now)

      assert countdown.relative == "in 1 hour"
      assert countdown.absolute == DateTime.to_iso8601(target)
    end
  end
end
