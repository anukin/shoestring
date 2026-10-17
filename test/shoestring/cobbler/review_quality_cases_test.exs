defmodule Shoestring.Cobbler.ReviewQualityCasesTest do
  @moduledoc """
  The seeded review-quality cases (`tools/live_eval/review_quality`) are
  sound: every case's tests pass, so only a review can tell a defect from a
  clean change, every labelled defect is in the reviewed diff, and the scorer
  counts findings as the eval reports them. Local git and python3 only.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.Review.Findings

  Code.require_file("../../../tools/live_eval/review_quality/builder.exs", __DIR__)

  @moduletag :tmp_dir

  test "every case passes its tests and names a defect inside its diff", %{tmp_dir: dir} do
    cases = ReviewQuality.Builder.cases()
    assert length(cases) == 13
    assert Enum.count(cases, &(&1["label"] == "blocking")) == 8

    assert cases |> Enum.map(& &1["category"]) |> Enum.uniq() |> Enum.sort() ==
             ~w(concurrency correctness error_handling scope security tests)

    for c <- cases do
      built = ReviewQuality.Builder.build!(c, dir)
      assert built.gate_exit == 0, "#{c["id"]}: its tests must pass"
      changed = Enum.map(built.packet["changed_files"], & &1["path"])

      case c["label"] do
        "blocking" ->
          assert Enum.any?(c["defect"]["paths"], &(&1 in changed)), c["id"]
          assert is_binary(c["defect"]["description"])

        "clean" ->
          refute Map.has_key?(c, "defect")
      end
    end
  end

  test "the scorer counts a located blocking finding, a false block and an unsupported path",
       %{tmp_dir: dir} do
    cases = Map.new(ReviewQuality.Builder.cases(), &{&1["id"], &1})
    defect = cases["correctness-inclusive-range"]
    built = ReviewQuality.Builder.build!(defect, dir)

    answer = fn findings ->
      {:ok, validated} =
        Findings.validate(
          Jason.encode!(%{
            "verdict" => "request_changes",
            "summary" => "s",
            "findings" => findings
          }),
          built.packet
        )

      validated
    end

    hit = answer.([finding("F1", "blocking", "ranges.py", 2)])

    assert %{"location_hit" => true, "line_hit" => true, "blocked" => true} =
             ReviewQuality.Builder.score(defect, hit)

    elsewhere = answer.([finding("F1", "blocking", "test/test_ranges.py", 7)])

    assert %{"location_hit" => false, "blocked" => true, "blocking_elsewhere" => 1} =
             ReviewQuality.Builder.score(defect, elsewhere)

    invented = answer.([finding("F1", "blocking", "nowhere.py", 1)])

    assert %{"blocked" => false, "unsupported" => 1} =
             ReviewQuality.Builder.score(defect, invented)

    clean = cases["clean-inclusive-range"]
    assert %{"false_block" => true} = ReviewQuality.Builder.score(clean, hit)

    assert %{"false_block" => false, "non_blocking" => 1} =
             ReviewQuality.Builder.score(
               clean,
               answer.([finding("F1", "non_blocking", "ranges.py", 2)])
             )
  end

  defp finding(id, severity, path, line) do
    %{
      "id" => id,
      "severity" => severity,
      "path" => path,
      "line" => line,
      "claim" => "A claim.",
      "evidence" => "Some evidence.",
      "violates" => "correctness",
      "correction" => "A correction.",
      "confidence" => "high"
    }
  end
end
