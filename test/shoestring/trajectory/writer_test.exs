defmodule Shoestring.Trajectory.WriterTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Trajectory.{AppendInput, Writer, WriterSupervisor}

  test "a writer's retry policy is bounded and does not sleep" do
    attempts = :counters.new(1, [])
    goal_id = Ecto.UUID.generate()

    attempt_fun = fn _input, _references, _state ->
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

    attempt_fun = fn _input, _references, _state ->
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

  test "the writer persists the validated, sanitized payload" do
    test_pid = self()
    goal_id = Ecto.UUID.generate()

    attempt_fun = fn input, _references, _state ->
      send(test_pid, {:validated_payload, input.payload})
      {:error, :not_retryable}
    end

    pid =
      start_supervised!({
        Writer,
        goal_id: goal_id, idle_timeout: :infinity, attempt_fun: attempt_fun
      })

    input = %AppendInput{
      type: "capacity.snapshot_observed",
      schema_version: 2,
      actor: "system",
      occurred_at: ~U[2026-08-30 12:00:00Z],
      payload: %{
        "snapshot_id" => "11111111-1111-4111-8111-111111111111",
        "contract_version" => 2,
        "capacity_state" => "unknown",
        "windows" => %{
          "items" => [
            %{
              "kind" => "primary",
              "state" => "unknown",
              "reason" => "not_reported",
              "future_field" => "ignored"
            }
          ],
          "future_window_metadata" => "ignored"
        },
        "observed_at" => nil,
        "freshness" => %{"max_age_seconds" => 300},
        "source" => %{
          "adapter_id" => "fixture",
          "provider_id" => "codex",
          "invocation_mode" => "app_server",
          "event" => "none",
          "future_field" => "ignored"
        },
        "scope" => "account",
        "confidence" => "none",
        "support_tier" => "unsupported",
        "compatibility_state" => "degraded",
        "reason" => "not_reported",
        "extensions" => %{},
        "future_field" => "ignored"
      }
    }

    assert {:error, :not_retryable} = GenServer.call(pid, {:append, input})
    assert_receive {:validated_payload, validated_payload}
    refute Map.has_key?(validated_payload, "future_field")
    refute Map.has_key?(validated_payload["source"], "future_field")
    refute Map.has_key?(validated_payload["windows"], "future_window_metadata")
    refute Map.has_key?(hd(validated_payload["windows"]["items"]), "future_field")
  end

  test "a real idle timeout stops and unregisters the writer" do
    goal_id = Ecto.UUID.generate()
    pid = start_supervised!({Writer, goal_id: goal_id, idle_timeout: 0})

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert GenServer.whereis(Writer.via(goal_id)) == nil
  end

  test "concurrent startup resolves to one registered writer" do
    goal_id = Ecto.UUID.generate()

    results =
      Task.async_stream(
        1..20,
        fn _number -> WriterSupervisor.ensure_started(goal_id, idle_timeout: :infinity) end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.to_list()

    pids = for {:ok, {:ok, pid}} <- results, do: pid
    assert length(pids) == 20
    assert Enum.uniq(pids) |> length() == 1
    assert [{pid, _value}] = Registry.lookup(Shoestring.Trajectory.WriterRegistry, goal_id)
    assert hd(pids) == pid
  end
end
