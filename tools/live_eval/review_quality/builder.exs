# Builds and scores the seeded review-quality cases in cases.json. Shared by
# the hermetic case-validity test and the live eval
# (tools/live_eval/iter8_review_quality.exs); runs local git and python3
# only, never a provider.

defmodule ReviewQuality.Builder do
  @moduledoc false

  alias Shoestring.Cobbler.GateProcess
  alias Shoestring.Cobbler.Review.Packet

  @cases Path.join(__DIR__, "cases.json")

  def cases, do: @cases |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  @doc """
  Creates the case's base repository and its changed worktree under `root`,
  runs the case's test there, and builds the review packet.
  """
  def build!(%{"id" => id} = c, root) do
    source = Path.join([root, id, "source"])
    change = Path.join([root, id, "change"])
    File.mkdir_p!(source)
    write_all!(source, c["base"])

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.name", "Fixture"],
          ["config", "user.email", "fixture@example.invalid"],
          ["add", "."],
          ["-c", "commit.gpgsign=false", "commit", "-qm", "Base"]
        ],
        do: git!(source, args)

    base = source |> git!(["rev-parse", "HEAD"]) |> String.trim()
    git!(source, ["worktree", "add", "-q", "-b", "change", change, base])
    write_all!(change, c["change"])
    git!(change, ["add", "-A"])
    git!(change, ["-c", "commit.gpgsign=false", "commit", "-qm", "Implement the task"])
    commit = change |> git!(["rev-parse", "HEAD"]) |> String.trim()

    {:ok, gate} =
      GateProcess.run(["python3", "-B", "-m", "unittest", c["test"]], change, 60_000, 65_536)

    gates = [
      %{
        "gate" => "python_unittest",
        "argv" => "python3 -B -m unittest #{c["test"]}",
        "exit_status" => gate.exit_status,
        "duration_ms" => gate.duration_ms,
        "output" => gate.output,
        "sandbox" => nil
      }
    ]

    {:ok, built} =
      Packet.build(%{
        goal: Map.put(c["goal"], "repository", %{"base_revision" => base}),
        task: c["task"],
        revision_number: 1,
        plan_digest: String.duplicate("0", 64),
        base: base,
        commit: commit,
        worktree: change,
        gates: gates
      })

    Map.merge(built, %{gate_exit: gate.exit_status, base: base, commit: commit, worktree: change})
  end

  @doc """
  Scores validated findings against the case label. A blocking case is
  found when a supported blocking finding names one of the labelled paths
  (`line_hit?` also needs its line within the labelled range, two lines of
  slack); a clean case is falsely blocked by any supported blocking finding.
  """
  def score(c, findings) do
    items = findings["findings"]
    blocking = Enum.filter(items, &Shoestring.Cobbler.Review.Findings.blocking?/1)
    paths = get_in(c, ["defect", "paths"]) || []
    [low, high] = get_in(c, ["defect", "lines"]) || [0, 0]
    on_path = Enum.filter(blocking, &(&1["path"] in paths))

    %{
      "label" => c["label"],
      "outcome" => findings["outcome"],
      "blocked" => blocking != [],
      "location_hit" => c["label"] == "blocking" and on_path != [],
      "line_hit" =>
        c["label"] == "blocking" and
          Enum.any?(on_path, &(is_integer(&1["line"]) and &1["line"] in (low - 2)..(high + 2)//1)),
      "false_block" => c["label"] == "clean" and blocking != [],
      "blocking" => length(blocking),
      "blocking_elsewhere" => length(blocking) - length(on_path),
      "non_blocking" => Enum.count(items, &(&1["severity"] == "non_blocking")),
      "suggestions" => Enum.count(items, &(&1["severity"] == "suggestion")),
      "unsupported" => Enum.count(items, &(&1["reference"] == "unsupported")),
      "findings" => length(items)
    }
  end

  defp write_all!(dir, files) do
    for {path, content} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end
  end

  defp git!(dir, args) do
    {:ok, %{exit_status: 0, output: out}} =
      GateProcess.run(["git" | args], dir, 30_000, 1_048_576)

    out
  end
end
