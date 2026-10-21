defmodule Mix.Tasks.Shoestring.Diagnostics do
  use Mix.Task
  @shortdoc "Preview sanitized diagnostics and explicitly confirm their exact export bytes"
  @moduledoc """
      mix shoestring.diagnostics preview [--goal UUID] [--limit 1..200]
      mix shoestring.diagnostics export PATH --confirm SHA256 [--goal UUID] [--limit 1..200]

  Preview prints the full sanitized bundle and its manifest without writing an
  export. Review both, then supply confirmation_sha256 to export with the same
  selection. Export regenerates the preview; changed bytes require a new preview
  and confirmation. No provider CLI, authentication file or network is used.
  The local output is private (0600), created exclusively, and never uploaded.

  This is a deliberately lossy diagnostic projection, not replayable history.
  Prompts, source, raw output, original identifiers/paths, unlisted configuration
  and free text are excluded. Versions/tiers are historical selected event
  metadata; authentication and helper execution are not probed. Selection is
  bounded to the newest 200 events with explicit omitted counts. Oversized
  selected source or exports are refused, not silently truncated.
  """
  @impl true
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [goal: [:string, :keep], limit: [:integer, :keep], confirm: [:string, :keep]]
      )

    valid = invalid == [] and length(options) == length(Enum.uniq(Keyword.keys(options)))
    selection = Keyword.take(options, [:goal, :limit])

    operation =
      case {valid, positional, options[:confirm]} do
        {true, ["preview"], nil} ->
          fn -> Shoestring.Diagnostics.preview(selection) end

        {true, ["export", path], confirmation} when is_binary(confirmation) ->
          fn -> Shoestring.Diagnostics.export(path, confirmation, selection) end

        _ ->
          Mix.raise("Invalid arguments. See mix help shoestring.diagnostics")
      end

    case Shoestring.CLI.Repository.with_existing_repo(fn _ -> operation.() end) do
      {:ok, preview} -> Mix.shell().info(Jason.encode!(preview, pretty: true))
      {:error, reason} -> Mix.raise("Diagnostics refused: #{reason}")
    end
  end
end
