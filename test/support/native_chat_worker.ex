defmodule Shoestring.Test.NativeChatWorker do
  @moduledoc "Hermetic chat demo worker: edit only its allocated copy, then stream Fake events."
  alias Shoestring.Harness.Fake

  def start(request, opts) do
    {:ok, tree} =
      Shoestring.Worktrees.get(
        Path.join(Shoestring.State.path(:worktrees), request.workspace_ref)
      )

    File.write!(Path.join(tree.path, "calc.py"), "def add(a, b):\n    return a + b\n")
    {_, 0} = System.cmd("git", ["add", "calc.py"], cd: tree.path)

    {_, 0} =
      System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-qm", "Implement fixture sum"],
        cd: tree.path
      )

    Fake.start(request, opts)
  end

  defdelegate identity(), to: Fake
  defdelegate capabilities(), to: Fake
  defdelegate probe(opts), to: Fake
  defdelegate resume(identity, request, opts), to: Fake
  defdelegate send(identity, text, opts), to: Fake
  defdelegate cancel(identity, opts), to: Fake
  defdelegate status(identity, opts), to: Fake
  defdelegate stream(identity, opts), to: Shoestring.Test.FanoutBarrierFake
end
