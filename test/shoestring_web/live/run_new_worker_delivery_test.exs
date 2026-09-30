defmodule ShoestringWeb.RunNewWorkerDeliveryTest do
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query

  alias Shoestring.Harness.{DispatchRecord, DispatchWorker, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    previous = Application.get_env(:shoestring, :dispatch_effect)
    previous_opts = Application.get_env(:shoestring, :elf_dispatch_opts)
    Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)
    Application.put_env(:shoestring, :elf_dispatch_opts, notify: self())

    on_exit(fn ->
      if previous do
        Application.put_env(:shoestring, :dispatch_effect, previous)
      else
        Application.delete_env(:shoestring, :dispatch_effect)
      end

      if previous_opts do
        Application.put_env(:shoestring, :elf_dispatch_opts, previous_opts)
      else
        Application.delete_env(:shoestring, :elf_dispatch_opts)
      end
    end)

    :ok
  end

  test "the attributed direct Fake hatch also completes its success scenario", %{conn: conn} do
    {:ok, view, _} = live(conn, "/runs/new")
    view |> element("#btn-use-fixture") |> render_click()

    {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
      view
      |> form("#manual-run-form", %{
        "run" => %{
          "prompt" => "Direct Fake success",
          "scenario" => "success",
          "expert_bypass" => "true",
          "confirmed_by" => "iter6-hermetic-operator"
        }
      })
      |> render_submit()

    try do
      case Shoestring.Elves.whereis(run_id) do
        nil ->
          :ok

        pid ->
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
      end

      assert Repo.get!(RunRecord, run_id).status == "completed"

      running =
        Repo.one!(
          from e in TrajectoryEvent, where: e.run_id == ^run_id and e.type == "run.running"
        )

      "pgid:" <> pgid = running.payload["process_id"]
      assert Shoestring.Test.ElvesHelpers.group_members(String.to_integer(pgid)) == []
    after
      stop_owned_elf!(run_id)
    end
  end

  test "the worker reconstructs the submitted Fake success scenario", %{conn: conn} do
    {:ok, view, _} = live(conn, "/runs/new")
    view |> element("#btn-use-fixture") |> render_click()

    {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
      view
      |> form("#manual-run-form", %{
        "run" => %{"prompt" => "Persisted Fake success", "scenario" => "success"}
      })
      |> render_submit()

    on_exit(fn -> stop_owned_elf!(run_id) end)
    dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
    job = Repo.one!(from j in Oban.Job, where: j.args["dispatch_id"] == ^dispatch.dispatch_id)
    assert :ok = DispatchWorker.perform(job)

    case Shoestring.Elves.whereis(run_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
    end

    assert Repo.get!(RunRecord, run_id).status == "completed"
  end

  test "guarded submission executes only through its durable worker and replays once", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/runs/new")
    view |> element("#btn-use-fixture") |> render_click()

    {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
      view
      |> form("#manual-run-form", %{
        "run" => %{"prompt" => "Durable worker delivery", "scenario" => "quiet_exit"}
      })
      |> render_submit()

    on_exit(fn -> stop_owned_elf!(run_id) end)
    assert Shoestring.Elves.whereis(run_id) == nil
    run = Repo.get!(RunRecord, run_id)
    assert run.status == "requested"
    assert run.extensions["shoestring.fake:scenario"] == "quiet_exit"
    dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
    job = Repo.one!(from j in Oban.Job, where: j.args["dispatch_id"] == ^dispatch.dispatch_id)

    assert :ok = DispatchWorker.perform(job)
    pid = Shoestring.Elves.whereis(run_id)
    assert is_pid(pid)
    _ = :sys.get_state(pid)
    assert Repo.get!(DispatchRecord, dispatch.dispatch_id).status == "effect_completed"
    assert :ok = DispatchWorker.perform(job)
    assert Shoestring.Elves.whereis(run_id) == pid

    assert Repo.aggregate(
             from(e in TrajectoryEvent,
               where: e.run_id == ^run_id and e.type == "run.running"
             ),
             :count
           ) == 1

    stop_owned_elf!(run_id)

    running =
      Repo.one!(from e in TrajectoryEvent, where: e.run_id == ^run_id and e.type == "run.running")

    "pgid:" <> pgid = running.payload["process_id"]
    assert Shoestring.Test.ElvesHelpers.group_members(String.to_integer(pgid)) == []
  end

  defp stop_owned_elf!(run_id) do
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
