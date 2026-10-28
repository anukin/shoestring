defmodule Mix.Tasks.Test.Partitioned do
  @shortdoc "Runs the ExUnit suite as concurrent partitions"

  @moduledoc """
  Runs `mix test --partitions N` as N concurrent OS processes, one per
  `MIX_TEST_PARTITION`, so the synchronous database tests no longer run one
  file after another in a single VM. Each partition already gets its own state
  root and SQLite database (`config/runtime.exs`).

  Prints each partition's exit status, seed and counts, then the summed
  counts. A failed partition's whole output is printed with the command that
  reproduces it, and the task raises when any partition fails.

      mix test.partitioned
      mix test.partitioned --partitions 4

  ExUnit assigns test files to partitions by hash, so the same file always
  lands in the same partition for a given N.
  """

  use Mix.Task

  @default_partitions 8
  @count_keys ~w(doctests tests failures invalid skipped excluded)

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: [partitions: :integer])
    total = Keyword.get(opts, :partitions, @default_partitions)
    if total < 1, do: Mix.raise("--partitions must be a positive integer")

    mix = System.find_executable("mix") || Mix.raise("mix executable not found on PATH")
    started = System.monotonic_time(:millisecond)

    results =
      1..total
      |> Task.async_stream(&run_partition(mix, &1, total),
        max_concurrency: total,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> report_finished(result, total) end)
      |> Enum.sort_by(& &1.partition)

    wall = System.monotonic_time(:millisecond) - started
    failed = Enum.filter(results, &failed?/1)

    Enum.each(failed, &report_failure(&1, total))

    Mix.shell().info(
      "#{total} partitions in #{seconds(wall)}: " <> format_counts(sum_counts(results))
    )

    if failed != [] do
      Mix.raise(
        "Test partition(s) failed: " <>
          Enum.map_join(failed, ", ", &"#{&1.partition}/#{total}")
      )
    end
  end

  defp run_partition(mix, partition, total) do
    started = System.monotonic_time(:millisecond)

    {output, status} =
      System.cmd(mix, ["test", "--partitions", Integer.to_string(total)],
        env: [{"MIX_ENV", "test"}, {"MIX_TEST_PARTITION", Integer.to_string(partition)}],
        stderr_to_stdout: true
      )

    %{
      partition: partition,
      status: status,
      output: output,
      elapsed: System.monotonic_time(:millisecond) - started,
      seed: seed(output),
      counts: counts(output)
    }
  end

  defp report_finished(result, total) do
    counts = if result.counts, do: format_counts(result.counts), else: "no ExUnit summary"

    Mix.shell().info(
      "partition #{result.partition}/#{total}: exit #{result.status} in " <>
        "#{seconds(result.elapsed)}, seed #{result.seed || "?"}: #{counts}"
    )

    result
  end

  # A partition that exits 0 without printing ExUnit's summary did not run the
  # suite it was given, so it counts as failed too.
  defp failed?(%{status: status, counts: counts}), do: status != 0 or is_nil(counts)

  defp report_failure(result, total) do
    seed = if result.seed, do: " --seed #{result.seed}", else: ""

    Mix.shell().error("""

    ==> partition #{result.partition}/#{total} output
    #{result.output}
    ==> reproduce with: MIX_TEST_PARTITION=#{result.partition} mix test --partitions #{total}#{seed}
    """)
  end

  defp seed(output) do
    case Regex.run(~r/Running ExUnit with seed: (\d+)/, output) do
      [_, seed] -> seed
      nil -> nil
    end
  end

  # ExUnit's summary line, e.g. "4 doctests, 312 tests, 0 failures, 1 skipped (6 excluded)".
  defp counts(output) do
    case Regex.scan(~r/^.*\d+ tests?, \d+ failures?.*$/m, output) |> List.last() do
      [line] ->
        for [_, n, key] <-
              Regex.scan(~r/(\d+) (doctest|test|failure|invalid|skipped|excluded)/, line),
            into: %{},
            do: {normalize(key), String.to_integer(n)}

      nil ->
        nil
    end
  end

  defp normalize(key) when key in ~w(skipped excluded invalid), do: key
  defp normalize(key), do: key <> "s"

  defp sum_counts(results) do
    results
    |> Enum.map(&(&1.counts || %{}))
    |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _key, a, b -> a + b end))
  end

  defp format_counts(counts) do
    @count_keys
    |> Enum.filter(&(Map.get(counts, &1, 0) > 0 or &1 in ~w(tests failures)))
    |> Enum.map_join(", ", &"#{Map.get(counts, &1, 0)} #{&1}")
  end

  defp seconds(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
