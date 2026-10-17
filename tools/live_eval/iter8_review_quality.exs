# Explicitly invoked review-quality eval for iteration 8; never part of the
# hermetic gate. Each case in tools/live_eval/review_quality/cases.json is a
# seeded defect or a clean control whose tests pass, labelled by
# construction. Every (reviewer, case) pair is one real review call outside
# the service (no admission, no records), like iter8_review_probe.exs.
#
#   ITER8_QUALITY_EVALUATION  a new disposable directory.
#   ITER8_QUALITY_MAX_CALLS   required: the call budget; the run stops before
#                             exceeding it.
#   ITER8_QUALITY_REVIEWERS   comma list of codex|claude (default codex,claude).
#   ITER8_QUALITY_CASES       optional comma list of case ids.
#   ITER8_CODEX_MODEL, ITER8_CLAUDE_MODEL  (defaults gpt-6-luna and opus)
#
#     mix run --no-start tools/live_eval/iter8_review_quality.exs < /dev/null
#
# Exported: per call the validated findings, reported output tokens and
# timing; per reviewer the scores. No provider frames, identifiers or
# reasoning. The evaluation root and home are substituted. Non-blocking
# findings are listed for a human to label as useful or not; this script
# never labels them.

Code.require_file("review_quality/builder.exs", __DIR__)

alias Shoestring.Cobbler.Review.{ClaudeHeadless, CodexExec, Findings}

defmodule Iter8ReviewQuality do
  def root, do: System.fetch_env!("ITER8_QUALITY_EVALUATION") |> Path.expand()

  def redact(text) when is_binary(text),
    do:
      text
      |> String.replace(root(), "$EVALUATION")
      |> String.replace(System.user_home!(), "$HOME")

  def redact(%{} = map), do: Map.new(map, fn {k, v} -> {k, redact(v)} end)
  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(other), do: other

  def write!(name, value) do
    File.mkdir_p!(Path.join(root(), "evidence"))
    path = Path.join([root(), "evidence", name <> ".json"])
    File.write!(path, Jason.encode!(redact(value), pretty: true))
    path
  end

  def ratio(_n, 0), do: nil
  def ratio(n, d), do: Float.round(n / d, 3)

  def summary(rows) do
    blocking = Enum.filter(rows, &(&1["label"] == "blocking"))
    clean = Enum.filter(rows, &(&1["label"] == "clean"))
    validated = Enum.filter(rows, &(&1["result"] == "validated"))
    findings = Enum.sum(Enum.map(validated, & &1["score"]["findings"]))
    unsupported = Enum.sum(Enum.map(validated, & &1["score"]["unsupported"]))
    hits = Enum.count(blocking, &get_in(&1, ["score", "location_hit"]))
    tokens = Enum.sum(Enum.map(validated, &(&1["output_tokens"] || 0)))

    %{
      "calls" => length(rows),
      "validated" => length(validated),
      "failed_calls" => length(rows) - length(validated),
      "blocking_cases" => length(blocking),
      "blocked_blocking_cases" => Enum.count(blocking, &get_in(&1, ["score", "blocked"])),
      "located_blocking_cases" => hits,
      "line_located_blocking_cases" => Enum.count(blocking, &get_in(&1, ["score", "line_hit"])),
      "recall_located" => ratio(hits, length(blocking)),
      "clean_cases" => length(clean),
      "falsely_blocked_clean_cases" => Enum.count(clean, &get_in(&1, ["score", "false_block"])),
      "false_block_rate" =>
        ratio(Enum.count(clean, &get_in(&1, ["score", "false_block"])), length(clean)),
      "findings" => findings,
      "unsupported_findings" => unsupported,
      "reference_validity" => ratio(findings - unsupported, findings),
      "non_blocking_findings" => Enum.sum(Enum.map(validated, & &1["score"]["non_blocking"])),
      "output_tokens" => tokens,
      "output_tokens_per_located_blocking_case" => ratio(tokens, hits),
      "elapsed_ms" => Enum.sum(Enum.map(rows, & &1["elapsed_ms"]))
    }
  end
