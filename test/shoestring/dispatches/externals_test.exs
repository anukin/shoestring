defmodule Shoestring.Dispatches.ExternalsTest do
  @moduledoc """
  Iteration 20: EXTERNAL dispatches. Work done outside Shoestring in its run
  worktree, accepted only by its checks; a person confirms, completes or
  abandons. Hermetic: a temporary Git repository, real private-Git run
  worktrees, an injected gate runner (one real sandboxed check), no
  provider and no network. The test process plays the operator.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{Dispatches, Grants, ModelCatalog, Repo}
  alias Shoestring.Dispatches.{External, Externals}

  @moduletag :tmp_dir
  @by "human:operator"

  setup %{tmp_dir: dir} do
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
          units: [%{"name" => "flow_credits", "cap" => 100, "reserve" => 40}]
        },
        @by
      )

    %{repo: repo, session: session, grant: grant, worktrees: Path.join(dir, "worktrees")}
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp request(ctx, extra \\ %{}) do
    {provider, model} = Dispatches.external_worker()

    Map.merge(
      %{
        session_id: ctx.session,
        request_id: "ext-#{System.unique_integer([:positive])}",
        purpose: "external",
        provider: provider,
        model: model,
        title: "Make one reference sheet",
        brief: "EXTERNAL - make one reference sheet\nContract: tests/test_tool.py passes.\n",
        repository: ctx.repo,
        tests: ["tests/test_tool.py"]
      },
      extra
    )
  end

  defp passing,
    do: [
      gate_runner_opts: [
        runner: fn _argv, _worktree, _timeout ->
          {:ok, %{exit_status: 0, output: "Ran 1 test\nOK", duration_ms: 3}}
        end
      ]
    ]

  defp started!(ctx, extra \\ %{}) do
    assert {:ok, dispatch, :recorded} = Dispatches.create(request(ctx, extra))
    dispatch
  end

  defp confirmed!(ctx, extra \\ %{}) do
    dispatch = started!(ctx, extra)
    assert :confirmed = Externals.confirm(dispatch, @by, worktrees_dir: ctx.worktrees)
    {dispatch, Externals.get(dispatch.id)}
  end

  defp commit_in!(path, file \\ "sheet.txt", text \\ "a sheet\n") do
    File.write!(Path.join(path, file), text)
    git!(path, ["add", file])

    git!(path, ["-c", "user.name=Op", "-c", "user.email=op@example.com", "commit", "-qm", "sheet"])

    {sha, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
    String.trim(sha)
  end

  describe "recording and the grant" do
    test "an EXTERNAL is recorded held, with its units reserved and no worktree yet", ctx do
      dispatch = started!(ctx)
      assert dispatch.purpose == "external"
      assert Dispatches.state(dispatch) == "held"

      assert %External{state: "held", units_reserved: %{"flow_credits" => 40}, worktree_path: nil} =
               Externals.get(dispatch.id)

      assert Dispatches.usage(ctx.grant).units == %{"flow_credits" => 40}
      # A grant's pre-approval never starts it: only the person does.
      assert Dispatches.advance(dispatch) == :none
      assert Dispatches.state(dispatch) == "held"

      # Not even when its goal looks held for a pre-approval (a held review
      # here): the EXTERNAL rule, not a missing execution, refuses it.
      held = fn _goal_id ->
        {:ok,
         %{
           completed?: false,
           needs_user?: false,
           cancelled?: false,
           reviews: [%{state: "held", review_id: Ecto.UUID.generate(), calls: 0}],
           last_admission: nil
         }}
      end

      assert Dispatches.advance(dispatch, held) == :none
      assert Repo.get!(Grants.Grant, ctx.grant.id).unread_usage_used == 0
      assert %External{state: "held", confirmed_by: nil} = Externals.get(dispatch.id)
    end

    test "the grant must allow EXTERNAL; units must be the grant's and fit its cap", ctx do
      # Over the cap: 40 + 40 + 40 > 100. Refused before any worktree exists.
      started!(ctx)
      started!(ctx)

      assert {:error, {:outside_grant, :units}} = Dispatches.create(request(ctx))
      refute File.exists?(ctx.worktrees)

      assert {:error, {:outside_grant, :units}} =
               Dispatches.create(request(ctx, %{units: ["paper=1"]}))

      {:ok, grant} = Grants.revoke(ctx.grant, @by)
      _ = grant

      {:ok, _} =
        Grants.create(
          %{
            session_id: ctx.session,
            repository_root: ctx.repo,
            models: ["codex:gpt-6-luna"],
            purposes: ~w(implement),
            max_dispatches: 3,
            max_parallel: 1,
            max_total_seconds: 3600,
            max_dispatch_seconds: 3600,
            unread_usage: 0
          },
          @by
        )

      assert {:error, {:outside_grant, :purpose}} = Dispatches.create(request(ctx))
    end

    test "an EXTERNAL is never a batch member", ctx do
      assert {:error, :external_not_in_batch} =
               Dispatches.create(request(ctx, %{tasks: [%{"title" => "one", "files" => ["a"]}]}))
    end

    test "a reservation survives a restart: read fresh, replayed once, never duplicated", ctx do
      # One request id, exactly as the coordinator's client would resend it
      # after a restart between the reserve and the start.
      req = %{request(ctx) | request_id: "restart-once"}
      assert {:ok, dispatch, :recorded} = fresh!(ctx, fn -> Dispatches.create(req) end)

      # Every step below runs in a fresh process with its own connection to
      # the same rows: the closest hermetic analogue of a restart between
      # the reserve and the start.
      assert fresh!(ctx, fn -> Dispatches.usage(fresh_grant(ctx)).units end) ==
               %{"flow_credits" => 40}

      assert {:ok, replayed, :replayed} = fresh!(ctx, fn -> Dispatches.create(req) end)
      assert replayed.id == dispatch.id

      # The replay reserved nothing more: one row, one reserve.
      assert [%External{}] = fresh!(ctx, fn -> Repo.all(External) end)

      assert fresh!(ctx, fn -> Dispatches.usage(fresh_grant(ctx)).units end) == %{
               "flow_credits" => 40
             }

      assert :confirmed =
               fresh!(ctx, fn ->
                 Externals.confirm(dispatch, @by, worktrees_dir: ctx.worktrees)
               end)

      assert fresh!(ctx, fn -> Dispatches.usage(fresh_grant(ctx)).units end) == %{
               "flow_credits" => 40
             }

      %{worktree_path: path} = Externals.get(dispatch.id)
      commit_in!(path)

      assert {:ok, %External{state: "completed"}} =
               fresh!(ctx, fn -> Externals.complete(dispatch, @by, %{}, passing()) end)

      # Settled with no reported actual: the reserve is kept, exactly once.
      assert fresh!(ctx, fn -> Dispatches.usage(fresh_grant(ctx)).units end) == %{
               "flow_credits" => 40
             }
    end
  end

  describe "confirmation" do
    test "makes a private worktree from the pinned base, writes the brief and starts the clock",
         ctx do
      dispatch = started!(ctx)

      assert {:error, :non_human_identity} =
               Externals.confirm(dispatch, "grant:x", worktrees_dir: ctx.worktrees)

      before = Externals.source(ctx.repo)

      assert :confirmed = Dispatches.confirm_hold(dispatch, @by)

      external = Externals.get(dispatch.id)
      assert external.state == "awaiting"
      assert Dispatches.state(dispatch) == "running"
      assert external.base_commit == dispatch.base_revision

      assert File.read!(Path.join(external.worktree_path, ".shoestring/brief.md")) =~
               "Work in this directory only: #{external.worktree_path}"

      # The brief is not part of the result, and the person's checkout is untouched.
      assert {"", 0} = System.cmd("git", ["-C", external.worktree_path, "status", "--porcelain"])
      assert external.source_before == before
      assert Externals.source(ctx.repo) == before
      assert DateTime.diff(external.deadline_at, external.confirmed_at) == 3600

      # Confirming twice does nothing more.
      assert Externals.confirm(dispatch, @by) == :none
    end
  end

  describe "completion" do
    test "an operator's commit passes the checks: completed, units settled, take commands", ctx do
      {dispatch, external} = confirmed!(ctx)
      sha = commit_in!(external.worktree_path)

      assert {:error, :non_human_identity} =
               Externals.complete(dispatch, "grant:x", %{}, passing())

      assert {:ok, %External{state: "completed", commit: ^sha} = done} =
               Externals.complete(dispatch, @by, %{"flow_credits" => 25}, passing())

      assert [%{"gate" => "python_unittest", "exit_status" => 0}] = done.checks
      assert Dispatches.state(dispatch) == "completed"
      assert Dispatches.usage(ctx.grant).units == %{"flow_credits" => 25}

      assert ["cd " <> _, "git fetch " <> fetch, "git merge FETCH_HEAD"] =
               Externals.take(dispatch, done)

      assert fetch =~ sha
      refute Externals.source_changed?(done)
      assert {:error, :already_finished} = Externals.complete(dispatch, @by, %{}, passing())
    end

    test "an untracked file or no commit leaves it needs_you; it can be completed again", ctx do
      {dispatch, external} = confirmed!(ctx)

      assert {:ok, %External{state: "needs_you", failure: "no_commit"}} =
               Externals.complete(dispatch, @by, %{}, passing())

      commit_in!(external.worktree_path)
      File.write!(Path.join(external.worktree_path, "stray.txt"), "left over\n")

      assert {:ok, %External{state: "needs_you", failure: "gate_worktree_dirty", attempts: 2}} =
               Externals.complete(dispatch, @by, %{}, passing())

      assert Dispatches.state(dispatch) == "needs_you"
      File.rm!(Path.join(external.worktree_path, "stray.txt"))

      assert {:ok, %External{state: "completed", attempts: 3}} =
               Externals.complete(dispatch, @by, %{}, passing())
    end

    test "a failing check leaves it needs_you with the check named", ctx do
      {dispatch, external} = confirmed!(ctx)
      commit_in!(external.worktree_path)

      failing = [
        gate_runner_opts: [
          runner: fn _argv, _wt, _t ->
            {:ok, %{exit_status: 1, output: "FAILED", duration_ms: 2}}
          end
        ]
      ]

      assert {:ok, %External{state: "needs_you", failure: "check_failed:python_unittest"}} =
               Externals.complete(dispatch, @by, %{}, failing)
    end

    test "a completion past the deadline is allowed and recorded as expired", ctx do
      {dispatch, external} = confirmed!(ctx)
      commit_in!(external.worktree_path)
      later = DateTime.add(external.deadline_at, 60, :second)
      assert Externals.expired?(external, later)

      assert {:ok, %External{state: "completed", expired: true}} =
               Externals.complete(dispatch, @by, %{}, Keyword.put(passing(), :now, later))
    end

    test "the checks run under the gate sandbox", ctx do
      {dispatch, external} = confirmed!(ctx)
      commit_in!(external.worktree_path)

      assert {:ok, %External{state: "completed", checks: [check]}} =
               Externals.complete(dispatch, @by, %{}, worktrees_dir: ctx.worktrees)

      assert check["sandboxed"] == true
      assert check["exit_status"] == 0
    end

    test "a change to the person's checkout during the work is reported", ctx do
      {dispatch, external} = confirmed!(ctx)
      commit_in!(external.worktree_path)
      File.write!(Path.join(ctx.repo, "touched.txt"), "an outside program wrote here\n")

      assert {:ok, done} = Externals.complete(dispatch, @by, %{}, passing())
      assert Externals.source_changed?(done)
    end

    test "a unit it did not reserve cannot be reported", ctx do
      {dispatch, external} = confirmed!(ctx)
      commit_in!(external.worktree_path)

      assert {:error, :unknown_unit} =
               Externals.complete(dispatch, @by, %{"paper" => 1}, passing())
    end
  end

  describe "abandonment" do
    test "keeps the worktree and the reserve; only a person, with a reason", ctx do
      {dispatch, external} = confirmed!(ctx)
      assert {:error, :non_human_identity} = Externals.abandon(dispatch, "grant:x", "no")
      assert {:error, :reason_required} = Externals.abandon(dispatch, @by, "  ")

      assert {:ok, %External{state: "abandoned"}} =
               Externals.abandon(dispatch, @by, "The web app was down.")

      assert File.dir?(external.worktree_path)
      assert Dispatches.state(dispatch) == "cancelled"
      assert Dispatches.usage(ctx.grant).units == %{"flow_credits" => 40}

      # A coordinator's cancel cannot abandon it: that is the person's.
      other = started!(ctx)
      assert {:error, :non_human_identity} = Dispatches.cancel(other, "stop")
    end
  end

  describe "chaining" do
    test "an EXTERNAL that follows another starts from its verified commit", ctx do
      {first, external} = confirmed!(ctx)
      sha = commit_in!(external.worktree_path)

      assert {:ok, second, _} =
               Dispatches.create(
                 request(ctx, %{after_dispatch: first.id, units: ["flow_credits=10"]})
               )

      assert second.state == "chained"
      assert Dispatches.follow(second) == :waiting

      assert {:ok, %External{state: "completed"}} = Externals.complete(first, @by, %{}, passing())
      assert {:ok, second, :recorded} = Dispatches.follow(second)
      assert second.base_revision == sha

      assert :confirmed = Externals.confirm(second, @by, worktrees_dir: ctx.worktrees)
      %External{worktree_path: path, base_commit: ^sha} = Externals.get(second.id)
      assert File.read!(Path.join(path, "sheet.txt")) == "a sheet\n"
    end
  end

  defp fresh_grant(ctx), do: Repo.get!(Grants.Grant, ctx.grant.id)

  # Runs `fun` in a fresh process with its own connection to the same rows.
  defp fresh!(ctx, fun) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        receive do
          :go ->
            Ecto.Adapters.SQL.Sandbox.allow(Shoestring.Repo, parent, self())
            send(parent, {ref, fun.()})
        end
      end)

    send(pid, :go)
    assert_receive {^ref, result}, 15_000
    result
  end
end
