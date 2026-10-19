defmodule Shoestring.Cobbler.GateProcess do
  @moduledoc false
  # Internal argv boundary. PlanGateRunner is responsible for the closed gate registry.
  alias Shoestring.Elves.PortRunner

  def run(argv, worktree, timeout_ms, max_bytes, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, runner} <- PortRunner.spawn(argv, cd: worktree, max_output_bytes: max_bytes) do
      try do
        collect(runner, started + timeout_ms, [], 0, max_bytes, opts[:output_sink])
        |> case do
          {:ok, status, output} ->
            {:ok,
             %{
               exit_status: status,
               output: output,
               duration_ms: System.monotonic_time(:millisecond) - started
             }}

          # What arrived before the bound is kept, at most max_bytes, so the
          # failure can be inspected; callers keep it out of reason strings.
          {:error, {:timeout, partial}} ->
            {:error, {:gate_timeout, %{timeout_ms: timeout_ms, partial_output: partial}}}

          {:error, {:overflow, bytes, partial}} ->
            {:error, {:gate_output_oversized, %{bytes: bytes, partial_output: partial}}}

          {:error, _reason} = error ->
            error
        end
      after
        # Also terminates owned descendants that outlive the command's direct child.
        _ = PortRunner.terminate(runner, kill_grace_ms: 100, reap_timeout_ms: 100)
        # A descendant can ignore TERM even when the direct child exits promptly.
        _ = PortRunner.killpg(runner, "KILL")
        PortRunner.close(runner)
      end
    end
  end

  defp collect(%{port: port} = runner, deadline, chunks, bytes, max_bytes, sink) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        total = bytes + byte_size(data)

        if total > max_bytes do
          kept = binary_part(data, 0, max_bytes - bytes)

          with {:ok, sink} <- deliver(sink, {:data, kept}) do
            finish(sink, {:error, {:overflow, total, joined([kept | chunks])}})
          end
        else
          with {:ok, sink} <- deliver(sink, {:data, data}) do
            collect(runner, deadline, [data | chunks], total, max_bytes, sink)
          end
        end

      {^port, {:exit_status, status}} ->
        finish(sink, {:ok, status, joined(chunks)})
    after
      remaining -> finish(sink, {:error, {:timeout, joined(chunks)}})
    end
  end

  defp finish(sink, result) do
    with {:ok, _sink} <- deliver(sink, :eof), do: result
  end

  defp deliver(nil, _event), do: {:ok, nil}

  defp deliver({callback, state}, event) do
    case callback.(event, state) do
      {:ok, state} -> {:ok, {callback, state}}
      {:error, reason} -> {:error, {:gate_output_failed, reason}}
    end
  end

  defp joined(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()
end
