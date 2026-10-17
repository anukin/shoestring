defmodule Shoestring.Cobbler.Review.Findings do
  @moduledoc """
  The structured result a reviewer must return, and the deterministic rules
  that turn it into a review outcome.

  Every finding names a stable id, a severity (`blocking`, `non_blocking`,
  `suggestion`), an optional file path and line, the claim, its evidence, what
  it violates, the proposed correction and the reviewer's confidence.

  A path the review packet does not contain (neither a changed file nor a
  tracked file at the reviewed commit) is kept but marked `unsupported`, and
  an unsupported finding never blocks. The reviewer's own verdict is recorded
  but does not decide anything: the outcome is `changes_requested` exactly
  when at least one supported blocking finding remains, otherwise `approved`.
  """
  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Harness.Security

  @max_findings 20
  @severities ~w(blocking non_blocking suggestion)
  @confidences ~w(low medium high)
  @text_limits %{"claim" => 1000, "evidence" => 2000, "violates" => 300, "correction" => 2000}

  @doc "The JSON Schema given to the reviewer (strict: every property required)."
  def schema do
    nullable = fn type -> %{"type" => [type, "null"]} end

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["verdict", "summary", "findings"],
      "properties" => %{
        "verdict" => %{"type" => "string", "enum" => ["approve", "request_changes"]},
        "summary" => %{"type" => "string", "maxLength" => 2000},
        "findings" => %{
          "type" => "array",
          "maxItems" => @max_findings,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ~w(id severity path line claim evidence violates correction confidence),
            "properties" => %{
              "id" => %{"type" => "string", "pattern" => "^F[0-9]{1,2}$"},
              "severity" => %{"type" => "string", "enum" => @severities},
              "path" => nullable.("string"),
              "line" => nullable.("integer"),
              "claim" => %{"type" => "string", "maxLength" => 1000},
              "evidence" => %{"type" => "string", "maxLength" => 2000},
              "violates" => %{"type" => "string", "maxLength" => 300},
              "correction" => %{"type" => "string", "maxLength" => 2000},
              "confidence" => %{"type" => "string", "enum" => @confidences}
            }
          }
        }
      }
    }
  end

  @doc """
  Validates reviewer output against `packet` and returns the canonical result:
  `%{"verdict", "summary", "findings" => [... "reference" => "none" |
  "supported" | "unsupported"], "outcome", "blocking_count"}`.
  """
  @spec validate(String.t(), map()) ::
          {:ok, map()} | {:error, {:schema_failed | :unsafe, String.t()}}
  def validate(json, packet) when is_binary(json) and is_map(packet) do
    known = MapSet.new(packet["changed_files"] ++ packet["repository_files"], & &1["path"])

    with {:ok, %{} = result} <- decode(json),
         :ok <- exact_keys(result, ~w(verdict summary findings)),
         true <- result["verdict"] in ["approve", "request_changes"] || {:schema, "verdict"},
         true <- text?(result["summary"], 2000) || {:schema, "summary"},
         findings when is_list(findings) and length(findings) <= @max_findings <-
           result["findings"],
         {:ok, findings} <- findings(findings, known),
         {:scan, []} <-
           {:scan, Security.scan_term(%{"summary" => result["summary"], "findings" => findings})} do
      blocking = Enum.count(findings, &blocking?/1)

      {:ok,
       %{
         "verdict" => result["verdict"],
         "summary" => result["summary"],
         "findings" => findings,
         "outcome" => if(blocking > 0, do: "changes_requested", else: "approved"),
         "blocking_count" => blocking
       }}
    else
      {:schema, field} -> {:error, {:schema_failed, field}}
      {:scan, _matches} -> {:error, {:unsafe, "findings"}}
      _ -> {:error, {:schema_failed, "findings"}}
    end
  end

  @doc "A supported (or path-free) blocking finding blocks; nothing else does."
  def blocking?(%{"severity" => "blocking", "reference" => reference}),
    do: reference in ["none", "supported"]

  def blocking?(_finding), do: false

  @doc """
  The fingerprint of a blocking finding across rounds: its path and what it
  violates. Wording differs between calls; the same defect usually does not
  move file or violated contract.
  """
  def fingerprint(%{"path" => path, "violates" => violates}) do
    PlanContract.digest(%{
      "path" => path,
      "violates" => violates |> String.downcase() |> String.split() |> Enum.join(" ")
    })
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = result} -> {:ok, result}
      _ -> {:schema, "json"}
    end
  end

  defp findings(findings, known) do
    findings
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn finding, {:ok, acc, ids} ->
      case finding(finding, known) do
        {:ok, %{"id" => id} = checked} ->
          if MapSet.member?(ids, id),
            do: {:halt, {:schema, "findings.id"}},
            else: {:cont, {:ok, [checked | acc], MapSet.put(ids, id)}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, findings, _ids} -> {:ok, Enum.reverse(findings)}
      error -> error
    end
  end

  defp finding(%{} = finding, known) do
    with :ok <-
           exact_keys(
             finding,
             ~w(id severity path line claim evidence violates correction confidence)
           ),
         true <-
           (is_binary(finding["id"]) and finding["id"] =~ ~r/\AF[0-9]{1,2}\z/) || {:schema, "id"},
         true <- finding["severity"] in @severities || {:schema, "severity"},
         true <- finding["confidence"] in @confidences || {:schema, "confidence"},
         true <- path?(finding["path"]) || {:schema, "path"},
         true <- line?(finding["line"]) || {:schema, "line"},
         true <-
           Enum.all?(@text_limits, fn {key, max} -> text?(finding[key], max) end) ||
             {:schema, "text"} do
      reference =
        cond do
          is_nil(finding["path"]) -> "none"
          MapSet.member?(known, finding["path"]) -> "supported"
          true -> "unsupported"
        end

      {:ok, Map.put(finding, "reference", reference)}
    end
  end

  defp finding(_finding, _known), do: {:schema, "finding"}

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys), do: :ok, else: {:schema, "keys"}
  end

  defp path?(nil), do: true

  defp path?(path) when is_binary(path) do
    byte_size(path) in 1..300 and not String.starts_with?(path, "/") and
      ".." not in Path.split(path) and not String.match?(path, ~r/[[:cntrl:]]/u)
  end

  defp path?(_path), do: false

  defp line?(nil), do: true
  defp line?(line), do: is_integer(line) and line >= 1 and line <= 10_000_000

  defp text?(value, max), do: is_binary(value) and String.length(value) <= max
end