end

root = Iter8ReviewQuality.root()
false = File.exists?(root)
max_calls = System.fetch_env!("ITER8_QUALITY_MAX_CALLS") |> String.to_integer()

reviewers =
  (System.get_env("ITER8_QUALITY_REVIEWERS") || "codex,claude") |> String.split(",", trim: true)

wanted =
  case System.get_env("ITER8_QUALITY_CASES") do
    nil -> nil
    list -> String.split(list, ",", trim: true)
  end

cases =
  ReviewQuality.Builder.cases()
  |> Enum.filter(&(wanted == nil or &1["id"] in wanted))

planned = length(cases) * length(reviewers)
if planned > max_calls, do: raise("#{planned} calls planned, budget #{max_calls}")

built = Map.new(cases, &{&1["id"], ReviewQuality.Builder.build!(&1, Path.join(root, "cases"))})
for {id, b} <- built, b.gate_exit != 0, do: raise("#{id}: its tests fail; not a review case")

rows =
  for reviewer <- reviewers, c <- cases do
    b = Map.fetch!(built, c["id"])

    {module, model} =
      case reviewer do
        "codex" -> {CodexExec, System.get_env("ITER8_CODEX_MODEL", "gpt-6-luna")}
        "claude" -> {ClaudeHeadless, System.get_env("ITER8_CLAUDE_MODEL", "opus")}
      end

    input = %{
      "packet_json" => b.json,
      "schema" => Findings.schema(),
      "model" => model,
      "max_output_tokens" => 4096,
      "timeout_ms" => 240_000
    }

    IO.puts("#{reviewer}:#{c["id"]} (#{c["label"]}) calling #{model} ...")
    {elapsed_us, result} = :timer.tc(fn -> module.review(input, endpoint: reviewer) end)

    row =
      case result do
        {:ok, %{json: answer, output_tokens: tokens}} ->
          case Findings.validate(answer, b.packet) do
            {:ok, findings} ->
              %{
                "result" => "validated",
                "outcome" => findings["outcome"],
                "summary" => findings["summary"],
                "findings" => findings["findings"],
                "score" => ReviewQuality.Builder.score(c, findings),
                "output_tokens" => tokens
              }

            {:error, reason} ->
              %{
                "result" => "schema_failed",
                "reason" => inspect(reason),
                "output_tokens" => tokens
              }
          end

        {:error, code} ->
          %{"result" => "adapter_error", "code" => Atom.to_string(code)}
      end
      |> Map.merge(%{
        "reviewer" => reviewer,
        "model" => model,
        "case" => c["id"],
        "category" => c["category"],
        "label" => c["label"],
        "packet_digest" => b.digest,
        "elapsed_ms" => div(elapsed_us, 1000)
      })

    progress =
      Map.merge(
        Map.take(row, ~w(result outcome code output_tokens elapsed_ms)),
        Map.take(row["score"] || %{}, ~w(location_hit false_block))
      )

    IO.puts("  -> " <> Jason.encode!(progress))

    row
  end

summary =
  rows
  |> Enum.group_by(& &1["reviewer"])
  |> Map.new(fn {r, rs} -> {r, Iter8ReviewQuality.summary(rs)} end)

to_label =
  for row <- rows, f <- row["findings"] || [], f["severity"] != "blocking" do
    Map.merge(Map.take(row, ~w(reviewer case label)), %{"finding" => f, "useful" => nil})
  end

IO.puts("Wrote #{Iter8ReviewQuality.write!("results", rows)}")
IO.puts("Wrote #{Iter8ReviewQuality.write!("summary", summary)}")
IO.puts("Wrote #{Iter8ReviewQuality.write!("non-blocking-to-label", to_label)}")
IO.puts(Jason.encode!(summary, pretty: true))
