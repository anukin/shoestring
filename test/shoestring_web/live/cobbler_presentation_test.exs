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
end
