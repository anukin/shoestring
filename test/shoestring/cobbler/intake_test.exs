defmodule Shoestring.Cobbler.IntakeTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.Intake

  # Temporary repositories are retained; no cleanup/reaper behaviour.
  defp repo!(files) do
    root = Path.join(System.tmp_dir!(), "shoestring-intake-#{Ecto.UUID.generate()}")

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), content)
    end

    File.mkdir_p!(root)
    git!(root, ["init", "-q", "-b", "main"])

    if files != [] do
      git!(root, ["add", "."])
      git!(root, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    end

    root
  end

  defp git!(root, args) do
    {_, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    :ok
  end

  defp head(root) do
    {out, 0} = System.cmd("git", ["-C", root, "rev-parse", "HEAD"])
    String.trim(out)
  end

  @python [
    {"calc.py", "def add(a, b):\n    raise NotImplementedError\n"},
    {"test/test_calc.py", "import unittest\n"},
    {"test/unit/test_more.py", "import unittest\n"}
  ]

  test "a clean Python repository yields HEAD, tracked paths, a unittest gate and a contract" do
    root = repo!(@python)
    assert {:ok, facts} = Intake.repository(Path.join(root, "test"))
    # Run from a subdirectory; the root is the top level (macOS may resolve /var).
    assert Path.basename(facts.root) == Path.basename(root)
    assert File.dir?(Path.join(facts.root, ".git"))
    assert facts.head == head(root)
    assert facts.tracked == ["calc.py", "test/test_calc.py", "test/unit/test_more.py"]

    assert {:ok, [gate]} = Intake.gates(facts)

    assert gate == %{
             "gate" => "python_unittest",
             "test_paths" => ["test/test_calc.py", "test/unit/test_more.py"]
           }

    assert {:ok, contract} =
             Intake.goal_contract("  Make add return the sum.  ", facts, [gate],
               constraints: ["Keep add pure."]
             )

    assert contract["statement"] == "Make add return the sum."
    assert contract["repository"] == %{"base_revision" => facts.head}
    assert contract["acceptance"]["gates"] == [gate]
    assert "Keep add pure." in contract["constraints"]
  end

  test "a Mix project gets mix_test, and explicit flags replace detection" do
    root = repo!([{"mix.exs", "defmodule X.MixProject do end\n"}, {"test/x_test.exs", ""}])
    {:ok, facts} = Intake.repository(root)

    assert {:ok, [%{"gate" => "mix_test"}]} = Intake.gates(facts)

    assert {:ok,
            [
              %{"gate" => "mix_precommit"},
              %{"gate" => "mix_test", "test_paths" => ["test/x_test.exs"]}
            ]} =
             Intake.gates(facts, gates: ["mix_precommit"], tests: ["test/x_test.exs"])
  end

  test "refusals name the missing input and never guess" do
    assert {:error, :not_a_git_repository} =
             Intake.repository(
               System.tmp_dir!()
               |> Path.join("no-repo-#{Ecto.UUID.generate()}")
               |> tap(&File.mkdir_p!/1)
             )

    assert {:error, :no_commits} = Intake.repository(repo!([]))

    dirty = repo!(@python)
    File.write!(Path.join(dirty, "calc.py"), "changed\n")
    File.write!(Path.join(dirty, "notes.txt"), "new\n")
    assert {:error, {:dirty_worktree, paths}} = Intake.repository(dirty)
    assert Enum.sort(paths) == ["calc.py", "notes.txt"]
    # Untracked files can be let through alone; every path can be allowed.
    assert {:error, {:dirty_worktree, ["calc.py"]}} =
             Intake.repository(dirty, uncommitted: :untracked)

    assert {:ok, %{uncommitted: uncommitted}} = Intake.repository(dirty, uncommitted: :allow)
    assert Enum.sort(uncommitted) == ["calc.py", "notes.txt"]
    File.write!(Path.join(dirty, "calc.py"), File.read!(Path.join(dirty, "calc.py")))
    git!(dirty, ["checkout", "--", "calc.py"])

    assert {:ok, %{uncommitted: ["notes.txt"]}} =
             Intake.repository(dirty, uncommitted: :untracked)

    {:ok, bare} = Intake.repository(repo!([{"README.md", "x\n"}]))
    assert {:error, :no_gate_detected} = Intake.gates(bare)

    many = for n <- 1..17, do: {"test/test_m#{n}.py", ""}
    {:ok, too_many} = Intake.repository(repo!(many))
    assert {:error, {:too_many_python_tests, 17}} = Intake.gates(too_many)

    {:ok, facts} = Intake.repository(repo!(@python))
    assert {:error, {:unknown_gate, "rm_rf"}} = Intake.gates(facts, gates: ["rm_rf"])

    assert {:error, {:untracked_test_path, "test/test_x.py"}} =
             Intake.gates(facts, tests: ["test/test_x.py"])

    assert {:error, {:unsupported_test_path, "calc.py"}} = Intake.gates(facts, tests: ["calc.py"])
    assert {:error, :empty_request} = Intake.goal_contract("   ", facts, [])
  end

  test "the repository map lists tracked paths only, bounded, and says when it is partial" do
    {:ok, facts} = Intake.repository(repo!(@python))

    small = Intake.repository_map(%{facts | tracked: ["calc.py", "test/test_calc.py"]})

    assert small == %{
             "paths" => ["calc.py", "test/test_calc.py"],
             "total_paths" => 2,
             "omitted_paths" => 0,
             "complete" => true
           }

    many = for n <- 1..500, do: "src/module_#{n}.py"
    partial = Intake.repository_map(%{facts | tracked: many})
    assert length(partial["paths"]) == 400
    assert partial["total_paths"] == 500
    refute partial["complete"]

    flagged = Intake.repository_map(%{facts | tracked: ["/Users/someone/x.py", "ok.py"]})
    assert flagged["paths"] == ["ok.py"]
    assert flagged["omitted_paths"] == 1
    refute flagged["complete"]
  end
end
