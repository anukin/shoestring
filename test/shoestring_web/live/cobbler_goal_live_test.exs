defmodule ShoestringWeb.CobblerGoalLiveTest do
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Cobbler

  alias Shoestring.Harness.{
    CapacitySnapshotRecord,
    CheckpointRecord,
    ExecutionLeaseRecord,
    RunRecord
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, ProjectorPosition, Task, TrajectoryEvent}

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
    assert has_element?(view, "#cobbler-sleep-card", "T3")

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
      deadline: DateTime.add(@now, 3600, :second),
      checkpoint_cadence: 5,
      renewal_state: Keyword.get(opts, :renewal_state, "none"),
      status: Keyword.get(opts, :status, "active"),
      extensions: %{},
      projection_sequence: 0
    })
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
