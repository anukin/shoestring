defmodule Shoestring.CLI.DecisionTest do
  @moduledoc """
  Iteration 19 Package C: `shoestring decision list|show|answer` in a
  terminal, `runs show` naming a pending decision and the command that
  answers it, and the coordinator's read-only MCP tools (none answers).
  Hermetic: fixture sessions, an injected gate runner, synthetic PNGs.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.SessionsFixtures
  import Shoestring.Test.DecisionHelpers

  alias Shoestring.CLI.Commands.{Decision, Runs}
  alias Shoestring.CLI.{Follow, Refusal}
  alias Shoestring.Coordinator.Tools
  alias Shoestring.Decisions
  alias Shoestring.Trajectory.ArtifactStore

  @moduletag :tmp_dir

  setup %{tmp_dir: worktree} do
    ctx = session()
    goal = Shoestring.Test.CobblerHelpers.create_goal!()
    builder = dispatch_fixture(ctx, "implement", "builder", "Draw the reference sheets")

    Repo.update_all(from(d in Shoestring.Dispatches.Dispatch, where: d.id == ^builder.id),
      set: [goal_id: goal.id]
    )

    write_candidates!(worktree)

    assert %{disposition: :accepted} =
             run_sheets!(goal, worktree, decision_plan(), repository_path: worktree)

    [decision] = Decisions.list(goal_ids: [goal.id])

    Map.merge(ctx, %{
      goal: goal,
      builder: Shoestring.Dispatches.get(builder.id),
      decision: decision,
      short: String.slice(decision.id, 0, 8)
    })
  end

  defp context(opts \\ []) do
    %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end,
      cwd: File.cwd!(),
      interactive?: fn -> Keyword.get(opts, :interactive, true) end,
      env: fn _ -> nil end,
      # The command line's job client; the test's manual Oban stands in.
      jobs: fn fun ->
        send(self(), :jobs_client)
        fun.(Oban)
      end
    }
  end

  defp output do
    receive do
      {:mix_shell, :info, [text]} -> text
    after
      1_000 -> flunk("no output")
    end
  end

  describe "shoestring decision" do
    test "list shows what waits on the person and how to answer it", ctx do
      Decision.run(["list"], context())
      text = output()
      assert text =~ ctx.short
      assert text =~ "sheets"
      assert text =~ "Which reference sheet should the story use?"
      assert text =~ "red  A red sheet"
      assert text =~ "shoestring decision answer #{ctx.short} --choose KEY"
      assert text =~ "--reject --note"

      Decision.run(["list", "--goal", ctx.goal.id, "--json"], context())
      assert [%{"decision_id" => id, "state" => "pending"}] = Jason.decode!(output())
      assert id == ctx.decision.id
    end

    test "show prints each option's file under the state directory and the web page", ctx do
      Decision.run(["show", ctx.short], context())
      text = output()
      root = ArtifactStore.root()

      for option <- ctx.decision.options do
        artifact = Repo.get!(Shoestring.Trajectory.Artifact, option["artifact_id"])
        assert text =~ "#{option["key"]}  #{option["label"]}  (image/png)"
        assert text =~ "file: #{Path.join(root, artifact.location)}"
      end

      # At the web UI's own host name: its live connection refuses another origin.
      assert text =~ "http://localhost:"
      refute text =~ "127.0.0.1"
      assert text =~ "/cobbler/goals/#{ctx.goal.id}"
      assert text =~ "nothing decides this on a timer"
    end

    test "answer needs a terminal and a human identity, and the first answer wins", ctx do
      assert_raise Refusal, ~r/person's choice/, fn ->
        Decision.run(["answer", ctx.short, "--choose", "red"], context(interactive: false))
      end

      assert_raise Refusal, ~r/human:NAME/, fn ->
        Decision.run(["answer", ctx.short, "--choose", "red", "--by", "grant:x"], context())
      end

      assert_raise Refusal, ~r/needs --note/, fn ->
        Decision.run(["answer", ctx.short, "--reject"], context())
      end

      assert_raise Refusal, ~r/not both/, fn ->
        Decision.run(["answer", ctx.short, "--choose", "red", "--reject"], context())
      end

      assert_raise Refusal, ~r/not one of its options/, fn ->
        Decision.run(["answer", ctx.short, "--choose", "purple"], context())
      end

      assert Decisions.get(ctx.decision.id).state == "pending"

      Decision.run(["answer", ctx.short, "--choose", "green", "--by", "human:pat"], context())

      # The plan is queued again through the command line's job client, and
      # the command says so.
      assert %{"state" => "answered", "answer" => "green", "plan" => "queued"} =
               Jason.decode!(output())

      assert_received :jobs_client

      assert Repo.exists?(
               from j in Oban.Job,
                 where:
                   j.worker == "Shoestring.Cobbler.PlanExecutionWorker" and j.state == "available" and
                     fragment("json_extract(?, '$.goal_id')", j.args) == ^ctx.goal.id
             )

      assert_raise Refusal, ~r/already answered/, fn ->
        Decision.run(["answer", ctx.short, "--reject", "--note", "No."], context())
      end

      assert %{state: "answered", answer_key: "green", decided_by: "human:pat"} =
               Decisions.get(ctx.decision.id)
    end

    test "an unknown or ambiguous id is refused" do
      assert_raise Refusal, ~r/No such decision/, fn ->
        Decision.run(["show", "ffffffff"], context())
      end

      assert_raise Refusal, ~r/No such decision/, fn ->
        Decision.run(["show", "../etc"], context())
      end
    end
  end

  describe "runs show and follow" do
    test "runs show names the pending decision and the command that answers it", ctx do
      detail = Runs.detail(ctx.builder)
      assert [%{"decision_id" => id, "task" => "sheets"}] = detail["decisions"]
      assert id == ctx.decision.id
      assert detail["next"] =~ "choose among the candidates task sheets produced"
      assert detail["next"] =~ "shoestring decision answer #{ctx.short} --choose KEY"
      assert detail["next"] =~ "You cannot answer for them."
    end

    test "follow prints the decision events in plain words", ctx do
      [event] =
        Repo.all(
          from e in Shoestring.Trajectory.TrajectoryEvent,
            where: e.goal_id == ^ctx.goal.id and e.type == "cobbler.plan.decision.requested"
        )

      assert Follow.line(event) =~ "Task sheets: waits for you to choose among 3 candidates"
      assert Follow.line(event) =~ "shoestring decision show #{ctx.short}"
    end
  end

  describe "the coordinator's tools" do
    test "list and show this session's decisions, and nothing answers one", ctx do
      binding = %{session_id: ctx.session, repository_root: ctx.repo}

      assert {:ok, [%{"decision_id" => id, "state" => "pending", "options" => options}]} =
               Tools.call("decisions_list", %{}, binding)

      assert id == ctx.decision.id
      assert Enum.map(options, & &1["key"]) == ["red", "green", "blue"]

      assert {:ok, %{"who_answers" => who}} =
               Tools.call("decisions_show", %{"decision" => id}, binding)

      assert who =~ "the person"

      # Another session, with a dispatch of its own, sees none of them.
      other = session()
      _ = dispatch_fixture(other, "implement", "builder", "Something else")
      other_binding = %{session_id: other.session, repository_root: other.repo}
      assert {:ok, []} = Tools.call("decisions_list", %{}, other_binding)

      assert {:error, "No such decision in this session."} =
               Tools.call("decisions_show", %{"decision" => id}, other_binding)

      # No tool answers: every tool, called with what an answer would carry,
      # leaves the decision pending.
      names = Enum.map(Tools.list(), & &1["name"])

      refute Enum.any?(
               names,
               &(&1 =~ ~r/decide_decision|decision_answer|decisions_answer|choose/)
             )

      for name <- names do
        _ =
          Tools.call(
            name,
            %{"decision" => id, "decision_id" => id, "choice" => "red", "key" => "red"},
            binding
          )
      end

      assert Decisions.get(id).state == "pending"
    end
  end
end
