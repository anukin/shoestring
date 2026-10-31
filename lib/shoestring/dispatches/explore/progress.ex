defmodule Shoestring.Dispatches.Explore.Progress do
  @moduledoc """
  What an explorer does while it runs, as short steps for the person: each
  command Codex runs, each file Claude reads or search it makes. Steps are
  read from the CLI's output as it arrives (`feed/4`), redacted and bounded
  to #{200} characters, and handed to a `report` function; the result never
  depends on them.
  """

  alias Shoestring.Trajectory.Redaction

  @max_line 200

  @doc """
  Adds `chunk` of output to the incomplete line `pending`, reports the steps
  of every complete line through `report`, and returns the new incomplete
  line. With no `report`, it keeps nothing.
  """
  def feed(_pending, _chunk, _steps, nil), do: ""

  def feed(pending, chunk, steps, report) do
    {complete, [rest]} = (pending <> chunk) |> String.split("\n") |> Enum.split(-1)

    for line <- complete,
        String.starts_with?(line, "{"),
        {:ok, %{} = frame} <- [Jason.decode(line)],
        step <- steps.(frame),
        do: report.(bound(step))

    rest
  end

  @doc "The steps of a `codex exec --json` frame: a command it starts."
  def codex(%{
        "type" => "item.started",
        "item" => %{"type" => "command_execution", "command" => command}
      })
      when is_binary(command),
      do: ["Ran " <> command]

  def codex(_frame), do: []

  @doc "The steps of a Claude stream-json frame: each tool it uses, with its target."
  def claude(%{"type" => "assistant", "message" => %{"content" => blocks}})
      when is_list(blocks) do
    for %{"type" => "tool_use", "name" => name} = block <- blocks, is_binary(name) do
      input = block["input"] || %{}

      case Enum.find_value(~w(file_path pattern path), &string(input[&1])) do
        nil -> name
        target -> "#{name} #{target}"
      end
    end
  end

  def claude(_frame), do: []

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp bound(step) do
    step = step |> Redaction.redact() |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(step) > @max_line,
      do: String.slice(step, 0, @max_line - 1) <> "…",
      else: step
  end
end
