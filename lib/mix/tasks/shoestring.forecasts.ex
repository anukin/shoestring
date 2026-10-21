defmodule Mix.Tasks.Shoestring.Forecasts do
  use Mix.Task
  @shortdoc "Report chronological shadow forecasts without changing dispatch"
  @moduledoc """
      mix shoestring.forecasts report --split-at ISO8601 --at ISO8601

  Builds fresh measurements, then reports empirical 99% upper intervals and
  held-out coverage or an explicit static fallback. Requires 100 attributable
  training and 100 later evaluation rows per fully versioned class. Evidence
  at/after --at is unavailable. There is no implicit wall clock and no enable
  switch. Historical v1 measurements have no assignable consumption labels,
  so the current local dataset always falls back. Reports do not change
  admission, reservations or execution, even if a synthetic cohort calibrates.
  No providers, application workers or network calls are started.
  """
  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [split_at: [:string, :keep], at: [:string, :keep]])

    with ["report"] <- positional,
         [] <- invalid,
         true <- Enum.sort(Keyword.keys(opts)) == [:at, :split_at],
         {:ok, split, _} <- DateTime.from_iso8601(opts[:split_at]),
         {:ok, at, _} <- DateTime.from_iso8601(opts[:at]),
         :lt <- DateTime.compare(split, at) do
      Shoestring.CLI.Repository.with_repo(fn _ ->
        case Shoestring.Measurement.snapshot(split_at: split) do
          {:ok, dataset} ->
            Mix.shell().info(
              Jason.encode!(Shoestring.Forecast.Shadow.report(dataset, at), pretty: true)
            )

          {:error, reason} ->
            Mix.raise("Shadow report refused: #{reason}")
        end
      end)
    else
      _ -> Mix.raise("Invalid arguments. See mix help shoestring.forecasts")
    end
  end
end
