defmodule ShoestringWeb.RuntimeDispatchEntryTest do
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_RUNTIME_ENTRY_CHILD") == "1" do
    import Ecto.Query
    import Phoenix.ConnTest
    import Phoenix.LiveViewTest

    alias Shoestring.Harness.{DispatchRecord, RunRecord}
    alias Shoestring.Repo
    alias Shoestring.Trajectory.TrajectoryEvent
    @endpoint ShoestringWeb.Endpoint

    setup do
      root = Process.whereis(Shoestring.Supervisor)
      ref = Process.monitor(root)
      assert :ok = Application.stop(:shoestring)
      assert_receive {:DOWN, ^ref, :process, ^root, _}, 15_000

      mode = System.fetch_env!("SHOESTRING_RUNTIME_ENTRY_ENV") |> String.to_existing_atom()
      # The effect under test comes exclusively from the actual runtime file.
      # Other inherited test settings disable provider monitors, HTTP server,
      # queues and plugins. Only the Fake fixture's durable job is drained.
      runtime = Config.Reader.read!("config/runtime.exs", env: mode, target: :host)
      Application.delete_env(:shoestring, :dispatch_effect)
      inherited = [shoestring: Application.get_all_env(:shoestring)]
      Application.put_all_env(Config.Reader.merge(inherited, runtime))
      config = Application.fetch_env!(:shoestring, Repo)

      Application.put_env(
        :shoestring,
        Repo,
        Keyword.put(config, :pool, DBConnection.ConnectionPool)
      )

      assert {:ok, _} = Application.ensure_all_started(:shoestring)
      :ok
    end

    test "runtime-configured durable delivery executes the submitted Fake run" do
      {:ok, view, _} = live(build_conn(), "/runs/new")
      view |> element("#btn-use-fixture") |> render_click()

      {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
        view
        |> form("#manual-run-form", %{
          "run" => %{"prompt" => "Runtime configured Fake delivery", "scenario" => "success"}
        })
        |> render_submit()

      try do
        run = Repo.get!(RunRecord, run_id)
        assert run.status == "requested"
        assert Shoestring.Elves.whereis(run_id) == nil
        dispatch = Repo.get_by!(DispatchRecord, run_id: run.id)
        drained = Oban.drain_queue(queue: :dispatch, with_scheduled: true)
        assert Repo.get!(DispatchRecord, dispatch.dispatch_id).status == "effect_completed"
        assert drained.success == 1
        assert drained.cancelled == 0

        case Shoestring.Elves.whereis(run_id) do
          nil ->
            :ok

          pid ->
            ref = Process.monitor(pid)
            assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
        end

        assert Repo.get!(RunRecord, run_id).status == "completed"

        running =
          Repo.one!(
            from e in TrajectoryEvent, where: e.run_id == ^run_id and e.type == "run.running"
          )

        "pgid:" <> pgid = running.payload["process_id"]
        assert Shoestring.Test.ElvesHelpers.group_members(String.to_integer(pgid)) == []
        {:ok, goal_view, _} = live(build_conn(), "/cobbler/goals/#{run.goal_id}")
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
  else
    for mode <- [:dev, :prod] do
      @tag timeout: 120_000
      test "#{mode} runtime entry on an isolated local node" do
        mode = unquote(mode)
        root = Path.join(File.cwd!(), ".shoestring/runtime-entry-#{mode}-#{Ecto.UUID.generate()}")

        {output, status} =
          System.cmd(
            "python3",
            [
              "-c",
              "import subprocess, sys; result = subprocess.run(['mix', 'test', sys.argv[1], '--seed', '0'], stdin=subprocess.DEVNULL, timeout=90); sys.exit(result.returncode)",
              "test/shoestring_web/live/runtime_dispatch_entry_test.exs"
            ],
            env: [
              {"SHOESTRING_RUNTIME_ENTRY_CHILD", "1"},
              {"SHOESTRING_RUNTIME_ENTRY_ENV", Atom.to_string(mode)},
              {"SHOESTRING_TEST_STATE_DIR", root},
              {"SHOESTRING_STATE_DIR", root},
              {"PHX_SERVER", ""},
              {"SECRET_KEY_BASE", String.duplicate("hermetic-fixture-", 8)}
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "1 test, 0 failures"
      end
    end

    test "normal test runtime does not globally configure provider execution" do
      config = Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
      refute Keyword.has_key?(config[:shoestring], :dispatch_effect)
    end
  end
end
