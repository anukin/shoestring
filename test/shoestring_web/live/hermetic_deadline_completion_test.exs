defmodule ShoestringWeb.HermeticDeadlineCompletionTest do
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query

  alias Shoestring.Harness.{CheckpointRecord, DispatchRecord, ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Test.HermeticLifecycleClock
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    start_supervised!({HermeticLifecycleClock, now: DateTime.utc_now()})
    keys = [:dispatch_clock, :dispatch_effect, :elf_dispatch_opts, :run_submission_observe]
    previous = Map.new(keys, &{&1, Application.fetch_env(:shoestring, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:shoestring, key, old)
          :error -> Application.delete_env(:shoestring, key)
        end
      end
    end)

    snapshot =
      Shoestring.Harness.Fake.Scenario.healthy_snapshot(
        "00000000-0000-4000-8000-f00000000621",
        HermeticLifecycleClock.now()
      )

    snapshot = %{
      snapshot
      | windows:
          snapshot.windows ++
            [%{kind: "weekly", state: :observed, used_percent: 20.0, reset_at: nil}]
    }

    scenario =
      Shoestring.Harness.Fake.Scenario.normal_completion(now: HermeticLifecycleClock.now())

    scenario = %{scenario | capacity: snapshot}
    Application.put_env(:shoestring, :dispatch_clock, HermeticLifecycleClock)
    Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)

    Application.put_env(:shoestring, :elf_dispatch_opts,
      scenario: scenario,
      clock: HermeticLifecycleClock
    )

    Application.put_env(:shoestring, :run_submission_observe, fn _ -> {:ok, snapshot} end)
    :ok
  end

  test "natural completion after the declared lease deadline never suspends or redispatches", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/runs/new")
    view |> element("#btn-use-fixture") |> render_click()

    {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
      view
      |> form("#manual-run-form", %{
        "run" => %{
          "prompt" => "Complete the deadline twin",
          "scenario" => "success",
          "lease_seconds" => "10"
        }
      })
      |> render_submit()

    run = Repo.get!(RunRecord, run_id)
    assert run.status == "requested"
    assert Shoestring.Elves.whereis(run_id) == nil

    proposed =
      Repo.one!(
        from e in TrajectoryEvent, where: e.run_id == ^run_id and e.type == "lease.proposed"
      )

    assert proposed.payload["deadline"] ==
             DateTime.to_iso8601(DateTime.add(HermeticLifecycleClock.now(), 10, :second))

    HermeticLifecycleClock.advance(11)
    dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
    job = Repo.one!(from j in Oban.Job, where: j.args["dispatch_id"] == ^dispatch.dispatch_id)

    try do
      assert :ok = Shoestring.Harness.DispatchWorker.perform(job)
      await_owned_run!(run_id)
      assert Repo.get!(RunRecord, run_id).status == "completed"
      assert Repo.get_by!(ExecutionLeaseRecord, run_id: run_id).status == "checkpoint_required"

      checkpoint =
        Repo.get!(CheckpointRecord, Shoestring.Elves.TerminalCheckpoint.checkpoint_id(run_id))

      assert checkpoint.stop_reason == "run.completed"
      assert count(run_id, ["run.completed"]) == 1
      assert count(run_id, ["run.pausing", "run.suspended", "run.failed"]) == 0

      assert Repo.aggregate(
               from(w in Shoestring.Cobbler.WakeupRecord, where: w.goal_id == ^run.goal_id),
               :count
             ) == 0

      assert Repo.aggregate(from(d in DispatchRecord, where: d.goal_id == ^run.goal_id), :count) ==
               1

      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^run.goal_id), :count) == 1
      assert Repo.get!(DispatchRecord, dispatch.dispatch_id).status == "effect_completed"

      running =
        Repo.one!(
          from e in TrajectoryEvent, where: e.run_id == ^run_id and e.type == "run.running"
        )

      "pgid:" <> pgid = running.payload["process_id"]
      assert Shoestring.Test.ElvesHelpers.group_members(String.to_integer(pgid)) == []
      {:ok, goal_view, _} = live(conn, "/cobbler/goals/#{run.goal_id}")
      assert has_element?(goal_view, "#cobbler-goal-status[data-status='completed']")
      refute has_element?(goal_view, "#cobbler-lease-status[data-status='active']")
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

  defp await_owned_run!(run_id) do
    case Shoestring.Elves.whereis(run_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
    end
  end

  defp count(run_id, types) do
    Repo.aggregate(
      from(e in TrajectoryEvent, where: e.run_id == ^run_id and e.type in ^types),
      :count
    )
  end
end
