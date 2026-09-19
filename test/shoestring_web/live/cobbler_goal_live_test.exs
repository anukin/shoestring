defmodule ShoestringWeb.CobblerGoalLiveTest do
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Cobbler

  alias Shoestring.Harness.{
    CapacitySnapshotRecord,
    CheckpointArtifactReference,
    CheckpointRecord,
    ExecutionLeaseRecord,
    RunRecord
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Artifact, Goal, ProjectorPosition, Task, TrajectoryEvent}

  @now ~U[2026-09-07 12:00:00.000000Z]

  test "goal page renders all sections for an admitted goal", %{conn: conn} do
    goal = create_goal!(Repo, "Section goal")
    _admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-goal-header")
    assert has_element?(view, "#cobbler-goal-status[data-status='queued']")
    assert has_element?(view, "#cobbler-admission")
    assert has_element?(view, "#cobbler-decision-result[data-status='admitted']")
    assert has_element?(view, "#cobbler-decision-reason", "automatic_admission_eligible")
    assert has_element?(view, "#cobbler-decision-reserves")
    assert has_element?(view, "#cobbler-lease-empty")
    assert has_element?(view, "#cobbler-checkpoint-empty")
    assert has_element?(view, "#cobbler-claim-empty")
    assert has_element?(view, "#cobbler-sleep-card")
    assert has_element?(view, "#cobbler-commands-list")
    assert has_element?(view, "#cobbler-events-list")
    assert has_element?(view, "#cobbler-projection-status[data-status='not_projected']")
    assert has_element?(view, "#cobbler-goal-refresh")
  end

  test "missing and malformed goals fail safely", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/cobbler/goals/#{Ecto.UUID.generate()}")

    assert has_element?(view, "#cobbler-goal-error")
    refute has_element?(view, "#cobbler-goal-header")

    {:ok, malformed_view, _html} = live(conn, "/cobbler/goals/not-a-uuid")

    assert has_element?(malformed_view, "#cobbler-goal-error")
    refute has_element?(malformed_view, "#cobbler-goal-header")
  end

  test "admission card renders per-result state without a deferral timestamp for admit", %{
    conn: conn
  } do
    goal = create_goal!(Repo, "Admit card goal")
    _admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-decision-result[data-status='admitted']")
    assert has_element?(view, "#cobbler-decision-reserves", "response_budget")
    refute has_element?(view, "#cobbler-decision-defer-until")
  end

  test "a defer_until decision renders the deferral source honestly", %{conn: conn} do
    goal = create_goal!(Repo, "Deferred goal")

    payload =
      admission_payload()
      |> Map.put("result", "defer_until")
      |> Map.put("reason_code", "reserve_breach")
      |> Map.put("explanation", "Deferred until quota reset")
      |> Map.put("defer_until", "2026-09-08T12:00:00.000000Z")

    append_admission_event!(goal.id, payload)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-goal-status[data-status='sleeping']")
    assert has_element?(view, "#cobbler-decision-result[data-status='deferred']")
    assert has_element?(view, "#cobbler-decision-defer-until")
  end

  test "require_confirmation and reject decisions render their own states", %{conn: conn} do
    confirm_goal = create_goal!(Repo, "Confirm goal")

    append_admission_event!(
      confirm_goal.id,
      admission_payload() |> Map.put("result", "require_confirmation")
    )

    {:ok, confirm_view, _html} = live(conn, "/cobbler/goals/#{confirm_goal.id}")

    assert has_element?(
             confirm_view,
             "#cobbler-decision-result[data-status='confirmation-required']"
           )

    reject_goal = create_goal!(Repo, "Reject goal")
    append_admission_event!(reject_goal.id, admission_payload() |> Map.put("result", "reject"))

    {:ok, reject_view, _html} = live(conn, "/cobbler/goals/#{reject_goal.id}")
    assert has_element?(reject_view, "#cobbler-goal-status[data-status='handing-off']")
    assert has_element?(reject_view, "#cobbler-decision-result[data-status='rejected']")
  end

  test "sleep card invents no timestamp when no wake source exists", %{conn: conn} do
    goal = create_goal!(Repo, "Sleep honesty goal")
    _admission = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-sleep-card")
    assert has_element?(view, "#cobbler-sleep-card", "cobbler_wakeups")
    assert has_element?(view, "#cobbler-sleep-card", "No wake time is invented here")
    refute has_element?(view, "#cobbler-sleep-card", "T3")

    refute view |> element("#cobbler-sleep-card time") |> has_element?()
  end

  test "lease card renders bounds and renewal state; empty state otherwise", %{conn: conn} do
    goal = create_goal!(Repo, "Lease goal")
    _admission = append_admission_event!(goal.id)
    insert_lease(goal, status: "active", renewal_state: "eligible")

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-lease")
    assert has_element?(view, "#cobbler-lease-status[data-status='active']")
    assert has_element?(view, "#cobbler-lease-renewal[data-status='eligible']")
    assert has_element?(view, "#cobbler-lease", "10")
    assert has_element?(view, "#cobbler-lease", "25")
    refute has_element?(view, "#cobbler-lease-empty")
  end

  test "lease card derives the nearest boundary from consumed spend (G-BLOCK-2)", %{conn: conn} do
    goal = create_goal!(Repo, "Lease boundary goal")
    _admission = append_admission_event!(goal.id)
    lease = insert_lease(goal, status: "active", renewal_state: "none")

    # Budgets 10/25 with reserves 2/5 put the budget boundaries 8 responses
    # and 20 tools out; the cadence of 5 is nearer. Two counted responses
    # leave the cadence 3 away, and it stays the nearest bound.
    append_output_event!(goal, lease.run_id, "evt-1")
    append_output_event!(goal, lease.run_id, "evt-2")

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-lease-responses-consumed", "2")
    assert has_element?(view, "#cobbler-lease-tools-consumed", "0")
    assert has_element?(view, "#cobbler-lease-epoch", "0")

    assert has_element?(
             view,
             "#cobbler-lease-next-boundary[data-bound='checkpoint_cadence'][data-reached='false']"
           )

    assert has_element?(view, "#cobbler-lease-next-boundary", "Checkpoint cadence")
    assert has_element?(view, "#cobbler-lease-next-boundary", "3 responses away")
  end

  test "lease card reports the boundary as reached once spend meets the cadence", %{conn: conn} do
    goal = create_goal!(Repo, "Lease due goal")
    _admission = append_admission_event!(goal.id)
    lease = insert_lease(goal, status: "renewal_due", renewal_state: "due")

    for index <- 1..5, do: append_output_event!(goal, lease.run_id, "evt-due-#{index}")

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-lease-responses-consumed", "5")

    assert has_element?(
             view,
             "#cobbler-lease-next-boundary[data-bound='checkpoint_cadence'][data-reached='true']"
           )

    assert has_element?(view, "#cobbler-lease-next-boundary", "renewal is due")
  end

  test "lease card shows the full cadence when nothing has been spent", %{conn: conn} do
    goal = create_goal!(Repo, "Lease no-spend goal")
    _admission = append_admission_event!(goal.id)
    _lease = insert_lease(goal, status: "active", renewal_state: "none")

    # No harness events recorded for the run: the nearest bound is the whole
    # cadence, and this is still the first spend epoch.
    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-lease-responses-consumed", "0")
    assert has_element?(view, "#cobbler-lease-epoch", "0")

    assert has_element?(
             view,
             "#cobbler-lease-next-boundary[data-bound='checkpoint_cadence'][data-reached='false']"
           )

    assert has_element?(view, "#cobbler-lease-next-boundary", "5 responses away")
  end

  test "a tool event with no extensions map is not counted, matching the Elf", %{conn: conn} do
    goal = create_goal!(Repo, "Lease rehydration goal")
    _admission = append_admission_event!(goal.id)
    lease = insert_lease(goal, status: "active", renewal_state: "none")

    # Both directions. A well-formed tool event counts ...
    append_tool_event!(goal, lease.run_id, "evt-tool-ok")
    # ... and one whose payload carries no extensions map is dropped, exactly
    # as `Elf`'s rehydration drops it, so the page cannot claim spend the Elf
    # never counted.
    append_tool_event!(goal, lease.run_id, "evt-tool-bare", extensions: :absent)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-lease-tools-consumed", "1")
    refute has_element?(view, "#cobbler-lease-tools-consumed", "2")
  end

  test "lease deadline renders a countdown and keeps the exact instant", %{conn: conn} do
    goal = create_goal!(Repo, "Lease deadline goal")
    _admission = append_admission_event!(goal.id)

    deadline = DateTime.add(DateTime.utc_now(), 7200, :second)
    _lease = insert_lease(goal, status: "active", renewal_state: "none", deadline: deadline)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-lease-deadline", "Expires in")

    # The exact instant stays reachable rather than being replaced.
    assert has_element?(
             view,
             "#cobbler-lease-deadline time[datetime='#{DateTime.to_iso8601(deadline)}']"
           )
  end

  test "a passed lease deadline is worded in the past, not as a countdown", %{conn: conn} do
    goal = create_goal!(Repo, "Lease passed deadline goal")
    _admission = append_admission_event!(goal.id)

    deadline = DateTime.add(DateTime.utc_now(), -7200, :second)
    _lease = insert_lease(goal, status: "expired", renewal_state: "expired", deadline: deadline)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-lease-deadline", "Passed")
    assert has_element?(view, "#cobbler-lease-deadline", "ago")
    refute has_element?(view, "#cobbler-lease-deadline", "Expires in")
  end

  test "a deferral target renders a countdown beside its exact instant", %{conn: conn} do
    goal = create_goal!(Repo, "Deferral countdown goal")

    defer_until = DateTime.add(DateTime.utc_now(), 5400, :second)

    payload =
      admission_payload()
      |> Map.put("result", "defer_until")
      |> Map.put("reason_code", "reserve_breach")
      |> Map.put("explanation", "Deferred until quota reset")
      |> Map.put("defer_until", DateTime.to_iso8601(defer_until))

    append_admission_event!(goal.id, payload)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-defer-countdown", "in 1 hour")

    assert has_element?(
             view,
             "#cobbler-defer-countdown[datetime='#{DateTime.to_iso8601(defer_until)}']"
           )
  end

  test "checkpoint card renders referenced artifacts (G-BLOCK-1)", %{conn: conn} do
    goal = create_goal!(Repo, "Checkpoint artifact goal")
    _admission = append_admission_event!(goal.id)

    checkpoint = insert_checkpoint(goal, %{"summary" => "Artifact checkpoint"})
    artifact = insert_artifact!(goal)
    attach_artifact!(checkpoint, artifact)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-checkpoint-artifacts")
    assert has_element?(view, "#cobbler-checkpoint-artifact-#{artifact.id}")
    assert has_element?(view, "#cobbler-checkpoint-artifacts", artifact.id)
    refute has_element?(view, "#cobbler-checkpoint-artifacts", "No artifacts are referenced")
  end

  test "checkpoint card states an empty artifact list rather than dangling", %{conn: conn} do
    goal = create_goal!(Repo, "Checkpoint no-artifact goal")
    _admission = append_admission_event!(goal.id)
    _checkpoint = insert_checkpoint(goal, %{"summary" => "No artifacts here"})

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-checkpoint-artifacts")
    assert has_element?(view, "#cobbler-checkpoint-artifacts", "No artifacts are referenced")
    refute has_element?(view, "#cobbler-checkpoint-artifacts li")
  end

  test "checkpoint contents are redacted and required content stays visible", %{conn: conn} do
    goal = create_goal!(Repo, "Checkpoint goal")
    _admission = append_admission_event!(goal.id)

    insert_checkpoint(goal, %{
      "summary" => "Checkpoint visible summary",
      "notes" => "saw sk-abcdef1234567890 in output at /Users/eve/.cache",
      "reasoning" => "secret thought content that must not render"
    })

    {:ok, view, html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-checkpoint")
    assert has_element?(view, "#cobbler-checkpoint-contents")

    # Sensitive material is gone ...
    refute html =~ "sk-abcdef1234567890"
    refute html =~ "/Users/eve"
    refute html =~ "secret thought content"
    # ... and required content is still present.
    assert html =~ "Checkpoint visible summary"
    assert has_element?(view, "#cobbler-checkpoint", "Next checkpoint action")
  end

  test "claim card shows the owning goal claim and an empty state otherwise", %{conn: conn} do
    holder = create_goal!(Repo, "Claim holder")
    holder_admission = append_admission_event!(holder.id)

    assert {:ok, _} =
             Cobbler.submit_command(
               holder.id,
               claim_command(holder_admission, command_id: "cmd-claim-card")
             )

    contender = create_goal!(Repo, "Claim contender")
    contender_admission = append_admission_event!(contender.id)

    assert {:ok, _} =
             Cobbler.submit_command(
               contender.id,
               claim_command(contender_admission, command_id: "cmd-claim-contender")
             )

    {:ok, holder_view, _html} = live(conn, "/cobbler/goals/#{holder.id}")
    assert has_element?(holder_view, "#cobbler-claim")
    assert has_element?(holder_view, "#cobbler-claim", "supervised_execution")

    {:ok, contender_view, _html} = live(conn, "/cobbler/goals/#{contender.id}")
    assert has_element?(contender_view, "#cobbler-claim-empty")
    refute has_element?(contender_view, "#cobbler-claim")
  end

  test "confirm form records an attributed response", %{conn: conn} do
    {_holder, contender, command_id, row_id} = needs_user_fixture("cmd-confirm-ok")

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{contender.id}")
    form_id = "#cobbler-confirm-form-#{row_id}"
    assert has_element?(view, form_id)

    view
    |> element(form_id)
    |> render_submit(%{
      "response" => %{
        "command_id" => command_id,
        "resolution" => "abandon",
        "confirmed_by" => "Ada Operator",
        "intent" => "supervised_execution"
      }
    })

    assert %Shoestring.Cobbler.CommandRecord{status: "resolved", result: %{"kind" => "abandoned"}} =
             Cobbler.command(contender.id, command_id)

    refute has_element?(view, form_id)
    assert has_element?(view, "#cobbler-command-#{row_id}[data-status='resolved']")
  end

  test "unattributed confirmations are rejected and change nothing", %{conn: conn} do
    {_holder, contender, command_id, row_id} = needs_user_fixture("cmd-confirm-unattributed")

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{contender.id}")

    view
    |> element("#cobbler-confirm-form-#{row_id}")
    |> render_submit(%{
      "response" => %{
        "command_id" => command_id,
        "resolution" => "abandon",
        "confirmed_by" => "   ",
        "intent" => "supervised_execution"
      }
    })

    assert %Shoestring.Cobbler.CommandRecord{status: "needs_user"} =
             Cobbler.command(contender.id, command_id)

    assert has_element?(view, "#cobbler-confirm-form-#{row_id}")
  end

  test "mismatched intent confirmations are rejected and change nothing", %{conn: conn} do
    {_holder, contender, command_id, row_id} = needs_user_fixture("cmd-confirm-mismatch")

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{contender.id}")

    view
    |> element("#cobbler-confirm-form-#{row_id}")
    |> render_submit(%{
      "response" => %{
        "command_id" => command_id,
        "resolution" => "abandon",
        "confirmed_by" => "Ada Operator",
        "intent" => "something else entirely"
      }
    })

    assert %Shoestring.Cobbler.CommandRecord{status: "needs_user"} =
             Cobbler.command(contender.id, command_id)

    assert has_element?(view, "#cobbler-confirm-form-#{row_id}")
  end

  test "unoffered resolutions are rejected by the domain and change nothing", %{conn: conn} do
    {_holder, contender, command_id, row_id} = needs_user_fixture("cmd-confirm-unoffered")

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{contender.id}")

    view
    |> element("#cobbler-confirm-form-#{row_id}")
    |> render_submit(%{
      "response" => %{
        "command_id" => command_id,
        "resolution" => "confirm",
        "confirmed_by" => "Ada Operator",
        "intent" => "supervised_execution"
      }
    })

    assert %Shoestring.Cobbler.CommandRecord{status: "needs_user"} =
             Cobbler.command(contender.id, command_id)

    assert has_element?(view, "#cobbler-confirm-form-#{row_id}")
  end

  test "stale and degraded observations raise warnings", %{conn: conn} do
    goal = create_goal!(Repo, "Warning goal")

    payload =
      admission_payload()
      |> Map.put("observation", %{
        "snapshot_id" => nil,
        "confidence" => "medium",
        "freshness" => "stale",
        "capacity_state" => "degraded"
      })

    append_admission_event!(goal.id, payload)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-warnings")
    assert has_element?(view, "#cobbler-warning-stale-observation")
    assert has_element?(view, "#cobbler-warning-degraded-capacity")
  end

  test "a failed projection renders redacted detail plus a read-only rebuild affordance", %{
    conn: conn
  } do
    goal = create_goal!(Repo, "Failed projection goal")
    _admission = append_admission_event!(goal.id)

    %ProjectorPosition{
      id: Ecto.UUID.generate(),
      goal_id: goal.id,
      projector: "goal_task",
      version: 1,
      last_sequence: 1,
      status: "failed",
      error_detail: "projection broke reading /Users/eve/.config/cache"
    }
    |> Repo.insert!()

    {:ok, view, html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-projection-status[data-status='failed']")
    assert has_element?(view, "#cobbler-projection-error")
    assert has_element?(view, "#cobbler-rebuild")
    assert has_element?(view, "#cobbler-warning-projection-failed")

    refute html =~ "/Users/eve"
    assert html =~ "[REDACTED]"
  end

  test "a rebuild button re-reads without mutating state", %{conn: conn} do
    goal = create_goal!(Repo, "Rebuild goal")
    admission = append_admission_event!(goal.id)

    assert {:ok, _} =
             Cobbler.submit_command(
               goal.id,
               claim_command(admission, command_id: "cmd-rebuild-read")
             )

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")
    refute has_element?(view, "#cobbler-rebuild-warning")

    commands_before = Repo.aggregate(Shoestring.Cobbler.CommandRecord, :count)
    events_before = Repo.aggregate(TrajectoryEvent, :count)

    view |> element("#cobbler-goal-refresh") |> render_click()

    assert Repo.aggregate(Shoestring.Cobbler.CommandRecord, :count) == commands_before
    assert Repo.aggregate(TrajectoryEvent, :count) == events_before
    refute has_element?(view, "#cobbler-rebuild-warning")
  end

  test "a diverged command store raises the rebuild banner", %{conn: conn} do
    goal = create_goal!(Repo, "Diverged goal")
    admission = append_admission_event!(goal.id)

    assert {:ok, _} =
             Cobbler.submit_command(
               goal.id,
               claim_command(admission, command_id: "cmd-diverge-ui")
             )

    Repo.delete_all(
      from command in Shoestring.Cobbler.CommandRecord, where: command.goal_id == ^goal.id
    )

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

    assert has_element?(view, "#cobbler-rebuild-warning")
  end

  test "appended admission decisions appear without a reload", %{conn: conn} do
    goal = create_goal!(Repo, "Live goal")
    first = append_admission_event!(goal.id)

    {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")
    assert has_element?(view, "#cobbler-event-#{first.id}")

    second = append_admission_event!(goal.id)

    assert has_element?(view, "#cobbler-event-#{second.id}")
    assert has_element?(view, "#cobbler-decision-result[data-status='admitted']")
  end

  test "secret-bearing explanations are redacted while the reason stays visible", %{conn: conn} do
    goal = create_goal!(Repo, "Redaction goal")

    # The registry fail-closes API keys and paths at append time, so this
    # explanation carries shapes that pass validation (a JWT and a thought
    # block) and proves the render boundary still redacts them.
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJVadQssw5c"

    append_admission_event!(
      goal.id,
      admission_payload()
      |> Map.put("reason_code", "automatic_admission_eligible")
      |> Map.put(
        "explanation",
        "Admitted with token #{jwt} and note <thought>hidden provider reasoning</thought> end"
      )
    )

    {:ok, _view, html} = live(conn, "/cobbler/goals/#{goal.id}")

    refute html =~ jwt
    refute html =~ "hidden provider reasoning"
    assert html =~ "[REDACTED"
    assert html =~ "automatic_admission_eligible"
  end

  defp needs_user_fixture(command_id) do
    holder = create_goal!(Repo, "Holder #{command_id}")
    holder_admission = append_admission_event!(holder.id)

    assert {:ok, _} =
             Cobbler.submit_command(
               holder.id,
               claim_command(holder_admission, command_id: "cmd-holder-#{command_id}")
             )

    contender = create_goal!(Repo, "Contender #{command_id}")
    contender_admission = append_admission_event!(contender.id)

    assert {:ok, %{command: row}} =
             Cobbler.submit_command(
               contender.id,
               claim_command(contender_admission, command_id: command_id)
             )

    assert row.status == "needs_user"
    {holder, contender, command_id, row.id}
  end

  defp insert_task(%Goal{} = goal) do
    %Task{}
    |> Task.changeset(%{"title" => "UI task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp insert_run(%Goal{} = goal, %Task{} = task) do
    %RunRecord{
      id: Ecto.UUID.generate(),
      goal_id: goal.id,
      task_id: task.id,
      dispatch_id: Ecto.UUID.generate(),
      provider_id: "codex",
      workspace_ref: "ws-ui",
      request_version: 1,
      prompt: "UI prompt",
      continuation: %{},
      policy: %{"mode" => "supervised"},
      requested_capabilities: %{},
      status: "requested",
      projection_sequence: 0,
      inserted_at: @now,
      updated_at: @now
    }
    |> Repo.insert!()
  end

  defp insert_snapshot(%Goal{} = goal) do
    %CapacitySnapshotRecord{id: Ecto.UUID.generate(), goal_id: goal.id}
    |> CapacitySnapshotRecord.changeset(%{
      contract_version: 1,
      capacity_state: "observed",
      legacy_capacity_state: "known",
      legacy_observed_at: @now,
      freshness_max_age_seconds: 300,
      source_adapter_id: "fixture.adapter",
      source_method: "probe",
      source_provider_id: "codex",
      source_invocation_mode: "cli",
      source_event: "explicit_read",
      scope: "account-ui",
      confidence: "high",
      support_tier: "proactive",
      compatibility_state: "compatible",
      extensions: %{},
      projection_sequence: 0
    })
    |> Repo.insert!()
  end

  defp insert_lease(%Goal{} = goal, opts) do
    task = insert_task(goal)
    run = insert_run(goal, task)
    snapshot = insert_snapshot(goal)

    %ExecutionLeaseRecord{
      id: Ecto.UUID.generate(),
      goal_id: goal.id,
      run_id: run.id,
      admitted_snapshot_id: snapshot.id
    }
    |> ExecutionLeaseRecord.changeset(%{
      contract_version: 1,
      response_reserve: 2,
      tool_reserve: 5,
      response_budget: 10,
      tool_budget: 25,
      deadline: Keyword.get(opts, :deadline, DateTime.add(@now, 3600, :second)),
      checkpoint_cadence: 5,
      renewal_state: Keyword.get(opts, :renewal_state, "none"),
      status: Keyword.get(opts, :status, "active"),
      extensions: %{},
      projection_sequence: 0
    })
    |> Repo.insert!()
  end

  # One counted response: an `:output` event carrying message text. Delta and
  # START frames carry no text and are not counted, per the D4 rules the page
  # reuses rather than restates.
  defp append_output_event!(%Goal{} = goal, run_id, source_event_id) do
    {:ok, event} =
      Trajectory.append(
        goal.id,
        %{
          "type" => "harness.event_recorded",
          "schema_version" => 1,
          "actor" => "elf",
          "occurred_at" => @now,
          "idempotency_key" => source_event_id,
          "payload" => %{
            "run_id" => run_id,
            "source_event_id" => source_event_id,
            "ordinal" => 1,
            "occurred_at" => DateTime.to_iso8601(@now),
            "kind" => "output",
            "extensions" => %{"shoestring.fake:text" => "assistant message"}
          }
        },
        trusted: [run_id: run_id]
      )

    event
  end

  # A durable tool event. `extensions: :absent` omits the key entirely, which
  # the registry allows (extensions is optional for this type) and which the
  # Elf's own rehydration treats as undecodable.
  defp append_tool_event!(%Goal{} = goal, run_id, source_event_id, opts \\ []) do
    base = %{
      "run_id" => run_id,
      "source_event_id" => source_event_id,
      "ordinal" => 1,
      "occurred_at" => DateTime.to_iso8601(@now),
      "kind" => "tool"
    }

    payload =
      case Keyword.get(opts, :extensions, %{"shoestring.fake:tool_name" => "grep"}) do
        :absent -> base
        extensions -> Map.put(base, "extensions", extensions)
      end

    {:ok, event} =
      Trajectory.append(
        goal.id,
        %{
          "type" => "harness.event_recorded",
          "schema_version" => 1,
          "actor" => "elf",
          "occurred_at" => @now,
          "idempotency_key" => source_event_id,
          "payload" => payload
        },
        trusted: [run_id: run_id]
      )

    event
  end

  defp insert_artifact!(%Goal{} = goal) do
    %Artifact{}
    |> Artifact.changeset(%{
      sha256: String.duplicate("a", 64),
      byte_size: 12,
      media_type: "text/plain",
      location: "artifacts/checkpoint-note.txt"
    })
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp attach_artifact!(%CheckpointRecord{} = checkpoint, %Artifact{} = artifact) do
    %CheckpointArtifactReference{}
    |> CheckpointArtifactReference.changeset(checkpoint.id, artifact.id)
    |> Repo.insert!()
  end

  defp insert_checkpoint(%Goal{} = goal, evidence) do
    task = insert_task(goal)
    run = insert_run(goal, task)

    %CheckpointRecord{id: Ecto.UUID.generate(), goal_id: goal.id, run_id: run.id}
    |> CheckpointRecord.changeset(%{
      contract_version: 1,
      acceptance_contract: %{"goal" => "done"},
      repository_state: %{"branch" => "main"},
      evidence: evidence,
      decisions: %{"decision" => "continue"},
      unresolved_issues: %{"issues" => []},
      next_action: "Next checkpoint action",
      stop_reason: "timeboxed",
      extensions: %{},
      projection_sequence: 0
    })
    |> Repo.insert!()
  end
end
