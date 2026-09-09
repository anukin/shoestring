defmodule ShoestringWeb.RunNewEntryTest do
  @moduledoc """
  Hermetic LiveViewTest locks for loop-closure I1 (P2): `/runs/new` submits
  Cobbler commands (admission → claim → gated dispatch) instead of calling
  `Elves.start_run` directly; a held claim surfaces the claim-held panel with
  zero runs started; and the expert/test hatch starts directly only with
  attribution, logging an auditable bypass event first.
  """
  use ShoestringWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Shoestring.Cobbler.Commands
  alias Shoestring.Harness.{DispatchRecord, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}
  alias Shoestring.Worktrees

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  setup %{conn: conn} do
    unique = "#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}"
    tmp_root = Path.join(System.tmp_dir!(), "shoestring_entry_test_#{unique}")
    File.rm_rf(tmp_root)
    repo_path = Path.join(tmp_root, "source_repo")
    File.mkdir_p!(repo_path)

    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: repo_path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Shoestring Test"], cd: repo_path)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@shoestring.local"], cd: repo_path)

    File.write!(Path.join(repo_path, "README.md"), "# Test Source Repo\nInitial content\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: repo_path)

    {_, 0} =
      System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-m", "Initial commit"],
        cd: repo_path
      )

    prev_roots = Application.get_env(:shoestring, :manual_run_allowed_repo_roots)
    Application.put_env(:shoestring, :manual_run_allowed_repo_roots, [tmp_root])

    on_exit(fn ->
      if prev_roots do
        Application.put_env(:shoestring, :manual_run_allowed_repo_roots, prev_roots)
      else
        Application.delete_env(:shoestring, :manual_run_allowed_repo_roots)
      end

      File.rm_rf(tmp_root)
    end)

    _sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})

    {:ok, conn: conn, repo_path: repo_path}
  end

  test "guarded submit records admission, claim, and dispatch before navigating", %{
    conn: conn,
    repo_path: repo_path
  } do
    {:ok, view, _html} = live(conn, ~p"/runs/new")

    {:error, {:live_redirect, %{to: target_path}}} =
      render_submit(view, :start_run, %{"run" => submit_params(repo_path)})

    assert target_path =~ ~r|^/runs/[0-9a-f-]+|
    run_id = String.replace(target_path, "/runs/", "")

    run = Repo.get!(RunRecord, run_id)
    assert run.provider_id == "shoestring.harness.fake"

    # Admission → claim → gated dispatch, in that order, before the Elf.
    admission =
      Repo.one!(
        from event in TrajectoryEvent,
          where: event.goal_id == ^run.goal_id and event.type == "admission.decided"
      )

    assert admission.payload["result"] == "admit"
    assert admission.payload["reason_code"] == "operator_confirmed_manual"

    assert Commands.active_claim([]).goal_id == run.goal_id

    dispatch = Repo.one!(from record in DispatchRecord, where: record.goal_id == ^run.goal_id)
    assert dispatch.run_id == run.id
    assert dispatch.status == "requested"

    assert {:ok, %Worktrees.Worktree{}} = Worktrees.get(run_id)
  end

  test "held claim surfaces the claim-held panel and starts zero runs", %{
    conn: conn,
    repo_path: repo_path
  } do
    holder = create_goal!()
    holder_admission = append_admission_event!(holder.id)

    assert {:ok, %{outcome: :recorded}} =
             Commands.submit(
               holder.id,
               claim_command(holder_admission, command_id: "cmd-entry-ui-holder"),
               now: now()
             )

    {:ok, view, _html} = live(conn, ~p"/runs/new")

    html = render_submit(view, :start_run, %{"run" => submit_params(repo_path)})

    assert html =~ "Execution Claim Held"
    assert has_element?(view, "#claim-held-panel")
    assert has_element?(view, "#claim-held-dashboard-link")

    # Refused visibly: no run row, no dispatch row, for any goal.
    assert Repo.aggregate(RunRecord, :count, :id) == 0
    assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 0
    assert Commands.active_claim([]).goal_id == holder.id
  end

  test "hatch with attribution starts directly and logs the bypass event", %{
    conn: conn,
    repo_path: repo_path
  } do
    {:ok, view, _html} = live(conn, ~p"/runs/new")

    params =
      submit_params(repo_path)
      |> Map.merge(%{"expert_bypass" => "true", "confirmed_by" => "tester-u3"})

    {:error, {:live_redirect, %{to: target_path}}} =
      render_submit(view, :start_run, %{"run" => params})

    assert target_path =~ ~r|^/runs/[0-9a-f-]+|
    run_id = String.replace(target_path, "/runs/", "")
    run = Repo.get!(RunRecord, run_id)

    # Never silent: the bypass is an auditable admission event on the goal,
    # and the run intent itself carries the marker.
    bypass =
      Repo.one!(
        from event in TrajectoryEvent,
          where: event.goal_id == ^run.goal_id and event.type == "admission.decided"
      )

    assert bypass.payload["result"] == "require_confirmation"
    assert bypass.payload["reason_code"] == "operator_confirmed_expert_bypass"
    assert bypass.payload["explanation"] =~ "tester-u3"
    assert run.extensions["shoestring.manual:expert_bypass"] == true
    assert run.extensions["shoestring.manual:confirmed_by"] == "tester-u3"
  end

  test "hatch without attribution is refused fail-closed with zero runs", %{
    conn: conn,
    repo_path: repo_path
  } do
    {:ok, view, _html} = live(conn, ~p"/runs/new")
    goals_before = Repo.aggregate(Goal, :count, :id)

    params = Map.put(submit_params(repo_path), "expert_bypass", "true")

    html = render_submit(view, :start_run, %{"run" => params})

    assert html =~ "requires attribution"
    assert Repo.aggregate(RunRecord, :count, :id) == 0
    # Fail-closed before any side effect: no new goal row (a seeded
    # "Capacity Observatory" goal pre-exists, so compare relatively).
    assert Repo.aggregate(Goal, :count, :id) == goals_before
  end

  defp submit_params(repo_path) do
    %{
      "repo_path" => repo_path,
      "base_revision" => "HEAD",
      "provider" => "fake",
      "prompt" => "Entry closure manual prompt",
      "timeout_seconds" => "60",
      "max_events" => "100",
      "lease_seconds" => "30",
      "scenario" => "success"
    }
  end
end
