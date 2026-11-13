defmodule Shoestring.Test.ExternalHelpers do
  @moduledoc """
  Fixtures for EXTERNAL dispatches (iteration 20): a temporary Git
  repository with a passing Python test, a session grant that allows
  EXTERNAL with one unit, and an injected passing gate runner.
  """
  import ExUnit.Assertions

  alias Shoestring.{Dispatches, Grants, ModelCatalog}

  @by "human:operator"

  def by, do: @by

  def external_session(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "tests"))
    File.write!(Path.join(repo, "tool.py"), "def greet(who):\n    return 'Hello, ' + who\n")

    File.write!(
      Path.join(repo, "tests/test_tool.py"),
      "import unittest\nimport tool\n\nclass T(unittest.TestCase):\n    def test_greet(self):\n        self.assertEqual(tool.greet('x'), 'Hello, x')\n"
    )

    File.write!(Path.join(repo, "tests/__init__.py"), "")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    {root, 0} = System.cmd("git", ["-C", repo, "rev-parse", "--show-toplevel"])
    repo = String.trim(root)
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
    session = "ext-#{System.unique_integer([:positive])}"

    {:ok, grant} =
      Grants.create(
        %{
          session_id: session,
          repository_root: repo,
          models: ["codex:gpt-6-luna"],
          purposes: ~w(implement external),
          max_dispatches: 6,
          max_parallel: 3,
          max_total_seconds: 3 * 3600,
          max_dispatch_seconds: 3600,
          unread_usage: 2,
          max_turns: 5,
          units: [%{"name" => "flow_credits", "cap" => 100, "reserve" => 40}]
        },
        @by
      )

    %{repo: repo, session: session, grant: grant, worktrees: Path.join(dir, "worktrees")}
  end

  def git!(dir, args),
    do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  def request(ctx, extra \\ %{}) do
    {provider, model} = Dispatches.external_worker()

    Map.merge(
      %{
        session_id: ctx.session,
        request_id: "ext-#{System.unique_integer([:positive])}",
        purpose: "external",
        provider: provider,
        model: model,
        title: "Make one reference sheet",
        brief: "EXTERNAL - make one reference sheet\\nContract: tests/test_tool.py passes.\\n",
        repository: ctx.repo,
        tests: ["tests/test_tool.py"]
      },
      extra
    )
  end

  def started!(ctx, extra \\ %{}) do
    assert {:ok, dispatch, :recorded} = Dispatches.create(request(ctx, extra))
    dispatch
  end

  def passing,
    do: [
      gate_runner_opts: [
        runner: fn _argv, _worktree, _timeout ->
          {:ok, %{exit_status: 0, output: "Ran 1 test\\nOK", duration_ms: 3}}
        end
      ]
    ]

  def commit_in!(path, file \\ "sheet.txt", text \\ "a sheet\\n") do
    File.write!(Path.join(path, file), text)
    git!(path, ["add", file])

    git!(path, ["-c", "user.name=Op", "-c", "user.email=op@example.com", "commit", "-qm", "sheet"])

    {sha, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
    String.trim(sha)
  end
end
