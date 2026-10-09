defmodule Shoestring.Test.FixturePlanFake do
  @moduledoc "Fake harness with deterministic edits confined to the allocated fixture worktree."
  alias Shoestring.Harness.Fake

  def start(request, opts) do
    {:ok, worktree} =
      Shoestring.Worktrees.get(
        Path.join(Shoestring.State.path(:worktrees), request.workspace_ref)
      )

    true = worktree.workspace_ref == request.workspace_ref
    path = worktree.path
    task = request.extensions["shoestring.plan:binding"]["plan_task_id"]
    file = Path.join(path, "lib/fixture.ex")
    source = File.read!(file)

    replacement =
      case task do
        "alpha" ->
          String.replace(source, "end\n", "  def greeting, do: \"hello\"\nend\n")

        "beta" ->
          String.replace(source, "end\n", "  def message, do: greeting() <> \" fixture\"\nend\n")
      end

    File.write!(file, replacement)
    {_, 0} = System.cmd("git", ["add", "lib/fixture.ex"], cd: path)

    {_, 0} =
      System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-m", "Fixture task #{task}"],
        cd: path
      )

    Fake.start(request, opts)
  end

  defdelegate resume(prior, request, opts), to: Fake
  defdelegate stream(identity, opts), to: Fake
  defdelegate probe(opts), to: Fake
  defdelegate cancel(identity, opts), to: Fake
  defdelegate identity(), to: Fake
  defdelegate status(identity, opts), to: Fake
end
