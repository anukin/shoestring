defmodule Mix.Tasks.Shoestring.Measurements do
  use Mix.Task
  @shortdoc "Rebuild and inspect privacy-safe run measurements; no providers are started"
  @moduledoc """
      mix shoestring.measurements report [--split-at ISO8601]
      mix shoestring.measurements rebuild [--split-at ISO8601]
      mix shoestring.measurements export PATH [--split-at ISO8601]
      mix shoestring.measurements delete --confirm

  Report/rebuild/export read a consistent canonical event snapshot. Rebuild
  replaces only the derived cache in the state directory. Export creates a
  private file and refuses to overwrite existing files. The optional split
  timestamp assigns finished runs by the availability of their latest source
  evidence to train or evaluation (never only their finish timestamp);
  unfinished runs belong to neither. No implicit current-time split is used.

  Delete requires --confirm and removes only the derived cache, never the
  trajectory or an export. Rebuilding can regenerate it. Delete an exported
  copy separately using your ordinary file-management tools. Historical events
  still retain their original data; this is not source-history erasure.

  Version 1 cannot establish external-session isolation. All consumption labels
  are unassignable, all training eligibility is false, and routing is unchanged.
  Reports state missingness instead of deriving model/task/repository features
  from prompts or the current checkout. No provider CLI or network is used.
  """
  alias Shoestring.Measurement

  @impl true
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [split_at: [:string, :keep], confirm: [:boolean, :keep]])

    with true <- invalid == [],
         true <- length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))),
         {:ok, opts} <- options(options),
         true <- valid?(positional, options) do
      result =
        case positional do
          ["delete"] -> Measurement.delete_cache(confirm: options[:confirm] == true)
          _ -> Shoestring.CLI.Repository.with_repo(fn _ -> execute(positional, opts) end)
        end

      case result do
        :ok ->
          Mix.shell().info(
            "Derived measurement cache deleted; canonical history and exports retained."
          )

        {:ok, output} ->
          Mix.shell().info(Jason.encode!(output, pretty: true))

        {:error, reason} ->
          Mix.raise("Measurement operation refused: #{reason}")
      end
    else
      _ -> Mix.raise("Invalid arguments. See mix help shoestring.measurements")
    end
  end

  defp execute(["report"], opts), do: Measurement.report(opts)
  defp execute(["rebuild"], opts), do: Measurement.rebuild(opts)
  defp execute(["export", path], opts), do: Measurement.export(path, opts)
  defp valid?(["delete"], opts), do: opts == [confirm: true]

  defp valid?([action], opts) when action in ~w(report rebuild),
    do: Keyword.keys(opts) -- [:split_at] == []

  defp valid?(["export", path], opts), do: path != "" and Keyword.keys(opts) -- [:split_at] == []
  defp valid?(_, _), do: false

  defp options(opts) do
    case opts[:split_at] do
      nil ->
        {:ok, []}

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, time, _} -> {:ok, [split_at: time]}
          _ -> {:error, :invalid_split_timestamp}
        end
    end
  end
end
