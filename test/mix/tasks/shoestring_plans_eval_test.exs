defmodule Mix.Tasks.Shoestring.Plans.EvalTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Shoestring.Plans.Eval

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "exports context and clearly labels reference fixture smoke checks" do
    Eval.run(["list"])
    assert_receive {:mix_shell, :info, [json]}
    assert Jason.decode!(json)["cases"] == ["catalog", "greeting", "receipt"]

    Eval.run(["context", "receipt"])
    assert_receive {:mix_shell, :info, [json]}
    assert Jason.decode!(json)["repository_files"]["test/test_receipt.py"] =~ "475 cents"

    Eval.run(["reference", "receipt"])
    assert_receive {:mix_shell, :info, [json]}
    report = Jason.decode!(json)
    assert report["source"] == "reference_fixture_smoke_check"
    assert report["candidate"]["schema_status"] == "valid"
    assert report["quality_verdict"] == "UNVERIFIED"
  end

  test "compares saved raw proposals and refuses ambiguous or unreadable input" do
    file = Application.app_dir(:shoestring, "priv/planner_eval/cases/greeting/reference.json")
    Eval.run(["compare", "greeting", "--file", file])
    assert_receive {:mix_shell, :info, [json]}
    report = Jason.decode!(json)
    assert report["source"] == "saved_proposal_unverified_origin"
    assert report["candidate"]["schema_status"] == "valid"

    assert_raise Mix.Error, ~r/unreadable_or_oversized_file/, fn ->
      Eval.run(["compare", "greeting", "--file", "missing-eval-file.json"])
    end

    assert_raise Mix.Error, ~r/unknown_case/, fn -> Eval.run(["context", "../receipt"]) end

    for args <- [
          ["compare", "greeting"],
          ["compare", "greeting", "--file", file, "--approve"],
          ["list", "extra"]
        ] do
      assert_raise Mix.Error, ~r/Invalid arguments/, fn -> Eval.run(args) end
    end
  end
end
