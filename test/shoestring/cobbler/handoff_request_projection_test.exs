defmodule Shoestring.Cobbler.HandoffRequestProjectionTest do
  @moduledoc """
  `Handoffs.request/3` validates the sender's checkpoint against its PROJECTED
  row, and no product path projects a finished Elf's terminal
  `checkpoint.created` (only Cobbler flows and `/runs/new` call the projector).
  At base, a handoff from a run that had simply completed was therefore
  rejected as `handoff_checkpoint_not_found` unless something else happened to
  project the goal first — in the #82 rerun that something was the driver.

  LOCK tests fail on base for that reason (a terminal `rejected` command with
  `handoff_checkpoint_not_found`). DOC tests pass on base.
  """
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Cobbler.{CommandRecord, Commands, Handoffs}
  alias Shoestring.Harness.{CheckpointRecord, Projector}
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory

  @t0 Shoestring.Test.FixedClock.now()

  test "LOCK: an unprojected terminal checkpoint is projected, then the intent is recorded" do
    fixture = fixture()
    assert Repo.get(CheckpointRecord, fixture.checkpoint_id) == nil

    assert {:ok, %{command: command, job: job}} =
             Handoffs.request(fixture.goal.id, attrs(fixture, "cmd-proj-1"))

    assert command.status == "resolved"
    assert command.result["kind"] == "handoff_requested"
    assert command.result["checkpoint_id"] == fixture.checkpoint_id
    assert %Oban.Job{queue: "handoff"} = job
    assert %CheckpointRecord{} = Repo.get(CheckpointRecord, fixture.checkpoint_id)
  end

  test "LOCK: a projection that cannot run records nothing, so the same id can be retried" do
    fixture = fixture()

    # Poison the goal's projector with an event it must refuse.
    {:ok, _} =
      Trajectory.append(fixture.goal.id, %{
        "type" => "run.running",
        "schema_version" => 1,
        "actor" => "test",
        "occurred_at" => @t0,
        "payload" => %{"run_id" => Ecto.UUID.generate()}
      })

    assert {:error, {:handoff_projection_failed, _reason}} =
             Handoffs.request(fixture.goal.id, attrs(fixture, "cmd-proj-2"))

    assert Repo.get_by(CommandRecord, goal_id: fixture.goal.id, command_id: "cmd-proj-2") ==
             nil
  end

  test "DOC: a replayed request with the same id and digest returns the recorded intent" do
    fixture = fixture()
    {:ok, %{command: first}} = Handoffs.request(fixture.goal.id, attrs(fixture, "cmd-proj-3"))
    {:ok, %{command: second}} = Handoffs.request(fixture.goal.id, attrs(fixture, "cmd-proj-3"))
    assert first.id == second.id
  end

  test "DOC: a checkpoint that is not the sender's is still rejected" do
    fixture = fixture()
    other = Ecto.UUID.generate()

    assert {:ok, %{command: command}} =
             Handoffs.request(
               fixture.goal.id,
               put_in(attrs(fixture, "cmd-proj-4"), ["payload", "checkpoint_id"], other)
             )

    assert command.status == "rejected"
  end

  defp fixture do
    goal = FakeHelpers.insert_goal(Ecto.UUID.generate())
    task = FakeHelpers.insert_task(goal, Ecto.UUID.generate())

    run =
      FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate()
      )

    run =
      Repo.update!(
        Ecto.Changeset.change(run, provider_id: "codex_app_server_stdio", status: "completed")
      )

    decision = admission_payload(provider_id: "codex", adapter_id: "codex_app_server")
    admission = append_admission_event!(goal.id, decision)
    {:ok, %{command: claim}} = Commands.submit(goal.id, claim_command(admission))
    assert claim.status == "resolved"
    {:ok, _} = Projector.project(goal.id)

    # The Elf's terminal checkpoint: committed, and — as in production —
    # not projected by anyone.
    checkpoint_id = Ecto.UUID.generate()

    {:ok, _} =
      Trajectory.append(
        goal.id,
        %{
          "type" => "checkpoint.created",
          "schema_version" => 1,
          "actor" => "elf",
          "occurred_at" => @t0,
          "idempotency_key" => "checkpoint:#{checkpoint_id}",
          "payload" => %{
            "checkpoint_id" => checkpoint_id,
            "run_id" => run.id,
            "contract_version" => 1,
            "acceptance_contract" => %{"criteria" => ["go test ./... passes"]},
            "repository_state" => %{"revision" => "abc123", "dirty" => false},
            "evidence" => %{"items" => []},
            "decisions" => %{"items" => []},
            "unresolved_issues" => %{"items" => []},
            "next_action" => "finish the CLI",
            "provider_session_id" => "codex-session",
            "stop_reason" => "completed",
            "artifact_ids" => %{"items" => []},
            "extensions" => %{}
          }
        },
        trusted: [run_id: run.id]
      )

    %{goal: goal, run: run, checkpoint_id: checkpoint_id, decision_id: decision["decision_id"]}
  end

  defp attrs(fixture, command_id) do
    %{
      "command_id" => command_id,
      "payload" => %{
        "run_id" => fixture.run.id,
        "checkpoint_id" => fixture.checkpoint_id,
        "decision_refs" => [fixture.decision_id],
        "to_provider_id" => "claude",
        "to_adapter_id" => "claude_headless_stream_json",
        "scope" => "subscription",
        "reason" => "continue on Claude",
        "requested_by" => "operator"
      }
    }
  end
end
