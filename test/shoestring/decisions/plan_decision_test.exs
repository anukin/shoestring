defmodule Shoestring.Decisions.PlanDecisionTest do
  @moduledoc """
  Iteration 19 Package A: a plan task declares a decision; after its gates
  pass the plan waits, before the task's dependents, for a person's answer.

  Hermetic: Fake-grade admission, an injected gate runner (no OS process),
  a temporary directory standing in for the task's worktree, and synthetic
  solid-colour PNG candidates generated here.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.{Cobbler, Decisions, Repo}
  alias Shoestring.Decisions.Decision
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers}
  alias Shoestring.Trajectory.{ArtifactStore, TrajectoryEvent}

  import PlanExecutorHelpers,
    only: [admit!: 1, complete_run!: 2, propose_and_approve!: 2]

  import Shoestring.Test.DecisionHelpers

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    goal = CobblerHelpers.create_goal!()
    %{goal: goal, worktree: dir}
  end

  defp pending!(goal) do
    assert [%Decision{state: "pending"} = decision] = Decisions.list(goal_ids: [goal.id])
    decision
  end

  defp no_resume, do: [resume_fun: fn _goal, _execution -> :ok end]

  defp events(goal, type) do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal.id and e.type == ^type,
        order_by: [asc: e.sequence]
    )
  end

  # --------------------------------------------------------------------------
  # The pause
  # --------------------------------------------------------------------------

  test "after its gates pass, the deciding task waits for a person and its dependent does not start",
       %{goal: goal, worktree: worktree} do
    options = write_candidates!(worktree)
    result = run_sheets!(goal, worktree)
    assert result.disposition == :accepted

    decision = pending!(goal)
    assert decision.key == "sheet"
    assert decision.question == "Which reference sheet should the story use?"
    assert decision.note == "Three takes."
    assert decision.allow_reject
    assert Enum.map(decision.options, & &1["key"]) == ["red", "green", "blue"]
    assert Decisions.choices(decision) == ["red", "green", "blue", "reject"]

    # Every candidate is stored with its exact bytes.
    for {option, stored} <- Enum.zip(options, decision.options) do
      bytes = File.read!(Path.join(worktree, option["file"]))

      assert {:ok, %{artifact: artifact, bytes: ^bytes}} =
               ArtifactStore.read(stored["artifact_id"])

      assert artifact.sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      assert artifact.media_type == "image/png"
      refute artifact.redacted
    end

    assert [%{payload: %{"decision_id" => id}}] = events(goal, "cobbler.plan.decision.requested")
    assert id == decision.id

    assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
    assert status.accepted == []
    assert status.awaiting_decision == ["sheets"]
    assert status.needs_user?
    refute status.completed?

    # Advancing never starts the dependent, nor re-runs the deciding task.
    assert {:ok, %{disposition: :blocked}} =
             Cobbler.advance_plan_execution(
               goal.id,
               opts(worktree, admission_event_id: admit!(goal).id)
             )

    assert PlanExecutorHelpers.run_count(goal.id) == 1
  end

  test "a pending decision is held by no process: answering later, from another process, resumes the plan",
       %{goal: goal, worktree: worktree} do
    write_candidates!(worktree)
    run_sheets!(goal, worktree)
    decision = pending!(goal)
    parent = self()

    # The answer arrives from an unrelated process (the web, the CLI), not
    # from anything that took part in the run.
    task =
      Task.async(fn ->
        Decisions.answer(decision.id, "green", "The green one reads best.", "human:test",
          resume_fun: fn goal_id, execution_id ->
            send(parent, {:resume, goal_id, execution_id})
          end
        )
      end)

    assert {:ok, %Decision{state: "answered", answer_key: "green", decided_by: "human:test"}} =
             Task.await(task)

    execution_id = decision.execution_id
    goal_id = goal.id
    assert_receive {:resume, ^goal_id, ^execution_id}

    assert [%{actor: "human", payload: %{"answer" => "choose", "option_key" => "green"}}] =
             events(goal, "cobbler.plan.decision.answered")

    assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
    assert status.accepted == ["sheets"]
    assert status.awaiting_decision == []
    refute status.needs_user?

    assert {:ok, %{disposition: :dispatched, plan_task_id: "story", run_id: run_id}} =
             Cobbler.advance_plan_execution(
               goal.id,
               opts(worktree, admission_event_id: admit!(goal).id)
             )

    # The dependent's inputs carry the chosen key, label, artifact and path.
    prompt = Repo.get!(Shoestring.Harness.RunRecord, run_id).prompt
    chosen = Enum.find(decision.options, &(&1["key"] == "green"))
    assert prompt =~ ~s("key":"green")
    assert prompt =~ chosen["artifact_id"]
    assert prompt =~ ".shoestring/decisions/sheet/green.png"
    assert prompt =~ "The green one reads best."
    refute prompt =~ Enum.find(decision.options, &(&1["key"] == "red"))["artifact_id"]
  end

  test "the first answer wins; a second answer and a non-human identity are refused",
       %{goal: goal, worktree: worktree} do
    write_candidates!(worktree)
    run_sheets!(goal, worktree)
    decision = pending!(goal)

    assert {:error, :non_human_identity} =
             Decisions.answer(decision.id, "red", nil, "grant:session-1", no_resume())

    assert {:error, :non_human_identity} =
             Decisions.answer(decision.id, "red", nil, "coordinator", no_resume())

    assert {:error, :unknown_option} =
             Decisions.answer(decision.id, "purple", nil, "human:test", no_resume())

    assert {:ok, _} = Decisions.answer(decision.id, "red", nil, "human:test", no_resume())

    assert {:error, :already_answered} =
             Decisions.answer(decision.id, "blue", nil, "human:other", no_resume())

    assert {:error, :already_answered} =
             Decisions.answer(decision.id, "reject", "None.", "human:other", no_resume())

    assert %Decision{answer_key: "red", decided_by: "human:test"} = Decisions.get(decision.id)
    assert [_one] = events(goal, "cobbler.plan.decision.answered")
  end

  test "concurrent answers: exactly one wins", %{goal: goal, worktree: worktree} do
    write_candidates!(worktree)
    run_sheets!(goal, worktree)
    decision = pending!(goal)

    results =
      ["red", "green", "blue", "red"]
      |> Enum.with_index()
      |> Enum.map(fn {key, n} ->
        Task.async(fn -> Decisions.answer(decision.id, key, nil, "human:p#{n}", no_resume()) end)
      end)
      |> Task.await_many(10_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_answered})) == 3
    assert [_one] = events(goal, "cobbler.plan.decision.answered")
  end

  test "the waiting task releases the sequential task claim", %{goal: goal, worktree: worktree} do
    write_candidates!(worktree)
    run_sheets!(goal, worktree)
    pending!(goal)
    assert is_nil(Shoestring.Cobbler.Commands.active_claim())
  end

  test "two goals running the same plan each get their own decision",
       %{goal: goal, worktree: worktree} do
    write_candidates!(worktree)
    other = CobblerHelpers.create_goal!()

    assert %{disposition: :accepted} = run_sheets!(goal, worktree)
    assert %{disposition: :accepted} = run_sheets!(other, worktree)

    mine = pending!(goal)
    theirs = pending!(other)
    assert mine.id != theirs.id
    assert mine.execution_id == theirs.execution_id

    assert {:ok, _} = Decisions.answer(theirs.id, "red", nil, "human:test", no_resume())
    assert %Decision{state: "pending"} = Decisions.get(mine.id)
  end

  test "the chosen candidate is copied into the dependent's worktree from the store",
       %{goal: goal, worktree: worktree, tmp_dir: tmp} do
    write_candidates!(worktree)
    run_sheets!(goal, worktree)
    decision = pending!(goal)
    green = Enum.find(decision.options, &(&1["key"] == "green"))
    input = %{"path" => green["file"], "artifact_id" => green["artifact_id"]}

    dependent = Path.join(tmp, "dependent")
    File.mkdir_p!(dependent)
    assert :ok = Decisions.materialize(dependent, [input])

    assert File.read!(Path.join(dependent, green["file"])) ==
             File.read!(Path.join(worktree, green["file"]))

    # A committed path is already in the tree: nothing is written for it.
    assert :ok = Decisions.materialize(dependent, [%{input | "path" => "art/green.png"}])
    refute File.exists?(Path.join(dependent, "art/green.png"))

    # A linked directory on the way is refused, and so is a missing artifact.
    linked = Path.join(tmp, "linked")
    File.mkdir_p!(linked)
    elsewhere = Path.join(tmp, "elsewhere")
    File.mkdir_p!(elsewhere)
    File.ln_s!(elsewhere, Path.join(linked, ".shoestring"))

    assert {:error, {:decision_input_unavailable, _, :symlink}} =
             Decisions.materialize(linked, [input])

    assert File.ls!(elsewhere) == []

    assert {:error, {:decision_input_unavailable, _, _}} =
             Decisions.materialize(dependent, [%{input | "artifact_id" => Ecto.UUID.generate()}])
  end

  # --------------------------------------------------------------------------
  # "None of these"
  # --------------------------------------------------------------------------

  test "reject needs a note and leaves the task for a person; nothing retries it",
       %{goal: goal, worktree: worktree} do
    write_candidates!(worktree)
    run_sheets!(goal, worktree)
    decision = pending!(goal)

    assert {:error, :note_required} =
             Decisions.answer(decision.id, "reject", nil, "human:test", no_resume())

    assert {:error, :note_required} =
             Decisions.answer(decision.id, "reject", "   ", "human:test", no_resume())

    assert {:ok, %Decision{state: "rejected", answer_note: "All three miss the brief."}} =
             Decisions.answer(
               decision.id,
               "reject",
               "All three miss the brief.",
               "human:test",
               no_resume()
             )

    assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
    assert status.accepted == []
    assert status.awaiting_decision == []
    assert status.needs_user?
    assert [%{resolution: :gate_failed, retry_state: "needs_user"}] = status.children

    assert {:ok, %{disposition: :blocked}} =
             Cobbler.advance_plan_execution(
               goal.id,
               opts(worktree, admission_event_id: admit!(goal).id)
             )

    assert PlanExecutorHelpers.run_count(goal.id) == 1
  end

  test "a decision that does not allow reject refuses it", %{goal: goal, worktree: worktree} do
    write_candidates!(worktree)
    run_sheets!(goal, worktree, decision_plan(decision(%{"allow_reject" => false})))
    decision = pending!(goal)
    assert Decisions.choices(decision) == ["red", "green", "blue"]

    assert {:error, :reject_not_allowed} =
             Decisions.answer(decision.id, "reject", "None.", "human:test", no_resume())
  end

  # --------------------------------------------------------------------------
  # Withdrawal
  # --------------------------------------------------------------------------

  test "cancelling the goal withdraws the pending decision and keeps its artifacts",
       %{goal: goal, worktree: worktree} do
    write_candidates!(worktree)
    run_sheets!(goal, worktree)
    decision = pending!(goal)

    assert {:ok, _} =
             Shoestring.Cobbler.PlanCancellation.request(
               goal.id,
               %{
                 command_id: Ecto.UUID.generate(),
                 execution_id: decision.execution_id,
                 scope: "goal",
                 requested_by: "human:test",
                 reason: "Changed the story."
               },
               oban: Oban
             )

    assert %Decision{state: "withdrawn"} = Decisions.get(decision.id)
    assert [_] = events(goal, "cobbler.plan.decision.withdrawn")

    assert {:error, :decision_withdrawn} =
             Decisions.answer(decision.id, "red", nil, "human:test", no_resume())

    for option <- decision.options,
        do: assert({:ok, _} = ArtifactStore.read(option["artifact_id"]))
  end

  # --------------------------------------------------------------------------
  # A malformed decision file is a gate failure, never a crash
  # --------------------------------------------------------------------------

  defp assert_gate_failure(goal, worktree, reason_pattern) do
    result = run_sheets!(goal, worktree)
    assert result.disposition == :gate_failed
    assert result.reason =~ reason_pattern
    assert Decisions.list(goal_ids: [goal.id]) == []
    assert events(goal, "cobbler.plan.decision.requested") == []

    assert [%{payload: %{"gate" => "decision"}}] = events(goal, "cobbler.plan.task.gate_failed")
    assert {:ok, %{accepted: []}} = Cobbler.plan_execution_status(goal.id)
  end

  test "13 options fail the gate", %{goal: goal, worktree: worktree} do
    colours = for n <- 1..13, do: {"c#{n}", {n, n, n}}
    write_candidates!(worktree, colours: colours)
    assert_gate_failure(goal, worktree, "at most 12 options")
  end

  test "a .. path fails the gate", %{goal: goal, worktree: worktree} do
    [first | rest] = write_candidates!(worktree)

    write_candidates!(worktree,
      file: %{"id" => "sheet", "options" => [%{first | "file" => "../outside.png"} | rest]}
    )

    assert_gate_failure(goal, worktree, ".. parts")
  end

  test "a symlinked candidate fails the gate", %{goal: goal, worktree: worktree} do
    [first | rest] = write_candidates!(worktree)

    outside =
      Path.join(Path.dirname(worktree), "outside-#{System.unique_integer([:positive])}.png")

    File.write!(outside, png({1, 2, 3}))
    link = Path.join(worktree, ".shoestring/decisions/sheet/link.png")
    File.ln_s!(outside, link)

    write_candidates!(worktree,
      file: %{
        "id" => "sheet",
        "options" => [%{first | "file" => ".shoestring/decisions/sheet/link.png"} | rest]
      }
    )

    assert_gate_failure(goal, worktree, "symlink")
  end

  test "a missing decision file fails the gate", %{goal: goal, worktree: worktree} do
    assert_gate_failure(goal, worktree, "does not exist")
  end

  test "fewer options than the plan's minimum fail the gate", %{goal: goal, worktree: worktree} do
    write_candidates!(worktree, colours: [{"red", {255, 0, 0}}])
    assert_gate_failure(goal, worktree, "at least 2 options")
  end

  test "a candidate over the artifact cap fails with how to fix it",
       %{goal: goal, worktree: worktree} do
    write_candidates!(worktree)
    rev = propose_and_approve!(goal, decision_plan())
    admission = admit!(goal)

    assert {:ok, _} =
             Cobbler.request_plan_execution(
               goal.id,
               %{
                 revision_number: rev.revision_number,
                 digest: rev.digest,
                 admission_event_id: admission.id
               },
               opts(worktree)
             )

    assert {:ok, first} =
             Cobbler.advance_plan_execution(
               goal.id,
               opts(worktree, admission_event_id: admission.id)
             )

    complete_run!(goal, first.run_id)

    assert {:ok, %{disposition: :gate_failed, reason: reason}} =
             Cobbler.complete_plan_task_run(
               goal.id,
               first.run_id,
               opts(worktree, artifact_max_size: 16)
             )

    assert reason =~ "artifact limit"
    assert reason =~ "source"
  end

  test "an option keyed reject is refused", %{goal: goal, worktree: worktree} do
    [first | rest] = write_candidates!(worktree)

    write_candidates!(worktree,
      file: %{"id" => "sheet", "options" => [%{first | "key" => "reject"} | rest]}
    )

    assert_gate_failure(goal, worktree, "reserved")
  end
end
