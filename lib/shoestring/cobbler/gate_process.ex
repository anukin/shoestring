defmodule Shoestring.Cobbler.GateProcess do
  @moduledoc false
  # Internal argv boundary. PlanGateRunner is responsible for the closed gate registry.
  alias Shoestring.Elves.PortRunner

  def run(argv, worktree, timeout_ms, max_bytes) do
    started = System.monotonic_time(:millisecond)

    with {:ok, runner} <- PortRunner.spawn(argv, cd: worktree, max_output_bytes: max_bytes) do
      try do
        collect(runner, started + timeout_ms, [], 0, max_bytes)
        |> case do
          {:ok, status, output} ->
            {:ok,
             %{
               exit_status: status,
               output: output,
               duration_ms: System.monotonic_time(:millisecond) - started
             }}

          {:error, :timeout} ->
            {:error, {:gate_timeout, %{timeout_ms: timeout_ms}}}

          {:error, {:overflow, bytes}} ->
            {:error, {:gate_output_oversized, %{bytes: bytes}}}
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

  defp collect(%{port: port} = runner, deadline, chunks, bytes, max_bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        total = bytes + byte_size(data)

        if total > max_bytes do
          {:error, {:overflow, total}}
        else
          collect(runner, deadline, [data | chunks], total, max_bytes)
        end

      {^port, {:exit_status, status}} ->
        {:ok, status, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      remaining -> {:error, :timeout}
    end
  end
end
