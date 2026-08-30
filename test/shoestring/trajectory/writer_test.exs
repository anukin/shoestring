defmodule Shoestring.Trajectory.WriterTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Trajectory.{AppendInput, Writer}

  test "a writer's retry policy is bounded and does not sleep" do
    attempts = :counters.new(1, [])
    goal_id = Ecto.UUID.generate()

    attempt_fun = fn _input, _state ->
      :counters.add(attempts, 1, 1)
      {:error, :busy}
    end

    pid =
      start_supervised!({
        Writer,
        goal_id: goal_id, idle_timeout: :infinity, max_retries: 2, attempt_fun: attempt_fun
      })

    input = %AppendInput{
      type: "decision.recorded",
      schema_version: 1,
      actor: "system",
      payload: %{"decision" => "continue"}
    }

    assert {:error, {:retry_exhausted, :busy}} = GenServer.call(pid, {:append, input})
    assert :counters.get(attempts, 1) == 3
  end

  test "a sequence conflict uses the same bounded retry policy" do
    attempts = :counters.new(1, [])
    goal_id = Ecto.UUID.generate()

    attempt_fun = fn _input, _state ->
      :counters.add(attempts, 1, 1)
      {:error, :sequence_conflict}
    end

    pid =
      start_supervised!({
        Writer,
        goal_id: goal_id, idle_timeout: :infinity, max_retries: 1, attempt_fun: attempt_fun
      })

    input = %AppendInput{
      type: "decision.recorded",
      schema_version: 1,
      actor: "system",
      payload: %{"decision" => "continue"}
    }

    assert {:error, {:retry_exhausted, :sequence_conflict}} =
             GenServer.call(pid, {:append, input})

    assert :counters.get(attempts, 1) == 2
  end

  test "a stopped idle writer is removed cleanly from its registry" do
    goal_id = Ecto.UUID.generate()
    pid = start_supervised!({Writer, goal_id: goal_id, idle_timeout: :infinity})
    assert [{^pid, _value}] = Registry.lookup(Shoestring.Trajectory.WriterRegistry, goal_id)

    ref = Process.monitor(pid)
    _ = :sys.get_state(pid)
    send(pid, :idle_timeout)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert GenServer.whereis(Writer.via(goal_id)) == nil
  end
end
