defmodule Shoestring.Cobbler.Review.Fixture do
  @moduledoc """
  A deterministic reviewer for hermetic tests and rehearsals; never a
  provider. Every line the diff adds that contains `REVIEW-DEFECT:` becomes a
  blocking finding at that file and line (the text after the marker is the
  claim); anything else is approved. `opts[:fixture_fun]` (an internal test
  seam) replaces the rule with `fun.(packet) :: {:ok, json} | {:error, atom}`.
  """
  @behaviour Shoestring.Cobbler.Review.Adapter

  @marker "REVIEW-DEFECT:"

  def marker, do: @marker

  @impl true
  def review(input, opts) do
    packet = Jason.decode!(input["packet_json"])

    case Keyword.get(opts, :fixture_fun) do
      fun when is_function(fun, 1) ->
        with {:ok, json} <- fun.(packet), do: {:ok, %{json: json, output_tokens: 0}}

      nil ->
        {:ok, %{json: Jason.encode!(rule(packet)), output_tokens: 0}}
    end
  end

  defp rule(packet) do
    findings =
      packet["diff"]
      |> added_lines()
      |> Enum.filter(fn {_path, _line, text} -> String.contains?(text, @marker) end)
      |> Enum.take(20)
      |> Enum.with_index(1)
      |> Enum.map(fn {{path, line, text}, index} ->
        claim = text |> String.split(@marker, parts: 2) |> List.last() |> String.trim()

        %{
          "id" => "F#{index}",
          "severity" => "blocking",
          "path" => path,
          "line" => line,
          "claim" => String.slice(if(claim == "", do: "Seeded defect.", else: claim), 0, 1000),
          "evidence" => "The added line carries the seeded review marker.",
          "violates" => "task acceptance criteria",
          "correction" => "Remove the seeded defect.",
          "confidence" => "high"
        }
      end)

    %{
      "verdict" => if(findings == [], do: "approve", else: "request_changes"),
      "summary" => "Fixture review: #{length(findings)} seeded defect(s).",
      "findings" => findings
    }
  end

  # {path, new-file line number, text} for every added line of a unified diff.
  defp added_lines(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({nil, 0, []}, fn line, {path, number, acc} ->
      cond do
        String.starts_with?(line, "+++ b/") ->
          {String.replace_prefix(line, "+++ b/", ""), 0, acc}

        String.starts_with?(line, "+++ ") ->
          {nil, 0, acc}

        String.starts_with?(line, "@@ ") ->
          case Regex.run(~r/\+(\d+)/, line) do
            [_, start] -> {path, String.to_integer(start), acc}
            _ -> {path, number, acc}
          end

        String.starts_with?(line, "+") and path != nil ->
          {path, number + 1, [{path, number, String.slice(line, 1..-1//1)} | acc]}

        String.starts_with?(line, "-") ->
          {path, number, acc}

        true ->
          {path, number + 1, acc}
      end
    end)
    |> elem(2)
    |> Enum.reverse()
  end
end
