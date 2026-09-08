defmodule Shoestring.Harness.ContinuationTest do
  @moduledoc """
  Hermetic tests for `Shoestring.Harness.Continuation` bounds and locks.

  Status per the standing contract: DOCUMENTATION, not regression locks.
  Every test here exercises the new `Shoestring.Harness.Continuation`
  module, so on the base commit (`d3ca088`) this file fails to compile
  with a missing-module error. That is the T1 precedent for new-surface
  documentation: it records intended behaviour without claiming to lock a
  pre-existing defect.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.{CheckpointRecord, Continuation, RunRequest}
  alias Shoestring.Repo
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers

  @goal_id "01950000-0000-7000-8000-0000000000a1"
  @task_id "01950000-0000-7000-8000-0000000000a2"
  @run_a "01950000-0000-7000-8000-0000000000a3"
  @run_b "01950000-0000-7000-8000-0000000000a4"

  describe "bounds are explicit module attributes" do
    test "caps are pinned and queryable" do
      assert Continuation.max_history() == 50
      assert Continuation.max_next_action_chars() == 2_000
      assert Continuation.truncation_marker() == "…[truncated]"
      assert Continuation.max_decision_refs() == 32
      assert Continuation.resumable_lease_statuses() == ["granted", "active", "renewed"]
    end
  end

  describe "project_latest/2 pure projection" do
    test "empty history returns :no_checkpoint" do
      assert Continuation.project_latest([], []) == {:error, :no_checkpoint}
    end

    test "picks the latest sequence deterministically" do
      checkpoints = [
        %{id: @run_a, projection_sequence: 3, next_action: "third"},
        %{id: @run_b, projection_sequence: 9, next_action: "ninth"},
        %{id: @goal_id, projection_sequence: 1, next_action: "first"}
      ]

      assert {:ok, cont} = Continuation.project_latest(checkpoints, [])
      assert cont.checkpoint_id == @run_b
      assert cont.next_action == "ninth"
      assert cont.decision_refs == []

      # Deterministic: repeated projection is identical.
      assert Continuation.project_latest(checkpoints, []) == {:ok, cont}
      assert Continuation.project_latest(Enum.reverse(checkpoints), []) == {:ok, cont}
    end

    test "ties on projection_sequence break by ascending id" do
      low = "01950000-0000-7000-8000-000000000001"
      high = "01950000-0000-7000-8000-000000000002"

      checkpoints = [
        %{id: high, projection_sequence: 5, next_action: "high"},
        %{id: low, projection_sequence: 5, next_action: "low"}
      ]

      assert {:ok, cont} = Continuation.project_latest(checkpoints, [])
      assert cont.checkpoint_id == low
      assert cont.next_action == "low"
    end

    test "next_action longer than 2000 chars is truncated with a marker" do
      long = String.duplicate("a", 2_001)
      checkpoints = [%{id: @run_a, projection_sequence: 1, next_action: long}]

      assert {:ok, cont} = Continuation.project_latest(checkpoints, [])
      assert String.length(cont.next_action) == 2_000 + String.length("…[truncated]")
      assert String.ends_with?(cont.next_action, "…[truncated]")

      exact = String.duplicate("b", 2_000)

      assert {:ok, exact_cont} =
               Continuation.project_latest(
                 [%{id: @run_a, projection_sequence: 1, next_action: exact}],
                 []
               )

      assert exact_cont.next_action == exact
    end

    test "decision_refs keep only the latest 32" do
      refs = Enum.map(1..40, fn _ -> Ecto.UUID.generate() end)
      checkpoints = [%{id: @run_a, projection_sequence: 1, next_action: "go"}]

      assert {:ok, cont} = Continuation.project_latest(checkpoints, refs)
      assert cont.decision_refs == Enum.take(refs, -32)
      assert length(cont.decision_refs) == 32
    end

    test "history beyond 50 rows is ignored structurally" do
      checkpoints =
        Enum.map(1..55, fn seq ->
          %{id: Ecto.UUID.generate(), projection_sequence: seq, next_action: "step #{seq}"}
        end)

      assert {:ok, cont} = Continuation.project_latest(checkpoints, [])
      assert cont.next_action == "step 55"
    end
  end

  describe "validate_attrs/1 forbidden-key lock" do
    test "every forbidden key in continuation attrs is rejected" do
      base = %{
        checkpoint_id: Ecto.UUID.generate(),
        next_action: "continue",
        decision_refs: []
      }

      for key <- Continuation.forbidden_keys() do
        assert {:error, {:forbidden_continuation_key, _}} =
                 Continuation.validate_attrs(Map.put(base, key, "smuggled")),
               "expected rejection for forbidden key #{key}"

        assert {:error, {:forbidden_continuation_key, _}} =
                 Continuation.validate_attrs(Map.put(base, Atom.to_string(key), "smuggled")),
               "expected rejection for forbidden string key #{key}"
      end
    end

    test "RunRequest struct keys do not smuggle into continuation attrs" do
      struct_keys =
        %RunRequest{
          version: 1,
          goal_id: Ecto.UUID.generate(),
          task_id: Ecto.UUID.generate(),
          workspace_ref: "workspace/test",
          prompt: "prompt",
          continuation: nil,
          policy: %{},
          requested_capabilities: [],
          dispatch_id: Ecto.UUID.generate(),
          extensions: %{}
        }
        |> Map.keys()
        |> Enum.reject(&(&1 == :__struct__))

      assert Enum.sort(struct_keys) ==
               Enum.sort([
                 :version,
                 :goal_id,
                 :task_id,
                 :workspace_ref,
                 :prompt,
                 :continuation,
                 :policy,
                 :requested_capabilities,
                 :dispatch_id,
                 :extensions
               ])

      base = %{
        "checkpoint_id" => Ecto.UUID.generate(),
        "next_action" => "continue",
        "decision_refs" => []
      }

      for key <- struct_keys,
          Atom.to_string(key) not in ["checkpoint_id", "next_action", "decision_refs"] do
        assert {:error, _} = Continuation.validate_attrs(Map.put(base, key, "x")),
               "expected rejection for struct key #{key}"
      end

      assert :ok = Continuation.validate_attrs(base)
    end

    test "closed RunRequest continuation rejects forbidden keys (pre-existing lock)" do
      # This assertion passes on the base commit too: RunRequest.new/1 was
      # already closed. It is kept here as the struct-closedness lock the
      # privacy tests build on, not as a regression lock for this slice.
      for key <- Continuation.forbidden_keys() do
        assert {:error, _} =
                 RunRequest.new(%{
                   version: 1,
                   goal_id: Ecto.UUID.generate(),
                   task_id: Ecto.UUID.generate(),
                   workspace_ref: "workspace/test",
                   prompt: "do the thing",
                   continuation: %{
                     checkpoint_id: Ecto.UUID.generate(),
                     next_action: "go",
                     decision_refs: [],
                     "#{key}": "smuggled"
                   },
                   policy: %{mode: "supervised"},
                   requested_capabilities: [],
                   dispatch_id: Ecto.UUID.generate(),
                   extensions: %{}
                 }),
               "expected RunRequest to reject forbidden continuation key #{key}"
      end
    end
  end

  describe "for_goal/2 bounded reader" do
    setup do
      goal = FakeHelpers.insert_goal(@goal_id)
      task = FakeHelpers.insert_task(goal, @task_id)
      FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(), run_id: @run_a)
      FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(), run_id: @run_b)
      %{goal: goal, task: task}
    end

    test "empty goal returns :no_checkpoint", %{goal: goal} do
      assert Continuation.for_goal(goal.id) == {:error, :no_checkpoint}
    end

    test "run-scoped query wins; goal fallback covers sibling runs", %{goal: goal} do
      insert_checkpoint!(@run_a, 1, "from run A", goal.id)
      insert_checkpoint!(@run_b, 7, "from run B", goal.id)

      assert {:ok, cont_a} = Continuation.for_goal(goal.id, run_id: @run_a)
      assert cont_a.next_action == "from run A"

      assert {:ok, cont_b} = Continuation.for_goal(goal.id, run_id: @run_b)
      assert cont_b.next_action == "from run B"

      unknown_run = Ecto.UUID.generate()
      assert {:ok, fallback} = Continuation.for_goal(goal.id, run_id: unknown_run)
      assert fallback.next_action == "from run B"

      assert {:error, :no_checkpoint} =
               Continuation.for_goal(goal.id, run_id: unknown_run, allow_goal_fallback: false)
    end

    test "decision refs come from admission.decided events only", %{goal: goal} do
      insert_checkpoint!(@run_a, 1, "go", goal.id)
      assert {:ok, cont} = Continuation.for_goal(goal.id)
      assert cont.decision_refs == []

      d1 = Ecto.UUID.generate()
      d2 = Ecto.UUID.generate()

      CobblerHelpers.append_admission_event!(
        goal.id,
        CobblerHelpers.admission_payload(decision_id: d1)
      )

      CobblerHelpers.append_admission_event!(
        goal.id,
        CobblerHelpers.admission_payload(decision_id: d2)
      )

      assert {:ok, with_refs} = Continuation.for_goal(goal.id)
      assert with_refs.decision_refs == [d1, d2]
    end

    test "decision refs cap at the latest 32", %{goal: goal} do
      insert_checkpoint!(@run_a, 1, "go", goal.id)

      ids =
        Enum.map(1..35, fn _ ->
          id = Ecto.UUID.generate()

          CobblerHelpers.append_admission_event!(
            goal.id,
            CobblerHelpers.admission_payload(decision_id: id)
          )

          id
        end)

      assert {:ok, cont} = Continuation.for_goal(goal.id)
      assert cont.decision_refs == Enum.take(ids, -32)
    end
  end

  defp insert_checkpoint!(run_id, sequence, next_action, goal_id) do
    %CheckpointRecord{id: Ecto.UUID.generate(), goal_id: goal_id, run_id: run_id}
    |> CheckpointRecord.changeset(%{
      "contract_version" => 1,
      "acceptance_contract" => %{"criteria" => ["tests pass"]},
      "repository_state" => %{"revision" => "abc123", "dirty" => false},
      "evidence" => %{"items" => []},
      "decisions" => %{"items" => ["free text, never an id"]},
      "unresolved_issues" => %{"items" => []},
      "next_action" => next_action,
      "stop_reason" => "quota_refused",
      "extensions" => %{},
      "projection_sequence" => sequence
    })
    |> Repo.insert!()
  end
end
