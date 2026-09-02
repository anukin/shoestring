defmodule Shoestring.Test.Fixtures.FakeHelpers do
  @moduledoc """
  Test helper functions for the fake harness: goal/task setup, run requests,
  and trajectory event payloads used across scenario and eval tests.
  """

  alias Shoestring.Harness.Identifier
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, Task}

  @fixed_clock Shoestring.Test.FixedClock
  @fixed_identifier Shoestring.Test.FixedIdentifier

  @spec insert_goal(String.t()) :: Goal.t()
  def insert_goal(id \\ nil) do
    goal_id = id || Identifier.generate(@fixed_identifier)
    now = @fixed_clock.now()

    %Goal{id: goal_id}
    |> Goal.changeset(%{"title" => "Fake test goal", "status" => "active"})
    |> Ecto.Changeset.put_change(:owner_id, "00000000-0000-4000-8000-000000000301")
    |> Ecto.Changeset.put_change(:inserted_at, now)
    |> Ecto.Changeset.put_change(:updated_at, now)
    |> Repo.insert!()
  end

  @spec insert_task(Goal.t(), String.t() | nil) :: Task.t()
  def insert_task(%Goal{id: goal_id}, id \\ nil) do
    task_id = id || Identifier.generate(@fixed_identifier)
    now = @fixed_clock.now()

    %Task{id: task_id}
    |> Task.changeset(%{"title" => "Fake test task", "status" => "pending"})
    |> Ecto.Changeset.put_change(:goal_id, goal_id)
    |> Ecto.Changeset.put_change(:inserted_at, now)
    |> Ecto.Changeset.put_change(:updated_at, now)
    |> Repo.insert!()
  end

  @spec insert_run_record(Goal.t(), Task.t(), String.t(), keyword()) ::
          Shoestring.Harness.RunRecord.t()
  def insert_run_record(%Goal{id: goal_id}, %Task{id: task_id}, dispatch_id, opts \\ []) do
    alias Shoestring.Harness.RunRecord

    run_id = Keyword.get(opts, :run_id, Identifier.generate(@fixed_identifier))
    now = @fixed_clock.now()

    Repo.insert!(%RunRecord{
      id: run_id,
      goal_id: goal_id,
      task_id: task_id,
      dispatch_id: dispatch_id,
      provider_id: "shoestring.harness.fake",
      workspace_ref: "workspace/test",
      request_version: 1,
      prompt: "Test prompt",
      continuation: %{},
      policy: %{"mode" => "supervised", "network" => false, "write_access" => false},
      requested_capabilities: %{"items" => []},
      status: "requested",
      projection_sequence: 0,
      inserted_at: now,
      updated_at: now
    })
  end

  @spec append_run_requested(Goal.t(), Task.t(), Shoestring.Harness.RunRecord.t()) :: :ok
  def append_run_requested(%Goal{id: goal_id}, %Task{id: task_id}, run) do
    {:ok, _event} =
      Trajectory.append(
        goal_id,
        %{
          "type" => "run.requested",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => @fixed_clock.now(),
          "idempotency_key" => "run-requested:#{run.dispatch_id}",
          "payload" => %{
            "run_id" => run.id,
            "dispatch_id" => run.dispatch_id,
            "provider_id" => run.provider_id,
            "workspace_ref" => run.workspace_ref,
            "request_version" => run.request_version,
            "prompt" => run.prompt,
            "continuation" => %{},
            "policy" => run.policy,
            "requested_capabilities" => run.requested_capabilities,
            "extensions" => %{}
          }
        },
        trusted: [task_id: task_id, run_id: run.id]
      )

    :ok
  end

  @spec append_run_starting(Goal.t(), Shoestring.Harness.RunRecord.t()) :: :ok
  def append_run_starting(%Goal{id: goal_id}, run) do
    {:ok, _event} =
      Trajectory.append(
        goal_id,
        %{
          "type" => "run.starting",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => @fixed_clock.now(),
          "payload" => %{"run_id" => run.id}
        },
        trusted: [run_id: run.id]
      )

    :ok
  end

  @spec append_run_running(Goal.t(), Shoestring.Harness.RunRecord.t(), keyword()) :: :ok
  def append_run_running(%Goal{id: goal_id}, run, opts \\ []) do
    {:ok, _event} =
      Trajectory.append(
        goal_id,
        %{
          "type" => "run.running",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => @fixed_clock.now(),
          "payload" => %{
            "run_id" => run.id,
            "provider_session_id" => Keyword.get(opts, :session_id, "test-session-1")
          }
        },
        trusted: [run_id: run.id]
      )

    :ok
  end

  @spec append_run_completed(Goal.t(), Shoestring.Harness.RunRecord.t()) :: :ok
  def append_run_completed(%Goal{id: goal_id}, run) do
    {:ok, _event} =
      Trajectory.append(
        goal_id,
        %{
          "type" => "run.completed",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => @fixed_clock.now(),
          "payload" => %{"run_id" => run.id}
        },
        trusted: [run_id: run.id]
      )

    :ok
  end

  @spec append_capacity_snapshot(Goal.t(), String.t(), keyword()) :: :ok
  def append_capacity_snapshot(%Goal{id: goal_id}, snapshot_id, opts \\ []) do
    now = Keyword.get(opts, :now, @fixed_clock.now())
    used_percent = Keyword.get(opts, :used_percent, 20.0)
    capacity_state = Keyword.get(opts, :capacity_state, "known")
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(now, 300, :second))
    compatibility = Keyword.get(opts, :compatibility_state, "compatible")

    windows =
      if capacity_state == "known" do
        %{
          "items" => [
            %{
              "kind" => "five_hour",
              "state" => "known",
              "used_percent" => used_percent
            }
          ]
        }
      else
        %{"items" => []}
      end

    confidence = if capacity_state == "known", do: "high", else: "none"

    {:ok, _event} =
      Trajectory.append(
        goal_id,
        %{
          "type" => "capacity.snapshot_observed",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => now,
          "payload" => %{
            "snapshot_id" => snapshot_id,
            "contract_version" => 1,
            "capacity_state" => capacity_state,
            "windows" => windows,
            "observed_at" => DateTime.to_iso8601(now),
            "expires_at" =>
              if(is_nil(expires_at), do: nil, else: DateTime.to_iso8601(expires_at)),
            "source" => %{"adapter_id" => "shoestring.harness.fake", "method" => "probe"},
            "scope" => "subscription",
            "confidence" => confidence,
            "support_tier" => "supported",
            "compatibility_state" => compatibility,
            "extensions" => %{}
          }
        }
      )

    :ok
  end

  @spec append_lease_proposed(Goal.t(), String.t(), String.t(), String.t()) :: :ok
  def append_lease_proposed(%Goal{id: goal_id}, grant_id, run_id, snapshot_id) do
    now = @fixed_clock.now()

    {:ok, _event} =
      Trajectory.append(
        goal_id,
        %{
          "type" => "lease.proposed",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => now,
          "payload" => %{
            "grant_id" => grant_id,
            "run_id" => run_id,
            "admitted_snapshot_id" => snapshot_id,
            "contract_version" => 1,
            "reserves" => %{"response" => 5, "tool" => 10},
            "response_budget" => 20,
            "tool_budget" => 50,
            "deadline" => DateTime.to_iso8601(DateTime.add(now, 3600, :second)),
            "checkpoint_cadence" => 10,
            "renewal_state" => "none",
            "extensions" => %{}
          }
        },
        trusted: [run_id: run_id]
      )

    :ok
  end

  @spec append_checkpoint_created(Goal.t(), String.t(), String.t(), String.t()) :: :ok
  def append_checkpoint_created(%Goal{id: goal_id}, checkpoint_id, run_id, stop_reason) do
    {:ok, _event} =
      Trajectory.append(
        goal_id,
        %{
          "type" => "checkpoint.created",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => @fixed_clock.now(),
          "payload" => %{
            "checkpoint_id" => checkpoint_id,
            "run_id" => run_id,
            "contract_version" => 1,
            "acceptance_contract" => %{"criteria" => ["tests pass"]},
            "repository_state" => %{"revision" => "abc123", "dirty" => false},
            "evidence" => %{"items" => ["tests passed"]},
            "decisions" => %{"items" => ["chose approach A"]},
            "unresolved_issues" => %{"items" => []},
            "next_action" => "continue from step 3",
            "stop_reason" => stop_reason,
            "artifact_ids" => %{"items" => []},
            "extensions" => %{}
          }
        },
        trusted: [run_id: run_id]
      )

    :ok
  end

  @spec make_run_request(Goal.t(), Task.t(), String.t(), keyword()) ::
          Shoestring.Harness.RunRequest.t()
  def make_run_request(%Goal{id: goal_id}, %Task{id: task_id}, dispatch_id, opts \\ []) do
    continuation = Keyword.get(opts, :continuation)

    {:ok, request} =
      Shoestring.Harness.RunRequest.new(%{
        version: 1,
        goal_id: goal_id,
        task_id: task_id,
        workspace_ref: "workspace/test",
        prompt: Keyword.get(opts, :prompt, "implement the feature"),
        continuation: continuation,
        policy: %{mode: "supervised"},
        requested_capabilities: Keyword.get(opts, :capabilities, []),
        dispatch_id: dispatch_id,
        extensions: %{}
      })

    request
  end

  @spec new_id() :: Shoestring.Harness.Identifier.t()
  def new_id, do: Shoestring.Harness.SystemIdentifier.generate()
end
