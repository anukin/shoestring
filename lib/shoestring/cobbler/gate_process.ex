defmodule Shoestring.Cobbler.GateProcess do
  @moduledoc false
  # Internal argv boundary. PlanGateRunner is responsible for the closed gate registry.
  alias Shoestring.Elves.PortRunner

  # The command is already stopped when this grace period starts. Retain
  # buffered partial output on failed gates without waiting on a stuck sink.
  @failed_sink_drain_ms 500

  def run(argv, worktree, timeout_ms, max_bytes, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    deadline = started + timeout_ms

    with {:ok, sink} <- start_sink(opts[:output_sink]) do
      try do
        with {:ok, runner} <- PortRunner.spawn(argv, cd: worktree, max_output_bytes: max_bytes) do
          result =
            try do
              collect(runner, deadline, [], 0, max_bytes, sink)
            after
              # Stop the owned command before waiting for persistence. A slow
              # disk or database must not extend its execution or output cap.
              _ = PortRunner.terminate(runner, kill_grace_ms: 100, reap_timeout_ms: 100)
              _ = PortRunner.killpg(runner, "KILL")
              PortRunner.close(runner)
            end

          case finish_sink(sink, result, deadline) do
            {:ok, status, output} ->
              {:ok,
               %{
                 exit_status: status,
                 output: output,
                 duration_ms: System.monotonic_time(:millisecond) - started
               }}

            {:error, {:timeout, partial}} ->
              {:error, {:gate_timeout, %{timeout_ms: timeout_ms, partial_output: partial}}}

            {:error, {:overflow, bytes, partial}} ->
              {:error, {:gate_output_oversized, %{bytes: bytes, partial_output: partial}}}

            {:error, _reason} = error ->
              error
          end
        end
      after
        stop_sink(sink)
      end
    end
  end

  defp collect(%{port: port} = runner, deadline, chunks, bytes, max_bytes, sink) do
    remaining = remaining(deadline)
    ref = if sink, do: sink.task.ref, else: make_ref()

    if remaining == 0 do
      {:error, {:timeout, joined(chunks)}}
    else
      receive do
        {^port, {:data, data}} ->
          total = bytes + byte_size(data)

          if total > max_bytes do
            kept = binary_part(data, 0, max_bytes - bytes)

            queue_output(sink, kept)
            {:error, {:overflow, total, joined([kept | chunks])}}
          else
            queue_output(sink, data)
            collect(runner, deadline, [data | chunks], total, max_bytes, sink)
          end

        {^port, {:exit_status, status}} ->
          {:ok, status, joined(chunks)}

        {^ref, {:error, reason}} ->
          {:error, {:gate_output_failed, reason}}

        {^ref, _unexpected} ->
          {:error, {:gate_output_failed, :sink_stopped}}

        {:DOWN, ^ref, :process, _pid, _reason} ->
          {:error, {:gate_output_failed, :sink_stopped}}
      after
        remaining -> {:error, {:timeout, joined(chunks)}}
      end
    end
  end

  defp start_sink(nil), do: {:ok, nil}

  defp start_sink({callback, state}) do
    caller = self()
    tag = make_ref()

    task =
      Task.Supervisor.async_nolink(Shoestring.Cobbler.GateOutputTasks, fn ->
        monitor = Process.monitor(caller)
        sink_loop(tag, monitor, callback, state)
      end)

    {:ok, %{task: task, tag: tag}}
  catch
    :exit, _reason -> {:error, {:gate_output_failed, :sink_unavailable}}
  end

  defp sink_loop(tag, monitor, callback, state) do
    receive do
      {^tag, event} ->
        case callback.(event, state) do
          {:ok, _state} when event == :eof -> :ok
          {:ok, state} -> sink_loop(tag, monitor, callback, state)
          {:error, reason} -> {:error, reason}
        end

      {:DOWN, ^monitor, :process, _caller, _reason} ->
        :ok
    end
  end

  defp queue_output(nil, _data), do: :ok
  defp queue_output(_sink, ""), do: :ok
  defp queue_output(sink, data), do: send(sink.task.pid, {sink.tag, {:data, data}})

  defp finish_sink(nil, result, _deadline), do: result
  defp finish_sink(_sink, {:error, {:gate_output_failed, _}} = result, _deadline), do: result

  defp finish_sink(sink, result, deadline) do
    send(sink.task.pid, {sink.tag, :eof})

    drain_ms =
      if match?({:error, _}, result), do: @failed_sink_drain_ms, else: remaining(deadline)

    case Task.yield(sink.task, drain_ms) do
      {:ok, :ok} ->
        result

      nil ->
        case result do
          {:ok, _status, output} -> {:error, {:timeout, output}}
          error -> error
        end

      {:ok, {:error, reason}} ->
        sink_failure(result, reason)

      {:exit, _reason} ->
        sink_failure(result, :sink_stopped)
    end
  end

  defp sink_failure({:ok, _status, _output}, reason), do: {:error, {:gate_output_failed, reason}}
  defp sink_failure(error, _reason), do: error

  defp stop_sink(nil), do: :ok

  defp stop_sink(sink) do
    _ = Task.Supervisor.terminate_child(Shoestring.Cobbler.GateOutputTasks, sink.task.pid)
    Process.demonitor(sink.task.ref, [:flush])
    ref = sink.task.ref

    receive do
      {^ref, _result} -> :ok
    after
      0 -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp joined(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()
end
