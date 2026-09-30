defmodule ShoestringWeb.ProviderSubmissionTest do
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query

  alias Shoestring.Harness.{CapacitySnapshotRecord, ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  test "configured provider observation admits submission on its real scope", %{conn: conn} do
    previous = Application.get_env(:shoestring, :run_submission_observe)
    previous_effect = Application.get_env(:shoestring, :dispatch_effect)
    Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)
    owner = self()

    Application.put_env(:shoestring, :run_submission_observe, fn scoping ->
      send(owner, {:submission_observed, scoping})

      snapshot =
        Shoestring.Harness.Fake.Scenario.healthy_snapshot(
          "00000000-0000-4000-8000-f00000000601",
          DateTime.utc_now()
        )

      {:ok,
       %{
         snapshot
         | windows:
             snapshot.windows ++
               [%{kind: "weekly", state: :observed, used_percent: 20.0, reset_at: nil}]
       }}
    end)

    on_exit(fn ->
      if previous do
        Application.put_env(:shoestring, :run_submission_observe, previous)
      else
        Application.delete_env(:shoestring, :run_submission_observe)
      end

      if previous_effect do
        Application.put_env(:shoestring, :dispatch_effect, previous_effect)
      else
        Application.delete_env(:shoestring, :dispatch_effect)
      end
    end)

    {:ok, view, _} = live(conn, "/runs/new")
    view |> element("#btn-use-fixture") |> render_click()

    {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
      view
      |> form("#manual-run-form", %{
        "run" => %{"prompt" => "Provider-scoped acceptance", "scenario" => "success"}
      })
      |> render_submit()

    run = Repo.get!(RunRecord, run_id)

    admission =
      Repo.one!(
        from e in TrajectoryEvent,
          where: e.goal_id == ^run.goal_id and e.type == "admission.decided"
      )

    assert admission.payload["scope"] == "subscription"
    assert admission.payload["result"] == "admit"
    assert admission.payload["candidate"]["support_tier"] == "proactive"
    assert admission.payload["requested_capability"] == "supervised_execution"
    assert admission.payload["proposed_bounds"]["response_budget"] == 10
    assert admission.payload["proposed_bounds"]["tool_budget"] == 25
    assert run.extensions["shoestring.manual:max_events"] == 1000
    assert_receive {:submission_observed, %{provider_id: "fake", scope: "subscription"}}
    assert Shoestring.Elves.whereis(run_id) == nil

    dispatch = Repo.get_by!(Shoestring.Harness.DispatchRecord, run_id: run_id)
    job = Repo.one!(from j in Oban.Job, where: j.args["dispatch_id"] == ^dispatch.dispatch_id)
    assert :ok = Shoestring.Harness.DispatchWorker.perform(job)

    case Shoestring.Elves.whereis(run_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
    end

    assert Repo.get!(RunRecord, run_id).status == "completed"
    lease = Repo.get_by!(ExecutionLeaseRecord, run_id: run_id)
    assert lease.extensions["cobbler.lease:scope"] == "subscription"
    assert Repo.get!(CapacitySnapshotRecord, lease.admitted_snapshot_id).goal_id == run.goal_id

    running =
      Repo.one!(from e in TrajectoryEvent, where: e.run_id == ^run_id and e.type == "run.running")

    "pgid:" <> pgid = running.payload["process_id"]
    assert Shoestring.Test.ElvesHelpers.group_members(String.to_integer(pgid)) == []
  end
end
