defmodule Shoestring.Test.ExploreStandIn do
  @moduledoc """
  An explorer for hermetic tests; never a provider. It reports what it was
  given to `opts[:test_pid]` and answers per `opts[:scenario]`: `:report`
  (cites `calc.py:1`, `calc.py:999` and `missing.py:3`), `:write` (edits the
  copy first), `:oversized`, `:progress` (reports 55 steps through
  `opts[:progress]` first) or `{:error, code}`. `:process_group` holds an
  owned process group for the call, as the real explorers do, sends
  `{:explore_group, pgid, self()}` and reports once sent `:release_explore`.
  """
  @behaviour Shoestring.Dispatches.Explore.Adapter

  @impl true
  def explore(input, opts) do
    if pid = opts[:test_pid], do: send(pid, {:explore_input, input})

    case Keyword.get(opts, :scenario, :report) do
      :report ->
        {:ok, %{json: Jason.encode!(report()), output_tokens: 120}}

      :memory_requirement ->
        report = Map.put(report(), "summary", "Preserve signed zero; keep the public API.")
        {:ok, %{json: Jason.encode!(report), output_tokens: 120}}

      :progress ->
        for n <- 1..55, do: opts[:progress].("Ran step #{n}")
        {:ok, %{json: Jason.encode!(report()), output_tokens: 120}}

      :write ->
        File.write!(Path.join(input["workdir"], "calc.py"), "changed\n")
        {:ok, %{json: Jason.encode!(report()), output_tokens: 120}}

      :oversized ->
        summary = String.duplicate("x", 3000)

        findings =
          for i <- 1..30,
              do: %{
                "claim" => String.duplicate("y", 1000) <> "#{i}",
                "evidence" => [%{"path" => "calc.py", "line" => 1}]
              }

        report = %{"summary" => summary, "findings" => findings, "open_questions" => []}

        {:ok,
         %{json: Jason.encode!(report) <> String.duplicate(" ", 40_000), output_tokens: 7000}}

      :process_group ->
        {:ok, runner} = Shoestring.Elves.PortRunner.spawn(["sleep", "60"], cd: input["workdir"])
        send(opts[:test_pid], {:explore_group, runner.pgid, self()})

        receive do
          :release_explore -> :ok
        after
          30_000 -> :ok
        end

        _ = Shoestring.Elves.PortRunner.terminate(runner)
        Shoestring.Elves.PortRunner.close(runner)
        {:ok, %{json: Jason.encode!(report()), output_tokens: 120}}

      {:error, code} ->
        {:error, code}
    end
  end

  defp report do
    %{
      "summary" => "add() raises NotImplementedError; the test expects a sum.",
      "findings" => [
        %{
          "claim" => "add() is not implemented",
          "evidence" => [%{"path" => "calc.py", "line" => 1}, %{"path" => "calc.py", "line" => 2}]
        },
        %{
          "claim" => "A line past the end",
          "evidence" => [%{"path" => "calc.py", "line" => 999}]
        },
        %{
          "claim" => "A file that is not there",
          "evidence" => [%{"path" => "missing.py", "line" => 3}]
        }
      ],
      "open_questions" => ["Should add() accept floats? api_key=sk-test-1234567890"]
    }
  end
end
