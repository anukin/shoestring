defmodule Shoestring.LiveEvalProviderBudgetTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    bin = Path.join(root, "fake-providers")
    File.mkdir_p!(bin)

    for name <- ~w(claude codex) do
      path = Path.join(bin, name)
      File.write!(path, "#!/bin/sh\nprintf 'fake-provider\\n'\n")
      File.chmod!(path, 0o755)
    end

    budget = Path.join(root, "budget")

    env = [
      {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
      {"SHOESTRING_LIVE_BUDGET_DIR", budget}
    ]

    %{root: root, budget: budget, env: env, python: System.find_executable("python3")}
  end

  test "a shared ceiling admits one concurrent worker and refuses the rest", c do
    assert {_, 0} = initialize(c)

    results =
      1..6
      |> Task.async_stream(fn _ -> invoke(c, "claude", ["--output-format", "stream-json"]) end,
        max_concurrency: 6,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({"fake-provider\n", 0}, &1)) == 1
    assert Enum.count(results, &match?({_, 125}, &1)) == 5
    assert ledger(c)["used"]["worker"] == 1
    assert length(ledger(c)["calls"]) == 1
    refute ledger(c)["calls"] |> inspect() =~ "output-format"
  end

  test "classification shares reviewer limits across providers and refuses unknown calls", c do
    assert {_, 0} = initialize(c)

    assert {"fake-provider\n", 0} =
             invoke(c, "claude", [
               "--output-format",
               "json",
               "--json-schema",
               ~s({"properties":{"tasks":{}}})
             ])

    assert {"fake-provider\n", 0} =
             invoke(c, "claude", [
               "--output-format",
               "json",
               "--json-schema",
               ~s({"properties":{"findings":{}}})
             ])

    assert {refused, 125} = invoke(c, "codex", ["exec"])
    refute refused =~ "fake-provider"
    assert {_, 2} = invoke(c, "claude", ["unclassified"])
    assert ledger(c)["used"] == %{"planner" => 1, "worker" => 0, "reviewer" => 1}
    assert {_, nonzero} = initialize(c)
    assert nonzero != 0
    assert ledger(c)["used"]["planner"] == 1
  end

  test "an injected delivery failure is charged once before explicit retry", c do
    assert {_, 0} = initialize(c, ["--reviewer", "2", "--fail-first-review-delivery", "codex"])
    assert {failed, 71} = invoke(c, "codex", ["exec"])
    refute failed =~ "fake-provider"
    assert {"fake-provider\n", 0} = invoke(c, "codex", ["exec"])
    assert ledger(c)["used"]["reviewer"] == 2
    [first, second] = ledger(c)["calls"]
    assert first["injected_delivery_failure"]
    refute Map.has_key?(second, "injected_delivery_failure")
  end

  defp initialize(c, extra \\ []) do
    System.cmd(
      c.python,
      [
        "tools/live_eval/provider_budget.py",
        "init",
        c.budget,
        "--planner",
        "1",
        "--worker",
        "1",
        "--reviewer",
        "1"
      ] ++ extra,
      env: c.env,
      stderr_to_stdout: true
    )
  end

  defp invoke(c, provider, args),
    do:
      System.cmd(Path.join([c.budget, "bin", provider]), args, env: c.env, stderr_to_stdout: true)

  defp ledger(c), do: c.budget |> Path.join("ledger.json") |> File.read!() |> Jason.decode!()
end
