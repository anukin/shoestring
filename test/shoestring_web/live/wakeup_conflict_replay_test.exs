defmodule ShoestringWeb.WakeupConflictReplayTest do
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query

  alias Shoestring.Cobbler.{WakeupRecord, Wakeups, WakeupWorker}
  alias Shoestring.Harness.{DispatchRecord, DispatchWorker, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Test.WakeupConflictRepo
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    keys = [:dispatch_effect, :elf_dispatch_opts, :run_submission_observe, :wakeup_observe]
    previous = Map.new(keys, &{&1, Application.fetch_env(:shoestring, &1)})
    Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)
    Application.delete_env(:shoestring, :run_submission_observe)

    Application.put_env(:shoestring, :elf_dispatch_opts,
      scenario: Shoestring.Harness.Fake.Scenario.sudden_quota_refusal()
    )

    owner = self()

    Application.put_env(:shoestring, :wakeup_observe, fn _ ->
      send(owner, :unexpected_manual_probe)
      {:error, :manual_scope_has_no_provider_reading}
    end)

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

  test "unique-conflict recovery replays a settled producer decline without a second job", %{
    conn: conn
  } do
    {run, wake} = settled_quota_wake!(conn)
    start_supervised!({WakeupConflictRepo, key: wake.idempotency_key, owner: self()})

    result =
      Wakeups.schedule(run.goal_id,
        repo: WakeupConflictRepo,
        run_id: run.id,
        command_id: wake.command_id,
        reason: wake.reason,
        wake_at: wake.wake_at
      )

    assert_received :stale_wakeup_lookup
    assert_received :database_wakeup_unique_conflict
    assert {:ok, %{outcome: :replayed, wakeup: replayed, job: nil}} = result
    assert replayed.id == wake.id
    assert Repo.aggregate(from(w in WakeupRecord, where: w.goal_id == ^run.goal_id), :count) == 1

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == "Shoestring.Cobbler.WakeupWorker"),
             :count
           ) == 1

    assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^run.goal_id), :count) == 1

    assert Repo.aggregate(from(d in DispatchRecord, where: d.goal_id == ^run.goal_id), :count) ==
             1

    refute_received :unexpected_manual_probe
  end

  test "unique-conflict recovery still creates a fresh explicit operator recheck", %{conn: conn} do
    {run, _wake} = settled_quota_wake!(conn)
    opts = [run_id: run.id, manual_operator: "iter6-conflict-operator"]
    assert {:ok, %{wakeup: first, job: first_job}} = Wakeups.schedule(run.goal_id, opts)
    assert :ok = WakeupWorker.perform(first_job)
    assert Repo.get!(WakeupRecord, first.id).status == "woken"
    start_supervised!({WakeupConflictRepo, key: first.idempotency_key, owner: self()})

    assert {:ok, %{outcome: :recorded, wakeup: next, job: next_job}} =
             Wakeups.schedule(run.goal_id, Keyword.put(opts, :repo, WakeupConflictRepo))

    refute next.id == first.id
    assert next.idempotency_key == first.idempotency_key <> ":r1"
    assert next_job.args["wakeup_id"] == next.id
    assert_received :stale_wakeup_lookup
    assert_received :database_wakeup_unique_conflict
    assert Repo.aggregate(from(w in WakeupRecord, where: w.goal_id == ^run.goal_id), :count) == 3

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == "Shoestring.Cobbler.WakeupWorker"),
             :count
           ) == 3

    refute_received :unexpected_manual_probe
  end

  defp settled_quota_wake!(conn) do
    {:ok, view, _} = live(conn, "/runs/new")
    view |> element("#btn-use-fixture") |> render_click()

    {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
      view
      |> form("#manual-run-form", %{
        "run" => %{"prompt" => "Conflict replay quota attempt", "scenario" => "success"}
      })
      |> render_submit()

    try do
      dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
      job = Repo.one!(from j in Oban.Job, where: j.args["dispatch_id"] == ^dispatch.dispatch_id)
      assert :ok = DispatchWorker.perform(job)

      case Shoestring.Elves.whereis(run_id) do
        nil ->
          :ok

        pid ->
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
      end

      run = Repo.get!(RunRecord, run_id)
      assert run.status == "failed"
      wake = Repo.get_by!(WakeupRecord, run_id: run.id)
      job = Repo.one!(from j in Oban.Job, where: j.args["wakeup_id"] == ^wake.id)
      assert :ok = WakeupWorker.perform(job)
      wake = Repo.get!(WakeupRecord, wake.id)
      assert wake.status == "woken"

      running =
        Repo.one!(
          from e in TrajectoryEvent, where: e.run_id == ^run.id and e.type == "run.running"
        )

      "pgid:" <> pgid = running.payload["process_id"]
      assert Shoestring.Test.ElvesHelpers.group_members(String.to_integer(pgid)) == []
      {run, wake}
    after
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
end
