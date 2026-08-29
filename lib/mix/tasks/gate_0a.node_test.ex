defmodule Mix.Tasks.Gate0a.NodeTest do
  @shortdoc "Runs the Gate 0A Node.js probe regression tests"

  @moduledoc """
  Runs `node --test` over every Gate 0A Node.js test file
  (`test/gate_0a_*.test.js`) so these regression tests cannot silently
  disappear from CI.
  """

  use Mix.Task

  @required_test_files [
    "test/gate_0a_statusline_observer.test.js",
    "test/gate_0a_probe_runners.test.js",
    "test/gate_0a_probe_evidence_classification.test.js"
  ]

  @impl Mix.Task
  def run(_args) do
    node = System.find_executable("node") || Mix.raise("node executable not found on PATH")

    missing_required = Enum.reject(@required_test_files, &File.exists?/1)

    if missing_required != [] do
      Mix.raise(
        "Missing required Gate 0A Node.js test file(s): #{Enum.join(missing_required, ", ")}"
      )
    end

    test_files = "test/gate_0a_*.test.js" |> Path.wildcard() |> Enum.sort()

    if test_files == [] do
      Mix.raise("No Gate 0A Node.js test files found (test/gate_0a_*.test.js)")
    end

    {output, exit_status} = System.cmd(node, ["--test" | test_files], stderr_to_stdout: true)

    Mix.shell().info(output)

    if exit_status != 0 do
      Mix.raise("Gate 0A Node.js tests failed (exit status #{exit_status})")
    end
  end
end
