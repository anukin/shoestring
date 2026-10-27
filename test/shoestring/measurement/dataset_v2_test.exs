defmodule Shoestring.Measurement.DatasetV2Test do
  @moduledoc """
  Builds canonical history through the real plan, dispatch, collection and
  bracket paths with injected times and readings. No provider, monitor or
  network is started.
  """
  use Shoestring.DataCase, async: false
  alias Shoestring.{Advice, AgentProfiles, Cobbler, Measurement, Trajectory}
  alias Shoestring.Dispatches.{Call, Dispatch}
  alias Shoestring.Grants.Grant
  alias Shoestring.Harness.Capacity
  alias Shoestring.Harness.Capacity.Fixtures
  alias Shoestring.Measurement.{Brackets, Collection, DatasetV2}
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Trajectory.TrajectoryEvent
  import Shoestring.Test.PlanExecutorHelpers

  # `run.requested` is stamped by the system clock, so the timeline is
  # anchored to real time for each test.
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous_state = System.get_env("SHOESTRING_TEST_STATE_DIR")
    previous_reader = Application.get_env(:shoestring, :measurement_capacity_reader)
    previous_clock = Application.get_env(:shoestring, :dispatch_clock)
    System.put_env("SHOESTRING_TEST_STATE_DIR", dir)
    Process.put(:base, %{DateTime.truncate(DateTime.utc_now(), :second) | microsecond: {0, 6}})
    start_supervised!({Shoestring.Test.HermeticLifecycleClock, now: at(0)})
    Application.put_env(:shoestring, :dispatch_clock, Shoestring.Test.HermeticLifecycleClock)

    on_exit(fn ->
      if previous_state,
        do: System.put_env("SHOESTRING_TEST_STATE_DIR", previous_state),
        else: System.delete_env("SHOESTRING_TEST_STATE_DIR")

      if previous_reader,
        do: Application.put_env(:shoestring, :measurement_capacity_reader, previous_reader),
        else: Application.delete_env(:shoestring, :measurement_capacity_reader)

      if previous_clock,
        do: Application.put_env(:shoestring, :dispatch_clock, previous_clock),
        else: Application.delete_env(:shoestring, :dispatch_clock)
    end)

    Application.put_env(:shoestring, :measurement_capacity_reader, fn "codex" ->
      {at, used} = Process.get(:next_reading)
      reading(at, used)
    end)

    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{
        "codex_models" => "fixture-model-v1",
        "claude_models" => "default fixture-claude"
      })

    roles = [
      %{"name" => "Coordinator", "provider" => "claude", "model" => "default"},
      %{
        "name" => "Worker",
        "provider" => "codex",
        "model" => "fixture-model-v1",
        "effort" => "high"
      }
    ]

    {:ok, agent} =
      AgentProfiles.create(Shoestring.ConfigurationFixtures.agent_attrs(%{"roles" => roles}))

    {:ok, snapshot} = AgentProfiles.snapshot_by_id(agent.id)

    %{
      profile: Map.put(Map.take(snapshot, ["profile_id", "revision", "digest"]), "role", "Worker")
    }
  end

  defp reading(at, used) do
    fixture =
      Fixtures.load_fixture!("codex/normal-read-0.163.0-live.json")
      |> put_in(["payload", "result", "rateLimits", "primary", "usedPercent"], used)
      # Both windows reset after every reading in a test.
      |> put_in(["payload", "result", "rateLimits", "primary", "resetsAt"], unix(18_000))
      |> put_in(["payload", "result", "rateLimits", "secondary", "resetsAt"], unix(604_800))

    Capacity.normalize(:codex, :app_server_stdio, fixture,
      version: "0.163.0",
      now: at,
      captured_at: at,
      source_event: :explicit_read
    )
  end

  defp at(seconds), do: DateTime.add(Process.get(:base), seconds, :second)
  defp unix(seconds), do: DateTime.to_unix(at(seconds))

  defp start_goal!(c, tasks \\ 1) do
    goal = CobblerHelpers.create_goal!()

    plan =
      if tasks == 1,
        do:
          chain_plan(%{
            "tasks" => [Shoestring.Test.PlanFixtures.task("alpha", "Do the only thing", [])]
          }),
        else: chain_plan()

    revision = propose_and_approve!(goal, plan)
    admission = fresh_admission!(goal)

    {:ok, _} =
      Cobbler.request_plan_execution(
        goal.id,
        %{
          revision_number: revision.revision_number,
          digest: revision.digest,
          admission_event_id: admission.id,
          agent_profile: c.profile
        },
        exec_opts()
      )

    %{goal: goal, admission: admission}
  end

  defp fresh_admission!(goal) do
    original = admit!(goal)

    payload =
      original.payload
      |> put_in(["candidate", "adapter_id"], "codex_app_server_stdio")
      |> Map.put("decision_id", Ecto.UUID.generate())

    CobblerHelpers.append_admission_event!(goal.id, payload)
  end

  # One attempt: dispatch, before reading, run start/finish, after reading,
  # task completion. Times are seconds from the executor fixture clock.
  defp measured_run!(g, timeline, opts \\ []) do
    admission = if opts[:first] == false, do: fresh_admission!(g.goal), else: g.admission
    requested_at = at(timeline.requested)
    Agent.update(Shoestring.Test.HermeticLifecycleClock, fn _ -> requested_at end)

    {:ok, run} =
      Cobbler.advance_plan_execution(
        g.goal.id,
        exec_opts(
          now: requested_at,
          clock: Shoestring.Test.HermeticLifecycleClock,
          admission_event_id: admission.id
        )
      )

    dispatched =
      Repo.one!(
        from e in TrajectoryEvent,
          where:
            e.goal_id == ^g.goal.id and e.type == "cobbler.plan.task.dispatched" and
              fragment("json_extract(?, '$.run_id')", e.payload) == ^run.run_id
      )

    context =
      Brackets.context(
        dispatched.payload["execution_id"],
        dispatched.payload["plan_task_id"],
        dispatched.payload["attempt"]
      )

    if timeline[:before] do
      Process.put(:next_reading, timeline.before)

      assert :recorded =
               Brackets.before(g.goal.id, "codex", "subscription", context,
                 now: elem(timeline.before, 0)
               )
    end

    append_run!(g.goal, run.run_id, "run.running", timeline.started)
    append_run!(g.goal, run.run_id, "run.completed", timeline.finished)

    if timeline[:after] do
      Process.put(:next_reading, timeline.after)
      assert :recorded = Brackets.after_run(g.goal.id, "codex", context)
    end

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(g.goal.id, run.run_id, exec_opts())

    # A finished plan releases the execution claim for the next goal.
    _ = Cobbler.advance_plan_execution(g.goal.id, exec_opts())
    run.run_id
  end

  defp append_run!(goal, run_id, type, seconds) do
    {:ok, _} =
      Trajectory.append(
        goal.id,
        %{
          "type" => type,
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => at(seconds),
          "payload" => %{"run_id" => run_id}
        },
        trusted: [run_id: run_id]
      )
  end

  defp open_window!(seconds \\ -600),
    do: {:ok, _} = Collection.open("codex", "subscription", "operator", now: at(seconds))

  defp dataset!(opts \\ []) do
    assert {:ok, dataset} = Measurement.snapshot(Keyword.put(opts, :dataset_version, 2))
    dataset
  end

  defp row(dataset, run_id), do: Enum.find(dataset["rows"], &(&1["run_id"] == run_id))

  @clean %{requested: 5, before: {nil, 54}, started: 20, finished: 80, after: {nil, 56}}

  defp timeline(overrides \\ %{}) do
    t = Map.merge(@clean, overrides)

    %{
      t
      | before: t.before && {at(elem(t.before, 0) || 10), elem(t.before, 1)},
        after: t.after && {at(elem(t.after, 0) || 90), elem(t.after, 1)}
    }
  end

  test "an attested, tightly bracketed, classified run becomes a calibration example", c do
    open_window!()
    run_id = measured_run!(start_goal!(c), timeline())
    dataset = dataset!()
    row = row(dataset, run_id)

    assert dataset["dataset_version"] == 2
    assert row["model"] == "fixture-model-v1"
    assert row["effort"] == "high"
    assert row["cli_version"] == "0.163.0"
    assert row["adapter_version"] == to_string(Application.spec(:shoestring, :vsn))
    assert row["task_class"] =~ ~r/\Agates:/
    assert row["capacity"]["exclusion_reasons"] == []
    assert row["capacity"]["assignable"]
    assert row["capacity"]["consumption_percent"] == 2
    assert row["capacity"]["consumption_window_minutes"] == 300
    assert row["training_eligible"]
    assert dataset["quality"]["training_eligible_rows"] == 1

    # Rows trace to the bracket, dispatch, revision and window events.
    cited = MapSet.new(row["source_events"], & &1["event_id"])
    assert MapSet.member?(cited, row["capacity"]["before"]["event_id"])
    assert MapSet.member?(cited, row["capacity"]["after"]["event_id"])
    assert Enum.any?(row["source_events"], &(&1["type"] == "measurement.collection.opened"))
    assert Enum.any?(row["source_events"], &(&1["type"] == "cobbler.plan.revision.created"))

    # Prompt text, workspace paths and the raw scope never appear.
    encoded = Jason.encode!(dataset)
    refute encoded =~ "subscription"
    refute encoded =~ "workspace/"
  end

  test "rebuilding yields identical bytes and leaves v1 unchanged", c do
    open_window!()
    measured_run!(start_goal!(c), timeline())
    assert {:ok, first} = Measurement.rebuild(dataset_version: 2)
    bytes = File.read!(Measurement.cache_path(dataset_version: 2))
    assert {:ok, ^first} = Measurement.rebuild(dataset_version: 2)
    assert bytes == File.read!(Measurement.cache_path(dataset_version: 2))

    assert {:ok, v1} = Measurement.snapshot()
    assert v1["dataset_version"] == 1
    assert Enum.all?(v1["rows"], &(&1["training_eligible"] == false))
  end

  test "outside a window no reading is taken and the run stays unassignable", c do
    g = start_goal!(c)
    run_id = measured_run!(g, timeline(%{before: nil, after: nil}))

    context_reads =
      Repo.aggregate(
        from(e in TrajectoryEvent, where: e.goal_id == ^g.goal.id and e.actor == "measurement"),
        :count
      )

    assert context_reads == 0
    assert :skipped = Brackets.before(g.goal.id, "codex", "subscription", "x:y:1", now: at(10))
    capacity = row(dataset!(), run_id)["capacity"]
    refute capacity["assignable"]
    assert "missing_before_reading" in capacity["exclusion_reasons"]
  end

  test "a before reading taken too early is excluded", c do
    open_window!()
    run_id = measured_run!(start_goal!(c), timeline(%{before: {-200, 54}}))

    assert "before_reading_not_immediately_before_run" in row(dataset!(), run_id)["capacity"][
             "exclusion_reasons"
           ]
  end

  test "a before reading taken after the run started is excluded", c do
    open_window!()
    run_id = measured_run!(start_goal!(c), timeline(%{before: {30, 54}}))

    assert "before_reading_not_immediately_before_run" in row(dataset!(), run_id)["capacity"][
             "exclusion_reasons"
           ]
  end

  test "an after reading taken too late is excluded", c do
    open_window!()
    run_id = measured_run!(start_goal!(c), timeline(%{after: {300, 56}}))

    assert "after_reading_not_immediately_after_run" in row(dataset!(), run_id)["capacity"][
             "exclusion_reasons"
           ]
  end

  test "closing a window for external use voids every row in it", c do
    open_window!()
    run_id = measured_run!(start_goal!(c), timeline())
    assert row(dataset!(), run_id)["training_eligible"]
    {:ok, _} = Collection.close("codex", "subscription", "external_use_reported", now: at(5000))
    row = row(dataset!(), run_id)
    refute row["training_eligible"]
    assert "collection_window_external_use_reported" in row["capacity"]["exclusion_reasons"]
  end

  test "overlapping Shoestring runs of the provider exclude each other", c do
    open_window!()
    a = start_goal!(c)
    b = start_goal!(c)
    first = measured_run!(a, timeline())
    second = measured_run!(b, timeline(%{requested: 8, before: {15, 56}, after: {95, 58}}))
    dataset = dataset!()

    for run_id <- [first, second] do
      assert row(dataset, run_id)["overlapping_run_count"] > 0
      assert "concurrent_shoestring_runs" in row(dataset, run_id)["capacity"]["exclusion_reasons"]
    end
  end

  test "an unexplained change between bracketed runs voids the whole window", c do
    open_window!()
    g = start_goal!(c, 2)
    first = measured_run!(g, timeline())

    second =
      measured_run!(
        g,
        timeline(%{
          requested: 195,
          before: {200, 60},
          started: 210,
          finished: 260,
          after: {270, 61}
        }),
        first: false
      )

    dataset = dataset!()

    for run_id <- [first, second] do
      assert "collection_window_unexplained_usage" in row(dataset, run_id)["capacity"][
               "exclusion_reasons"
             ]
    end

    assert dataset["quality"]["windows_with_unexplained_usage"] == 1
    assert dataset["quality"]["training_eligible_rows"] == 0
  end

  test "consistent consecutive runs in one window both remain examples", c do
    open_window!()
    g = start_goal!(c, 2)
    first = measured_run!(g, timeline())

    second =
      measured_run!(
        g,
        timeline(%{
          requested: 195,
          before: {200, 56},
          started: 210,
          finished: 260,
          after: {270, 57}
        }),
        first: false
      )

    dataset = dataset!()
    assert row(dataset, first)["training_eligible"]
    assert row(dataset, second)["training_eligible"]
    assert row(dataset, second)["capacity"]["consumption_percent"] == 1
  end

  test "a role left at provider default effort is missing a class feature", c do
    agent = AgentProfiles.get(c.profile["profile_id"])

    {:ok, edited} =
      AgentProfiles.update(agent, %{
        "roles" => %{
          "0" => %{"name" => "Coordinator", "provider" => "claude", "model" => "default"},
          "1" => %{"name" => "Worker", "provider" => "codex", "model" => "fixture-model-v1"}
        }
      })

    {:ok, snapshot} = AgentProfiles.snapshot_by_id(edited.id)
    profile = Map.put(Map.take(snapshot, ["profile_id", "revision", "digest"]), "role", "Worker")
    open_window!()
    run_id = measured_run!(start_goal!(%{c | profile: profile}), timeline())
    row = row(dataset!(), run_id)
    assert row["effort"] == nil
    assert "missing_class_features" in row["capacity"]["exclusion_reasons"]
    refute row["training_eligible"]
  end

  test "Claude rows can never be assignable" do
    assert DatasetV2.version() == 2
    refute "claude" in Brackets.readable_providers()
  end

  describe "advice's usage share (iteration 14 package I)" do
    test "a measured run's share of its provider's shortest window", c do
      assert Advice.usage_shares(Repo) == {:ok, %{}}
      open_window!()
      run_id = measured_run!(start_goal!(c), timeline())
      # A call that finished before the run's first reading does not overlap it.
      codex_call!(0, 9)

      assert Advice.usage_shares(Repo) ==
               {:ok, %{run_id => %{"percent" => 2, "window_minutes" => 300}}}
    end

    test "a run in an unmeasured goal or a call overlapping the readings excludes the run", c do
      open_window!()
      a = start_goal!(c)
      b = start_goal!(c)
      measured = measured_run!(a, timeline())
      # Goal b holds no bracket reading, so the dataset advice builds never sees it.
      measured_run!(b, timeline(%{requested: 8, before: nil, after: nil}))

      assert "concurrent_shoestring_runs" in row(dataset!(), measured)["capacity"][
               "exclusion_reasons"
             ]

      assert Advice.usage_shares(Repo) == {:ok, %{}}

      later =
        measured_run!(
          start_goal!(c),
          timeline(%{
            requested: 405,
            before: {410, 56},
            started: 420,
            finished: 480,
            after: {490, 58}
          })
        )

      assert {:ok, shares} = Advice.usage_shares(Repo)
      assert Map.keys(shares) == [later]
      codex_call!(450, 500)
      assert Advice.usage_shares(Repo) == {:ok, %{}}
    end

    test "a plan review of the provider counts from its creation until it settles", c do
      open_window!()
      g = start_goal!(c)
      run_id = measured_run!(g, timeline())
      plan_review!(g.goal.id, "approved", -100, 5)
      assert {:ok, %{^run_id => _}} = Advice.usage_shares(Repo)
      plan_review!(g.goal.id, "running", -100, -50)
      assert Advice.usage_shares(Repo) == {:ok, %{}}
    end
  end

  defp plan_review!(goal_id, state, created, updated) do
    Repo.insert!(%Shoestring.Cobbler.Review.Record{
      goal_id: goal_id,
      execution_id: Ecto.UUID.generate(),
      plan_task_id: "alpha",
      attempt: 1,
      run_id: Ecto.UUID.generate(),
      round: 1,
      base_commit: "base",
      commit: "head",
      packet_json: "{}",
      packet_digest: "digest",
      gates: %{},
      configuration: %{"provider_id" => "codex"},
      state: state,
      calls: 1,
      inserted_at: at(created),
      updated_at: at(updated)
    })
  end

  # A finished Codex EXPLORE or REVIEW call between `started` and `finished`.
  defp codex_call!(started, finished) do
    grant =
      Repo.insert!(%Grant{
        session_id: "s1",
        granted_by: "human:operator",
        repository_root: "/repo",
        models: ["codex:fixture-model-v1"],
        purposes: ["review"],
        max_dispatches: 1,
        max_parallel: 1,
        max_total_seconds: 600,
        max_dispatch_seconds: 600
      })

    dispatch =
      Repo.insert!(%Dispatch{
        grant_id: grant.id,
        session_id: "s1",
        request_id: Ecto.UUID.generate(),
        purpose: "review",
        provider: "codex",
        model: "fixture-model-v1",
        title: "Review",
        brief: "REVIEW - check it\n",
        brief_digest: "digest",
        repository_root: "/repo",
        base_revision: "base",
        max_attempts: 1,
        max_duration_seconds: 600,
        plan: %{},
        plan_digest: "digest",
        state: "started"
      })

    Repo.insert!(%Call{
      dispatch_id: dispatch.id,
      state: "completed",
      input_json: "{}",
      input_digest: "digest",
      started_at: at(started),
      finished_at: at(finished)
    })
  end
end
