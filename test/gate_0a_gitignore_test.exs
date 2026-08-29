defmodule Shoestring.Gate0AGitignoreTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("..", __DIR__)

  test "evidence is deny-by-default except for sanitized Gate 0A artifacts" do
    assert ignored?("plans/evidence/sibling-raw-provider.json")
    refute ignored?("plans/evidence/00a-capacity-feasibility/support-matrix.md")

    refute ignored?(
             "plans/evidence/00a-capacity-feasibility/fixtures/claude/normal-official-shape.json"
           )
  end

  defp ignored?(relative_path) do
    {_output, status} =
      System.cmd("git", ["check-ignore", "--no-index", "-q", relative_path], cd: @repo_root)

    status == 0
  end
end
