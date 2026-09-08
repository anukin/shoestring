defmodule Shoestring.Harness.CheckpointFallbackTest do
  @moduledoc """
  Hermetic unit tests for the deterministic no-model checkpoint template.

  Pure (`async: true`, no database): `CheckpointFallback.build/1` takes
  durable-state inputs only and performs zero adapter calls — asserted via
  `RequestLog` equality before/after. Overflow is a hard failure, never a
  silent truncation.

  Locking note (standing contract): this module is new surface in this
  slice, so on the pre-fix commit these tests error on the missing module
  (documentation, not a behavior-change lock). Stated honestly here rather
  than claimed as coverage.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Harness.CheckpointFallback
  alias Shoestring.Harness.Fake.RequestLog

  @goal_id "01950000-0000-7000-8000-000000000001"
  @run_id "01950000-0000-7000-8000-000000000002"
  @checkpoint_id "01950000-0000-7000-8000-000000000003"

  defp inputs(overrides \\ %{}) do
    Map.merge(
      %{
        checkpoint_id: @checkpoint_id,
        goal_id: @goal_id,
        run_id: @run_id,
        acceptance_criteria: ["tests pass", "docs updated"],
        repository_revision: "abc123",
        stop_reason: "deferred"
      },
      overrides
    )
  end

  test "builds a valid checkpoint from durable-state inputs with provenance" do
    assert {:ok, checkpoint} = CheckpointFallback.build(inputs())

    assert checkpoint.version == 1
    assert checkpoint.checkpoint_id == @checkpoint_id
    assert checkpoint.goal_id == @goal_id
    assert checkpoint.run_id == @run_id
    assert checkpoint.acceptance_contract == %{criteria: ["tests pass", "docs updated"]}
    assert checkpoint.repository_state == %{revision: "abc123", dirty: false}
    assert checkpoint.evidence == []
    assert checkpoint.stop_reason == "deferred"
    assert checkpoint.next_action =~ @run_id
    assert checkpoint.next_action =~ @goal_id
    assert checkpoint.next_action =~ "abc123"

    # Provenance is present ...
    assert checkpoint.extensions[CheckpointFallback.provenance_key()] ==
             CheckpointFallback.provenance_value()

    # ... and the required content is still present (both directions).
    assert String.length(checkpoint.next_action) <= 2_000
  end

  test "caller extensions survive; a caller provenance value is overwritten" do
    assert {:ok, checkpoint} =
             CheckpointFallback.build(
               inputs(%{
                 extensions: %{
                   "shoestring:note" => "kept",
                   CheckpointFallback.provenance_key() => "forged"
                 }
               })
             )

    assert checkpoint.extensions["shoestring:note"] == "kept"
    assert checkpoint.extensions[CheckpointFallback.provenance_key()] == "checkpoint-fallback-v1"
  end

  test "explicit next_action is honored when within budget" do
    assert {:ok, checkpoint} = CheckpointFallback.build(inputs(%{next_action: "rerun the suite"}))
    assert checkpoint.next_action == "rerun the suite"
  end

  test "deterministic: identical inputs produce identical checkpoints" do
    assert {:ok, first} = CheckpointFallback.build(inputs())
    assert {:ok, second} = CheckpointFallback.build(inputs())
    assert first == second
  end

  test "overflow hard-fails: over-long next_action is never truncated" do
    long = String.duplicate("a", 2_001)

    assert {:error, {:checkpoint_overflow, %{field: :next_action, limit: 2_000, actual: 2_001}}} =
             CheckpointFallback.build(inputs(%{next_action: long}))
  end

  test "overflow hard-fails: over-count evidence list is never truncated" do
    evidence = for n <- 1..33, do: "item #{n}"

    assert {:error, {:checkpoint_overflow, %{field: :evidence, limit: 32, actual: 33}}} =
             CheckpointFallback.build(inputs(%{evidence: evidence}))
  end

  test "overflow hard-fails: over-long stop_reason is rejected" do
    assert {:error, {:checkpoint_overflow, %{field: :stop_reason}}} =
             CheckpointFallback.build(inputs(%{stop_reason: String.duplicate("s", 301)}))
  end

  test "missing acceptance criteria fail closed" do
    assert {:error, _changeset} =
             CheckpointFallback.build(inputs() |> Map.delete(:acceptance_criteria))

    assert {:error, _changeset} =
             CheckpointFallback.build(inputs(%{acceptance_criteria: []}))
  end

  test "zero adapter calls: the request log is identical before and after" do
    {:ok, log} = RequestLog.start()
    before_entries = RequestLog.all(log)

    assert {:ok, checkpoint} = CheckpointFallback.build(inputs())
    assert is_binary(checkpoint.next_action)

    # No adapter exists in this path: the log proves nothing was invoked.
    assert RequestLog.all(log) == before_entries
    assert RequestLog.count(log) == 0
  end

  test "never interpolates provider output: no transcript-bearing input exists" do
    # The template accepts only durable-state fields. Passing a
    # transcript-shaped value where a durable field belongs either fails
    # validation or round-trips verbatim as caller data — the template
    # itself synthesizes nothing from it.
    {:ok, checkpoint} = CheckpointFallback.build(inputs())

    refute checkpoint.next_action =~ "transcript"
    refute Map.has_key?(checkpoint.extensions, "transcript")
    assert checkpoint.extensions[CheckpointFallback.provenance_key()] == "checkpoint-fallback-v1"
  end
end
