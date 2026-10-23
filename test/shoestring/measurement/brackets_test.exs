defmodule Shoestring.Measurement.BracketsTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.ExecutionAdmission
  alias Shoestring.Harness.{Capacity, Observatory}
  alias Shoestring.Harness.Capacity.Fixtures
  alias Shoestring.Measurement.{Brackets, Collection}
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    previous = Application.get_env(:shoestring, :measurement_capacity_reader)
    test = self()

    Application.put_env(:shoestring, :measurement_capacity_reader, fn provider ->
      send(test, {:read, provider})
      reading(Process.get(:used, 54))
    end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shoestring, :measurement_capacity_reader, previous),
        else: Application.delete_env(:shoestring, :measurement_capacity_reader)
    end)

    {:ok, admitted} = reading(54)
    {:ok, _, _} = Observatory.ingest(admitted)
    goal = CobblerHelpers.create_goal!()

    execution = %{
      execution_id: Ecto.UUID.generate(),
      agent_profile: %{"provider" => "codex", "adapter_id" => "codex_app_server_stdio"}
    }

    task = %{"id" => "alpha", "execution" => %{"max_duration_seconds" => 300}}
    %{goal: goal, execution: execution, task: task}
  end

  defp reading(used) do
    fixture =
      Fixtures.load_fixture!("codex/normal-read-0.163.0-live.json")
      |> put_in(["payload", "result", "rateLimits", "primary", "usedPercent"], used)

    now = DateTime.utc_now()

    Capacity.normalize(:codex, :app_server_stdio, fixture,
      version: "0.163.0",
      now: now,
      captured_at: now,
      source_event: :explicit_read
    )
  end

  defp brackets(goal_id) do
    Repo.all(
      from e in TrajectoryEvent,
        where:
          e.goal_id == ^goal_id and e.type == "capacity.snapshot_observed" and
            e.actor == "measurement",
        order_by: e.sequence
    )
  end

  defp open_window(provider \\ "codex"),
    do:
      Collection.open(provider, "subscription", "operator",
        now: DateTime.add(DateTime.utc_now(), -60, :second)
      )

  test "admission takes no reading outside a collection window", c do
    assert {:ok, _} = ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 1)
    refute_received {:read, _}
    assert brackets(c.goal.id) == []
  end

  test "inside a window an admitted attempt is bracketed before and after", c do
    {:ok, _} = open_window()
    assert {:ok, _} = ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 1)
    assert_received {:read, "codex"}
    context = Brackets.context(c.execution.execution_id, "alpha", 1)

    Process.put(:used, 56)
    assert :recorded = Brackets.after_run(c.goal.id, "codex", context)

    assert [before, after_reading] = brackets(c.goal.id)
    assert before.idempotency_key == "measurement-before:#{context}"
    assert after_reading.idempotency_key == "measurement-after:#{context}"

    for {event, side, used} <- [{before, "before", 54}, {after_reading, "after", 56}] do
      assert event.payload["extensions"]["measurement:bracket"] == side
      assert event.payload["extensions"]["measurement:context"] == context
      assert event.payload["source"]["event"] == "explicit_read"
      assert hd(event.payload["windows"]["items"])["used_percent"] == used
    end

    # Each reading is the goal's own observation, never the Observatory row.
    refute before.payload["snapshot_id"] == after_reading.payload["snapshot_id"]
  end

  test "a retried side keeps its first reading", c do
    {:ok, _} = open_window()
    context = Brackets.context(c.execution.execution_id, "alpha", 1)
    assert :recorded = Brackets.before(c.goal.id, "codex", "subscription", context)
    Process.put(:used, 70)
    assert :recorded = Brackets.before(c.goal.id, "codex", "subscription", context)
    assert [only] = brackets(c.goal.id)
    assert hd(only.payload["windows"]["items"])["used_percent"] == 54
  end

  test "Claude is never read, even inside its own window", c do
    {:ok, _} = open_window("claude")
    context = Brackets.context(c.execution.execution_id, "alpha", 1)
    assert :skipped = Brackets.before(c.goal.id, "claude", "subscription", context)
    assert :skipped = Brackets.after_run(c.goal.id, "claude", context)
    refute_received {:read, _}
  end

  test "an after reading needs a before reading for the same attempt", c do
    {:ok, _} = open_window()
    context = Brackets.context(c.execution.execution_id, "alpha", 1)
    assert :skipped = Brackets.after_run(c.goal.id, "codex", context)
    refute_received {:read, _}
    assert brackets(c.goal.id) == []
  end

  test "a failed reading records nothing and never blocks admission", c do
    {:ok, _} = open_window()
    Application.put_env(:shoestring, :measurement_capacity_reader, fn _ -> raise "boom" end)
    assert {:ok, _} = ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 1)

    Application.put_env(:shoestring, :measurement_capacity_reader, fn _ ->
      {:error, :not_connected}
    end)

    assert {:ok, _} = ExecutionAdmission.admit(c.goal.id, c.execution, c.task, 2)
    assert brackets(c.goal.id) == []
  end

  test "the default reader never starts a provider and refuses Claude" do
    assert {:error, :no_inference_free_observation} = Brackets.codex_read("claude")

    unless Process.whereis(Shoestring.Harness.Capacity.CodexMonitor) do
      assert {:error, :capacity_monitor_unavailable} = Brackets.codex_read("codex")
    end
  end
end
