# Explicitly invoked live probe of the iteration 8 reviewer adapters; never
# part of the hermetic gate. Each case is one real review call, outside the
# service (no admission, no records), like tools/planner_eval/codex_proposal.py.
#
#   ITER8_REVIEW_EVALUATION  a new disposable directory (under the home
#                            directory is fine); the fixture lives there.
#   ITER8_REVIEW_CASES       comma list of ADAPTER:CASE, ADAPTER codex|claude,
#                            CASE seeded|clean (default: all four).
#   ITER8_CODEX_MODEL, ITER8_CLAUDE_MODEL  (defaults gpt-6-luna and opus)
#
#     mix run --no-start tools/live_eval/iter8_review_probe.exs < /dev/null
#
# The fixture's only test is add(2, 2) == 4. "seeded" implements add as
# a * b: the gate passes, the contract (return the sum) is violated, so only a
# review can find it. "clean" implements a + b. Only the validated findings,
# the reported output tokens and timings are exported; no provider frames,
# identifiers or reasoning. The evaluation root and home are substituted.

alias Shoestring.Cobbler.GateProcess
alias Shoestring.Cobbler.Review.{ClaudeHeadless, CodexExec, Findings, Packet}

defmodule Iter8ReviewProbe do
  def root, do: System.fetch_env!("ITER8_REVIEW_EVALUATION") |> Path.expand()

  def git!(dir, args) do
    {:ok, %{exit_status: 0, output: out}} =
      GateProcess.run(["git" | args], dir, 30_000, 1_048_576)

    out
  end

  def redact(text) when is_binary(text),
    do:
      text
      |> String.replace(root(), "$EVALUATION")
      |> String.replace(System.user_home!(), "$HOME")

  def redact(%{} = map), do: Map.new(map, fn {k, v} -> {k, redact(v)} end)
  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(other), do: other
end

root = Iter8ReviewProbe.root()
false = File.exists?(root)
source = Path.join(root, "source")
File.mkdir_p!(Path.join(source, "test"))
File.write!(Path.join(source, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
File.write!(Path.join(source, "test/__init__.py"), "")

File.write!(Path.join(source, "test/test_calc.py"), """
import unittest
from calc import add


class AddTest(unittest.TestCase):
    def test_two_and_two(self):
        self.assertEqual(add(2, 2), 4)
""")

for args <- [
      ["init", "-b", "main"],
      ["config", "user.name", "Fixture"],
      ["config", "user.email", "fixture@example.invalid"],
      ["add", "."],
      ["-c", "commit.gpgsign=false", "commit", "-m", "Base"]
    ],
    do: Iter8ReviewProbe.git!(source, args)

base = source |> Iter8ReviewProbe.git!(["rev-parse", "HEAD"]) |> String.trim()

goal = %{
  "title" => "Make add return the sum",
  "objective" => "Make add(a, b) in calc.py return the sum of its arguments.",
  "repository" => %{"base_revision" => base},
  "acceptance" => %{
    "criteria" => ["add(a, b) returns a + b for all numbers", "Existing tests stay unchanged"]
  }
}

task = %{
  "id" => "fix-add",
  "title" => "Implement add",
  "files" => ["calc.py"],
  "acceptance_criteria" => [
    "add(a, b) returns the sum a + b",
    "test/test_calc.py is not modified"
  ]
}

bodies = %{"seeded" => "    return a * b\n", "clean" => "    return a + b\n"}

cases =
  (System.get_env("ITER8_REVIEW_CASES") || "codex:seeded,codex:clean,claude:seeded,claude:clean")
  |> String.split(",", trim: true)
  |> Enum.map(&String.split(&1, ":"))

results =
  for [adapter, kind] <- cases do
    wt = Path.join(root, "#{adapter}-#{kind}")
    Iter8ReviewProbe.git!(source, ["worktree", "add", "-q", "-b", "#{adapter}-#{kind}", wt, base])
    File.write!(Path.join(wt, "calc.py"), "def add(a, b):\n" <> Map.fetch!(bodies, kind))
    Iter8ReviewProbe.git!(wt, ["-c", "commit.gpgsign=false", "commit", "-qam", "Implement add"])
    commit = wt |> Iter8ReviewProbe.git!(["rev-parse", "HEAD"]) |> String.trim()

    {:ok, gate} =
      GateProcess.run(
        ["python3", "-B", "-m", "unittest", "test/test_calc.py"],
        wt,
        60_000,
        65_536
      )

    gates = [
      %{
        "gate" => "python_unittest",
        "argv" => "python3 -B -m unittest test/test_calc.py",
        "exit_status" => gate.exit_status,
        "duration_ms" => gate.duration_ms,
        "output" => gate.output,
        "sandbox" => nil
      }
    ]

    {:ok, %{packet: packet, json: json, digest: digest}} =
      Packet.build(%{
        goal: goal,
        task: task,
        revision_number: 1,
        plan_digest: String.duplicate("0", 64),
        base: base,
        commit: commit,
        worktree: wt,
        gates: gates
      })

    {module, model} =
      case adapter do
        "codex" -> {CodexExec, System.get_env("ITER8_CODEX_MODEL", "gpt-6-luna")}
        "claude" -> {ClaudeHeadless, System.get_env("ITER8_CLAUDE_MODEL", "opus")}
      end

    input = %{
      "packet_json" => json,
      "schema" => Findings.schema(),
      "model" => model,
      "max_output_tokens" => 4096,
      "timeout_ms" => 240_000
    }

    IO.puts("#{adapter}:#{kind} gate exit #{gate.exit_status}; calling #{model} ...")
    {elapsed_us, result} = :timer.tc(fn -> module.review(input, endpoint: adapter) end)

    summary =
      case result do
        {:ok, %{json: answer, output_tokens: tokens}} ->
          case Findings.validate(answer, packet) do
            {:ok, findings} ->
              %{
                "result" => "validated",
                "outcome" => findings["outcome"],
                "blocking_count" => findings["blocking_count"],
                "verdict" => findings["verdict"],
                "summary" => findings["summary"],
                "findings" => findings["findings"],
                "output_tokens" => tokens
              }

            {:error, reason} ->
              %{
                "result" => "schema_failed",
                "reason" => inspect(reason),
                "output_tokens" => tokens,
                "answer_bytes" => byte_size(answer)
              }
          end

        {:error, code} ->
          %{"result" => "adapter_error", "code" => Atom.to_string(code)}
      end

    summary =
      Map.merge(summary, %{
        "case" => kind,
        "adapter" => adapter,
        "model" => model,
        "packet_digest" => digest,
        "gate_exit" => gate.exit_status,
        "elapsed_ms" => div(elapsed_us, 1000)
      })

    IO.puts(
      "  -> " <>
        Jason.encode!(
          Map.take(
            summary,
            ~w(result outcome blocking_count code reason output_tokens elapsed_ms)
          )
        )
    )

    summary
  end

File.mkdir_p!(Path.join(root, "evidence"))

File.write!(
  Path.join(root, "evidence/review-probe.json"),
  Jason.encode!(Iter8ReviewProbe.redact(results), pretty: true)
)

IO.puts("Wrote #{Path.join(root, "evidence/review-probe.json")}")
