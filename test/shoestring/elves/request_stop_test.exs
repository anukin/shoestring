defmodule Shoestring.Elves.RequestStopTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Repo
  alias Shoestring.Test.ElvesHelpers

  defmodule FakeSession do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def init(opts) do
      {:ok, %{safe_stop_called: false, opts: opts}}
    end

    def handle_call(:request_safe_stop, _from, state) do
      {:reply, {:ok, :stop_requested}, %{state | safe_stop_called: true}}
    end
  end

  defmodule CrashingSession do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def init(_) do
      {:ok, %{}}
    end

    def handle_call(:request_safe_stop, _from, _state) do
      exit(:simulated_crash)
    end
  end

  setup do
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    request = ElvesHelpers.run_request(goal, task)
    identity = ElvesHelpers.fake_identity()
    {:ok, dispatch, _job} = Shoestring.Harness.Dispatches.enqueue(request, identity)
    run = Repo.get!(Shoestring.Harness.RunRecord, dispatch.run_id)

    {:ok, goal: goal, task: task, run: run, dispatch: dispatch}
  end

  test "returns {:error, :run_not_found} for unknown run_id" do
    unknown_id = Ecto.UUID.generate()
    assert {:error, :run_not_found} = Elves.request_stop(unknown_id)
  end

  test "returns {:ok, :already_terminal} when run has a recorded terminal event", %{
    goal: goal,
    task: task,
    run: run
  } do
    attrs = %{
      "type" => "run.completed",
      "schema_version" => 1,
      "actor" => "elf",
      "occurred_at" => DateTime.utc_now(),
      "idempotency_key" => "term-#{run.id}",
      "payload" => %{"run_id" => run.id}
    }

    assert {:ok, _event} =
             Shoestring.Trajectory.append(goal.id, attrs,
               trusted: [task_id: task.id, run_id: run.id]
             )

    assert {:ok, :already_terminal} = Elves.request_stop(run.id)
  end

  test "returns {:error, :session_not_found} when run is active but no session is found", %{
    run: run
  } do
    assert {:error, :session_not_found} = Elves.request_stop(run.id)
  end

  test "delegates to session pid passed via opts[:session]", %{run: run} do
    session_pid = start_supervised!(FakeSession)

    assert {:ok, :stop_requested} = Elves.request_stop(run.id, session: session_pid)
  end

  test "delegates to session pid looked up via CodexAppServer", %{run: run} do
    session_pid = start_supervised!(FakeSession)
    table = :codex_app_server_sessions

    if :ets.info(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set])
    end

    :ets.insert(table, {run.id, session_pid})

    assert {:ok, :stop_requested} = Elves.request_stop(run.id)
  end

  test "catches session exit and returns {:error, {:session_exit, reason}}", %{run: run} do
    crashing_pid = start_supervised!(CrashingSession)

    assert {:error, {:session_exit, {:simulated_crash, _call_info}}} =
             Elves.request_stop(run.id, session: crashing_pid)
  end
end
