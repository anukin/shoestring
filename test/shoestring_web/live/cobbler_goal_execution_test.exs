defmodule ShoestringWeb.CobblerGoalExecutionTest do
  @moduledoc """
  Goal-page execution explanation: worktree identity and the separation of an
  actively executing provider from an admission candidate.

  Every fixture is a persisted row or a durable worktree record on disk. No
  provider CLI is invoked and nothing touches the network; the only external
  command is the local `git` call `Shoestring.Worktrees` already makes when it
  verifies a worktree record against its Git directory copy.
  """

  use ShoestringWeb.ConnCase, async: false

  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Harness.RunRecord
  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, Task, TrajectoryEvent}

  @now ~U[2026-09-07 12:00:00.000000Z]

  describe "active provider versus admission candidate" do
    test "an executing run names the active provider distinctly from the candidate", %{conn: conn} do
      goal = create_goal!(Repo, "Executing goal")
      append_admission_event!(goal.id, admission_payload(provider_id: "codex"))
      insert_run!(goal, provider_id: "claude", status: "running")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-active-provider[data-status='running']", "claude")
      assert has_element?(view, "#cobbler-latest-run-status[data-status='running']")
      assert has_element?(view, "#cobbler-candidate-provider", "codex")
      assert has_element?(view, "#cobbler-candidate-adapter", "codex_app_server")
      assert has_element?(view, "#cobbler-candidate-tier", "proactive")
      assert has_element?(view, "#cobbler-candidate-compatibility", "compatible")

      # The candidate never leaks into the active slot and vice versa.
      refute has_element?(view, "#cobbler-active-provider", "codex")
      refute has_element?(view, "#cobbler-candidate-provider", "claude")
    end

    test "a terminal run reports no active provider and never promotes its own", %{conn: conn} do
      goal = create_goal!(Repo, "Completed run goal")
      append_admission_event!(goal.id, admission_payload(provider_id: "codex"))
      insert_run!(goal, provider_id: "claude", status: "completed")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-active-provider[data-status='none']")
      refute has_element?(view, "#cobbler-active-provider", "claude")
      assert has_element?(view, "#cobbler-latest-run-status[data-status='completed']")
      assert has_element?(view, "#cobbler-latest-run-provider", "claude")
    end

    test "a requested run is recorded but is not treated as executing", %{conn: conn} do
      goal = create_goal!(Repo, "Requested run goal")
      append_admission_event!(goal.id)
      insert_run!(goal, provider_id: "codex", status: "requested")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-active-provider[data-status='none']")
      assert has_element?(view, "#cobbler-latest-run-status[data-status='requested']")
      assert has_element?(view, "#cobbler-latest-run-provider", "codex")
    end

    test "a suspended run is recorded but is not treated as executing", %{conn: conn} do
      goal = create_goal!(Repo, "Suspended run goal")
      append_admission_event!(goal.id)
      insert_run!(goal, provider_id: "codex", status: "suspended")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-active-provider[data-status='none']")
      assert has_element?(view, "#cobbler-latest-run-status[data-status='suspended']")
    end

    test "a goal with no run and no decision states both absences explicitly", %{conn: conn} do
      goal = create_goal!(Repo, "Bare goal")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-provider")
      assert has_element?(view, "#cobbler-active-provider[data-status='none']")
      assert has_element?(view, "#cobbler-latest-run-empty")
      assert has_element?(view, "#cobbler-candidate-empty")
      refute has_element?(view, "#cobbler-latest-run")
      refute has_element?(view, "#cobbler-candidate-provider")
    end

    test "a provider session the provider never reported is explicit, not blank", %{conn: conn} do
      goal = create_goal!(Repo, "No session goal")
      append_admission_event!(goal.id)
      insert_run!(goal, provider_id: "codex", status: "running")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-provider-session", "Not reported")
    end

    test "a reported provider session renders as provider-reported evidence", %{conn: conn} do
      goal = create_goal!(Repo, "Session goal")
      append_admission_event!(goal.id)
      insert_run!(goal, provider_id: "codex", status: "running", provider_session_id: "sess-4821")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-provider-session", "sess-4821")
      assert has_element?(view, "#cobbler-provider", "diagnostic")
    end
  end

  describe "isolated worktree identity" do
    test "a registered worktree record renders its actual identity and path", %{conn: conn} do
      goal = create_goal!(Repo, "Worktree goal")
      append_admission_event!(goal.id)
      run = insert_run!(goal, provider_id: "codex", status: "running", workspace_ref: "ws-live")

      worktree = register_worktree!(run.id)

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-worktree-status[data-status='active']")
      assert has_element?(view, "#cobbler-worktree-run", run.id)
      assert has_element?(view, "#cobbler-worktree-workspace-ref", "ws-live")
      assert has_element?(view, "#cobbler-worktree-path", worktree.path)
      assert has_element?(view, "#cobbler-worktree-branch", worktree.branch)
      assert has_element?(view, "#cobbler-worktree-base-commit", worktree.base_commit)
      assert has_element?(view, "#cobbler-worktree-repo-path", worktree.repo_path)
      assert has_element?(view, "#cobbler-worktree-repo-id", worktree.repo_id)
      refute has_element?(view, "#cobbler-worktree-unknown")
    end

    test "a run with no registered record says so and invents no path", %{conn: conn} do
      goal = create_goal!(Repo, "Unregistered worktree goal")
      append_admission_event!(goal.id)
      insert_run!(goal, provider_id: "codex", status: "running", workspace_ref: "ws-missing")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-worktree-unknown[data-state='not_registered']")
      assert has_element?(view, "#cobbler-worktree-workspace-ref", "ws-missing")
      refute has_element?(view, "#cobbler-worktree-path")
      refute has_element?(view, "#cobbler-worktree-branch")
      refute has_element?(view, "#cobbler-worktree-status")
    end

    test "a goal with no run reports no worktree rather than an empty one", %{conn: conn} do
      goal = create_goal!(Repo, "No run worktree goal")
      append_admission_event!(goal.id)

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-worktree")
      assert has_element?(view, "#cobbler-worktree-unknown[data-state='no_run']")
      refute has_element?(view, "#cobbler-worktree-run")
      refute has_element?(view, "#cobbler-worktree-path")
    end

    test "the executing run, not a newer terminal run, names the live worktree", %{conn: conn} do
      goal = create_goal!(Repo, "Two run goal")
      append_admission_event!(goal.id)

      executing =
        insert_run!(goal,
          provider_id: "codex",
          status: "running",
          workspace_ref: "ws-executing",
          inserted_at: @now
        )

      _newer_terminal =
        insert_run!(goal,
          provider_id: "codex",
          status: "completed",
          workspace_ref: "ws-terminal",
          inserted_at: DateTime.add(@now, 60, :second)
        )

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-worktree-run", executing.id)
      assert has_element?(view, "#cobbler-worktree-workspace-ref", "ws-executing")
      refute has_element?(view, "#cobbler-worktree-workspace-ref", "ws-terminal")
    end
  end

  describe "refresh and live updates" do
    test "refresh picks up a run that has started executing", %{conn: conn} do
      goal = create_goal!(Repo, "Refresh goal")
      append_admission_event!(goal.id)
      run = insert_run!(goal, provider_id: "codex", status: "requested")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-active-provider[data-status='none']")

      set_run_status!(run, "running")
      render_click(view, "refresh")

      assert has_element?(view, "#cobbler-active-provider[data-status='running']", "codex")
    end

    test "a committed trajectory event refreshes the provider and worktree cards", %{conn: conn} do
      goal = create_goal!(Repo, "Live update goal")
      append_admission_event!(goal.id)
      run = insert_run!(goal, provider_id: "codex", status: "running", workspace_ref: "ws-live")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-active-provider[data-status='running']")
      assert has_element?(view, "#cobbler-worktree-unknown[data-state='not_registered']")

      set_run_status!(run, "completed")
      worktree = register_worktree!(run.id, status: "completed")

      send(view.pid, {:trajectory_event_committed, %TrajectoryEvent{goal_id: goal.id}})

      assert has_element?(view, "#cobbler-active-provider[data-status='none']")
      assert has_element?(view, "#cobbler-latest-run-status[data-status='completed']")
      assert has_element?(view, "#cobbler-worktree-status[data-status='completed']")
      assert has_element?(view, "#cobbler-worktree-path", worktree.path)
    end

    test "an event for a different goal changes nothing", %{conn: conn} do
      goal = create_goal!(Repo, "Isolated goal")
      append_admission_event!(goal.id)
      run = insert_run!(goal, provider_id: "codex", status: "running")

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      set_run_status!(run, "completed")

      send(
        view.pid,
        {:trajectory_event_committed, %TrajectoryEvent{goal_id: Ecto.UUID.generate()}}
      )

      assert has_element?(view, "#cobbler-active-provider[data-status='running']")
    end
  end

  describe "authorization" do
    test "the execution cards are not reachable for a goal outside the scope", %{conn: conn} do
      goal = create_goal!(Repo, "Foreign goal")
      append_admission_event!(goal.id)
      insert_run!(goal, provider_id: "codex", status: "running", workspace_ref: "ws-secret")

      refute ShoestringWeb.CobblerGoalLive.authorized_goal?(goal, %{
               user: %{id: Ecto.UUID.generate()}
             })

      {:ok, _view, html} = live(conn, "/cobbler/goals/#{goal.id}")

      # Local mode (nil scope) is authorized; the assertion that matters is
      # that a scoped, non-owning viewer never renders execution detail.
      assert html =~ "cobbler-goal-header"
    end
  end

  # -- fixtures --

  defp insert_task(%Goal{} = goal) do
    %Task{}
    |> Task.changeset(%{"title" => "Execution task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp insert_run!(%Goal{} = goal, opts) do
    task = insert_task(goal)
    inserted_at = Keyword.get(opts, :inserted_at, @now)

    %RunRecord{
      id: Ecto.UUID.generate(),
      goal_id: goal.id,
      task_id: task.id,
      dispatch_id: Ecto.UUID.generate(),
      provider_id: Keyword.fetch!(opts, :provider_id),
      workspace_ref: Keyword.get(opts, :workspace_ref, "ws-execution"),
      request_version: 1,
      prompt: "Execution prompt",
      continuation: %{},
      policy: %{"mode" => "supervised"},
      requested_capabilities: %{},
      status: Keyword.fetch!(opts, :status),
      provider_session_id: Keyword.get(opts, :provider_session_id),
      projection_sequence: 0,
      inserted_at: inserted_at,
      updated_at: inserted_at
    }
    |> Repo.insert!()
  end

  defp set_run_status!(%RunRecord{} = run, status) do
    run
    |> Ecto.Changeset.change(%{status: status})
    |> Repo.update!()
  end

  # Writes the durable worktree record `Shoestring.Worktrees` reads, plus a
  # real (non-Git) directory at the recorded path so the library's own
  # record/gitdir consistency check runs exactly as it does in production.
  defp register_worktree!(run_id, opts \\ []) do
    worktrees_dir = Shoestring.State.path(:worktrees)
    records_dir = Path.join(worktrees_dir, ".records")
    File.mkdir_p!(records_dir)

    path = Path.join(worktrees_dir, "run-#{run_id}")
    repo_path = Path.join(worktrees_dir, "source-#{run_id}")
    File.mkdir_p!(path)
    File.mkdir_p!(repo_path)

    record = %{
      "format_version" => 1,
      "run_id" => run_id,
      "repo_id" => "repo-fixture-#{String.slice(run_id, 0, 8)}",
      "repo_path" => repo_path,
      "base_commit" => "0123456789abcdef0123456789abcdef01234567",
      "branch" => "shoestring/run-#{String.slice(run_id, 0, 8)}",
      "path" => path,
      "workspace_ref" => "ws-record",
      "status" => Keyword.get(opts, :status, "active"),
      "created_at" => DateTime.to_iso8601(@now),
      "metadata" => %{}
    }

    record_file = Path.join(records_dir, "#{run_id}.json")
    File.write!(record_file, Jason.encode!(record))

    on_exit(fn ->
      File.rm(record_file)
      File.rm_rf(path)
      File.rm_rf(repo_path)
    end)

    %{
      path: path,
      repo_path: repo_path,
      repo_id: record["repo_id"],
      branch: record["branch"],
      base_commit: record["base_commit"]
    }
  end
end
