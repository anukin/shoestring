defmodule Shoestring.Harness.SafeStopSessionLookupTest do
  @moduledoc """
  Regression lock: `Shoestring.Elves.request_stop/2` must find a session
  registered the way the real adapters register one.

  Both production adapters register under `RunIdentity.run_id`, which
  `CodexAppServer.start_session/2` and `ClaudeHeadless` set from
  `request.dispatch_id` — NOT the run row id. `Shoestring.Elves.Elf` already
  documents this ("Sessions register under request.dispatch_id, which differs
  from the run row id on dispatched continuation runs — so look up dispatch
  first, run id second"), and round-4 R4.2 fixed it there.

  `Shoestring.Elves.resolve_session/2`, the safe-stop path, was the unfixed
  twin: it probed `run.id` only. On a dispatched continuation run — exactly
  the runs a wake or a handoff creates, where the dispatch id and the row id
  differ — a safe stop therefore found nothing and reported
  `{:error, :session_not_found}` for a session that was alive and reachable,
  so the operator's stop request silently did nothing.

  ## Lock ledger (base `01f2a54`)

  `"a session registered under the dispatch id is reachable"` is a TRUE
  behavioural lock: on base it fails with `{:error, :session_not_found}`
  where `{:ok, :stop_requested}` is asserted. The run-row-id arm and the
  explicit-resolver arm are DOCUMENTATION — they pass on base and pin the
  behaviour the fix must preserve.

  Hermetic: a local `Agent` stands in for the session registry and a stub
  session server answers the safe-stop call. No provider CLI, no network.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Test.Fixtures.FakeHelpers

  defmodule StubSession do
    @moduledoc "Answers the one safe-stop call `dispatch_safe_stop/2` makes."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test_pid)}

    @impl true
    def handle_call(:request_safe_stop, _from, test_pid) do
      send(test_pid, {:safe_stop_requested, self()})
      {:reply, {:ok, :stop_requested}, test_pid}
    end
  end

  setup do
    goal = FakeHelpers.insert_goal(Ecto.UUID.generate())
    task = FakeHelpers.insert_task(goal, Ecto.UUID.generate())

    run =
      FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate()
      )

    # A dispatched continuation run: the dispatch id and the row id differ.
    # Without that this test would prove nothing.
    refute run.dispatch_id == run.id

    session = start_supervised!({StubSession, test_pid: self()})
    {:ok, goal: goal, run: run, session: session}
  end

  test "a session registered under the dispatch id is reachable", %{run: run, session: session} do
    registry = registry(%{run.dispatch_id => session})

    assert {:ok, :stop_requested} =
             Elves.request_stop(run.id, adapter: :fake, session_resolver: registry)

    assert_receive {:safe_stop_requested, ^session}
  end

  test "a session registered under the run row id is still reachable (DOCUMENTATION)", %{
    run: run,
    session: session
  } do
    registry = registry(%{run.id => session})

    assert {:ok, :stop_requested} =
             Elves.request_stop(run.id, adapter: :fake, session_resolver: registry)

    assert_receive {:safe_stop_requested, ^session}
  end

  test "no registered session reports not-found rather than inventing a stop", %{run: run} do
    assert {:error, :session_not_found} =
             Elves.request_stop(run.id, adapter: :fake, session_resolver: registry(%{}))
  end

  test "an explicit :session_pid still wins over any lookup", %{run: run, session: session} do
    assert {:ok, :stop_requested} =
             Elves.request_stop(run.id, adapter: :fake, session_pid: session)

    assert_receive {:safe_stop_requested, ^session}
  end

  test "the run row's own ids are what get probed, in dispatch-first order", %{run: run} do
    # Both ids are registered to DIFFERENT servers; the dispatch id wins,
    # matching `Elf.lookup_session_ids/2`.
    dispatch_session = start_supervised!({StubSession, test_pid: self()}, id: :dispatch_session)
    row_session = start_supervised!({StubSession, test_pid: self()}, id: :row_session)

    registry = registry(%{run.dispatch_id => dispatch_session, run.id => row_session})

    assert {:ok, :stop_requested} =
             Elves.request_stop(run.id, adapter: :fake, session_resolver: registry)

    assert_receive {:safe_stop_requested, ^dispatch_session}
    refute_receive {:safe_stop_requested, ^row_session}, 50
  end

  test "a run whose dispatch id equals its row id is probed once", %{
    goal: goal,
    session: session
  } do
    shared = Ecto.UUID.generate()
    task = FakeHelpers.insert_task(goal, Ecto.UUID.generate())
    run = FakeHelpers.insert_run_record(goal, task, shared, run_id: shared)
    assert %RunRecord{} = run

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    resolver = fn id ->
      Agent.update(counter, &(&1 + 1))
      if id == shared, do: session, else: nil
    end

    assert {:ok, :stop_requested} =
             Elves.request_stop(run.id, adapter: :fake, session_resolver: resolver)

    assert Agent.get(counter, & &1) == 1
  end

  # A stand-in for the adapter session registry, keyed the way the real ETS
  # tables are keyed.
  defp registry(sessions), do: fn id -> Map.get(sessions, id) end
end
