defmodule ShoestringWeb.HermeticFailureRefusalTest do
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query

  alias Shoestring.Cobbler.{Wakeups, WakeupWorker}
  alias Shoestring.Harness.{DispatchRecord, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    keys = [:dispatch_effect, :elf_dispatch_opts, :run_submission_observe, :wakeup_observe]
    previous = Map.new(keys, &{&1, Application.fetch_env(:shoestring, &1)})
    Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)
    Application.delete_env(:shoestring, :elf_dispatch_opts)
    Application.put_env(:shoestring, :run_submission_observe, &capacity/1)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:shoestring, key, old)
          :error -> Application.delete_env(:shoestring, key)
        end
      end
    end)

    :ok
  end

  test "manual quota attempts still require confirmation without a provider probe", %{conn: conn} do
    Application.delete_env(:shoestring, :run_submission_observe)

    Application.put_env(:shoestring, :elf_dispatch_opts,
      scenario: Shoestring.Harness.Fake.Scenario.sudden_quota_refusal()
    )

    owner = self()

    Application.put_env(:shoestring, :wakeup_observe, fn scoping ->
      send(owner, {:manual_failure_probe, scoping})
      capacity(scoping)
    end)

    {:ok, view, _} = live(conn, "/runs/new")
    view |> element("#btn-use-fixture") |> render_click()

    {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
      view
      |> form("#manual-run-form", %{
        "run" => %{"prompt" => "Manual quota needs its operator", "scenario" => "success"}
      })
      |> render_submit()

    try do
      dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
      job = Repo.one!(from j in Oban.Job, where: j.args["dispatch_id"] == ^dispatch.dispatch_id)
      assert :ok = Shoestring.Harness.DispatchWorker.perform(job)
      await_owned_run!(run_id)
      run = Repo.get!(RunRecord, run_id)
      assert run.status == "failed"
      wake = Repo.get_by!(Shoestring.Cobbler.WakeupRecord, run_id: run_id)
      wake_job = Repo.one!(from j in Oban.Job, where: j.args["wakeup_id"] == ^wake.id)
      assert :ok = WakeupWorker.perform(wake_job)
      assert :ok = WakeupWorker.perform(wake_job)
      assert Repo.get!(Shoestring.Cobbler.WakeupRecord, wake.id).status == "woken"

      refusals =
        Repo.all(
          from e in TrajectoryEvent,
            where:
              e.goal_id == ^run.goal_id and e.type == "admission.decided" and
                e.payload["reason_code"] == "manual_scope_not_resumable"
        )

      assert [refusal] = refusals
      assert refusal.payload["result"] == "require_confirmation"
      assert refusal.payload["scope"] == "account:manual"
      assert Repo.get!(RunRecord, run.id) == run
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^run.goal_id), :count) == 1

      assert Repo.aggregate(from(d in DispatchRecord, where: d.goal_id == ^run.goal_id), :count) ==
               1

      refute_received {:manual_failure_probe, _}

      running =
        Repo.one!(
          from e in TrajectoryEvent, where: e.run_id == ^run_id and e.type == "run.running"
        )

      "pgid:" <> pgid = running.payload["process_id"]
      assert Shoestring.Test.ElvesHelpers.group_members(String.to_integer(pgid)) == []
    after
      stop_owned_run!(run_id)
    end
  end

  test "ordinary failed attempts refuse operator recovery and remain visibly failed", %{
    conn: conn
  } do
    owner = self()

    Application.put_env(:shoestring, :wakeup_observe, fn scoping ->
      send(owner, {:ordinary_failure_probe, scoping})
      capacity(scoping)
    end)

    {:ok, view, _} = live(conn, "/runs/new")
    view |> element("#btn-use-fixture") |> render_click()

    {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
      view
      |> form("#manual-run-form", %{
        "run" => %{"prompt" => "Ordinary failure stays terminal", "scenario" => "failure"}
      })
      |> render_submit()

    try do
      dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
      job = Repo.one!(from j in Oban.Job, where: j.args["dispatch_id"] == ^dispatch.dispatch_id)
      assert :ok = Shoestring.Harness.DispatchWorker.perform(job)
      await_owned_run!(run_id)
      run = Repo.get!(RunRecord, run_id)
      assert run.status == "failed"

      failed =
        Repo.one!(
          from e in TrajectoryEvent, where: e.run_id == ^run_id and e.type == "run.failed"
        )

      refute failed.payload["error_category"] == "quota_refused"

      assert {:ok, %{job: wake_job}} =
               Wakeups.request_recheck(run.goal_id,
                 run_id: run.id,
                 operator_identity: "iter6-hermetic-operator"
               )

      assert {:error, {:unexpected_run_state, "failed"}} = WakeupWorker.perform(wake_job)
      assert Repo.get!(RunRecord, run.id) == run
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^run.goal_id), :count) == 1

      assert Repo.aggregate(from(d in DispatchRecord, where: d.goal_id == ^run.goal_id), :count) ==
               1

      {:ok, goal_view, _} = live(conn, "/cobbler/goals/#{run.goal_id}")
      assert has_element?(goal_view, "#cobbler-goal-status[data-status='failed']")
      refute_receive {:ordinary_failure_probe, _}

      running =
        Repo.one!(
          from e in TrajectoryEvent, where: e.run_id == ^run_id and e.type == "run.running"
        )

      "pgid:" <> pgid = running.payload["process_id"]
      assert Shoestring.Test.ElvesHelpers.group_members(String.to_integer(pgid)) == []
    after
      stop_owned_run!(run_id)
    end
  end

  defp capacity(_scoping) do
    snapshot =
      Shoestring.Harness.Fake.Scenario.healthy_snapshot(
        "00000000-0000-4000-8000-f00000000631",
        DateTime.utc_now()
      )

    {:ok,
     %{
       snapshot
       | windows:
           snapshot.windows ++
             [%{kind: "weekly", state: :observed, used_percent: 20.0, reset_at: nil}]
     }}
  end

  defp await_owned_run!(run_id) do
    case Shoestring.Elves.whereis(run_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
    end
  end

  defp stop_owned_run!(run_id) do
    case Shoestring.Elves.whereis(run_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Shoestring.Elves.Elf.cancel(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
    end
  end
end
