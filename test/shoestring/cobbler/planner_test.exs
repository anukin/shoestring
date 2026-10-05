defmodule Shoestring.Cobbler.PlannerTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.{Commands, Planner, PlannerRequestRecord, Plans}
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Trajectory.TrajectoryEvent
  import Shoestring.Test.CobblerHelpers, only: [create_goal!: 0]
  import Shoestring.Test.PlanFixtures
  @now ~U[2026-10-04 12:00:00.000000Z]

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    {:ok, supervisor: supervisor, goal: create_goal!()}
  end

  defp config(responses),
    do: [adapter: :fixture, model: "fixture-v1", observer: self(), responses: responses]

  defp options(context, responses \\ nil, extra \\ []) do
    Keyword.merge(
      [
        now: @now,
        task_supervisor: context.supervisor,
        snapshot: snapshot(),
        config: config(responses || [{:ok, Jason.encode!(plan()), 12}])
      ],
      extra
    )
  end

  defp attrs(extra \\ %{}),
    do:
      Map.merge(
        %{request_key: "initial-1", requested_by: "human:operator", goal_contract: goal()},
        extra
      )

  defp request!(context, opts),
    do:
      assert(
        {:ok, %{request: %PlannerRequestRecord{state: "pending"}}} =
          Planner.request(context.goal.id, attrs(), opts)
      )

  defp snapshot(overrides \\ %{}) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        Map.merge(
          %{
            version: 2,
            snapshot_id: Ecto.UUID.generate(),
            capacity_state: :observed,
            windows: [
              %{
                kind: "five_hour",
                state: :observed,
                used_percent: 10,
                reset_at: DateTime.add(@now, 3600)
              },
              %{
                kind: "weekly",
                state: :observed,
                used_percent: 10,
                reset_at: DateTime.add(@now, 86_400)
              }
            ],
            observed_at: @now,
            freshness: %{max_age_seconds: 300},
            source: %{
              adapter_id: "planner.fixture",
              provider_id: "fixture",
              invocation_mode: "structured-planning",
              event: :explicit_read
            },
            scope: "planner:fixture",
            confidence: :high,
            support_tier: :proactive,
            compatibility_state: :compatible,
            reason: nil,
            extensions: %{}
          },
          overrides
        ),
        now: @now
      )

    snapshot
  end

  test "request is durable, bounded, inert and idempotent", context do
    opts = options(context)

    assert {:ok, %{request: row, outcome: :recorded}} =
             Planner.request(context.goal.id, attrs(), opts)

    assert row.projection["title"] == context.goal.title
    assert row.projection["goal_contract"]["repository"]["base_revision"] == base_revision()
    assert row.configuration["model"] == "fixture-v1"
    assert row.attempts == 0

    assert {:ok, %{request: replay, outcome: :replayed}} =
             Planner.request(context.goal.id, attrs(), opts)

    assert replay.id == row.id
    assert Repo.aggregate(PlannerRequestRecord, :count) == 1
    assert Repo.aggregate(TrajectoryEvent, :count) == 1
    assert Plans.list_revisions(context.goal.id) == []
    assert Commands.active_claim() == nil
    refute_receive {:planner_input, _}
  end

  test "valid inference charges before a single call and stays unapproved", context do
    opts = options(context)
    request!(context, opts)

    assert {:ok, %{request: row, outcome: :finished}} =
             Planner.generate(context.goal.id, "initial-1", opts)

    assert row.state == "ready"
    assert row.attempts == 1
    assert row.charged_output_tokens == 4096
    assert row.attempt_history["items"] |> hd() |> Map.get("output_tokens") == 12
    assert {:ok, %{consistent?: true, request: rebuilt}} = Planner.rebuild(context.goal.id)
    assert rebuilt.result_digest == row.result_digest
    assert rebuilt.charged_output_tokens == 4096
    assert_received {:planner_input, input}
    assert input["model"] == "fixture-v1"
    assert input["schema"]["additionalProperties"] == false
    assert input["projection"] == row.projection
    assert Plans.authority(context.goal.id) == nil
    assert Plans.list_revisions(context.goal.id) == []
    assert Commands.active_claim() == nil
    assert Repo.aggregate(Shoestring.Harness.RunRecord, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert {:ok, %{outcome: :replayed}} = Planner.generate(context.goal.id, "initial-1", opts)
    refute_receive {:planner_input, _}
  end

  test "human adoption binds the exact digest and never self-approves", context do
    opts = options(context)
    request!(context, opts)
    {:ok, %{request: row}} = Planner.generate(context.goal.id, "initial-1", opts)

    assert {:error, :stale_planner_digest} =
             Planner.adopt(
               context.goal.id,
               "initial-1",
               %{digest: String.duplicate("0", 64), authored_by: "human:operator"},
               opts
             )

    assert {:error, {:non_human_identity, _}} =
             Planner.adopt(
               context.goal.id,
               "initial-1",
               %{digest: row.result_digest, authored_by: "model:fixture"},
               opts
             )

    assert {:ok, %{revision: revision}} =
             Planner.adopt(
               context.goal.id,
               "initial-1",
               %{digest: row.result_digest, authored_by: "human:operator"},
               opts
             )

    assert revision.status == "proposed"
    assert revision.content["planner"]["identity"] == "fixture:fixture-v1"
    assert revision.digest == row.result_digest

    assert {:ok, %{outcome: :replayed}} =
             Planner.adopt(
               context.goal.id,
               "initial-1",
               %{digest: row.result_digest, authored_by: "human:operator"},
               opts
             )

    assert Plans.authority(context.goal.id) == nil
  end

  test "invalid JSON permits only one explicit repair with validation feedback", context do
    opts =
      options(context, [
        {:ok, "not-json hidden-reasoning-marker", 5},
        {:ok, Jason.encode!(plan()), 7}
      ])

    request!(context, opts)
    assert {:ok, %{request: first}} = Planner.generate(context.goal.id, "initial-1", opts)
    assert first.state == "schema_failed"
    assert first.result_json == nil
    assert {:ok, %{outcome: :replayed}} = Planner.generate(context.goal.id, "initial-1", opts)
    assert {:ok, %{request: repaired}} = Planner.repair(context.goal.id, "initial-1", opts)
    assert repaired.state == "ready"
    assert repaired.attempts == 2
    assert repaired.charged_output_tokens == 8192
    assert_received {:planner_input, %{"attempt" => 1}}

    assert_received {:planner_input,
                     %{"attempt" => 2, "validation_errors" => [%{"code" => "invalid_json"}]}}

    refute_receive {:planner_input, _}

    assert {:error, :planner_repair_unavailable} =
             Planner.repair(context.goal.id, "initial-1", opts)

    assert {:error, :planner_request_conflict} =
             Planner.request(context.goal.id, attrs(%{request_key: "new-budget"}), opts)

    serialized = Jason.encode!(Repo.all(from e in TrajectoryEvent, select: e.payload))
    refute serialized =~ "hidden-reasoning-marker"
    assert serialized =~ "fixture-v1"
    assert serialized =~ base_revision()
  end

  test "a failed repair remains available for manual editing without another inference",
       context do
    opts = options(context, [{:ok, "bad", 1}, {:ok, "bad-again", 1}])
    request!(context, opts)
    {:ok, _} = Planner.generate(context.goal.id, "initial-1", opts)

    assert {:ok, %{request: %{state: "schema_failed", attempts: 2}}} =
             Planner.repair(context.goal.id, "initial-1", opts)

    assert {:error, :planner_repair_unavailable} =
             Planner.repair(context.goal.id, "initial-1", opts)

    assert {:ok, _} = Plans.propose(context.goal.id, propose_attrs(), opts)
    assert Planner.get(context.goal.id).charged_output_tokens == 8192
  end

  for {name, state} <- [
        {"cycle", "schema_failed"},
        {"missing criterion", "schema_failed"},
        {"embedded command", "unsafe_proposal"},
        {"changed non-goals", "unsafe_proposal"},
        {"unbounded task", "schema_failed"},
        {"invented authority", "schema_failed"},
        {"invented provenance", "unsafe_proposal"}
      ] do
    @name name
    @state state
    test "refuses #{name} without revision or dispatch", context do
      opts = options(context, [{:ok, Jason.encode!(malformed(@name)), 10}])
      request!(context, opts)
      assert {:ok, %{request: row}} = Planner.generate(context.goal.id, "initial-1", opts)
      assert row.state == @state
      assert row.result_json == nil
      assert row.errors["items"] != []
      assert Plans.list_revisions(context.goal.id) == []
      assert Repo.aggregate(Shoestring.Harness.RunRecord, :count) == 0
    end
  end

  defp malformed("cycle"),
    do: Map.put(plan(), "tasks", [task("a", "A", ["b"]), task("b", "B", ["a"])])

  defp malformed("missing criterion"),
    do: Map.put(plan(), "tasks", [Map.delete(task("a", "A", []), "acceptance_criteria")])

  defp malformed("embedded command"), do: Map.put(plan(), "shell", "do-something")

  defp malformed("changed non-goals"),
    do: put_in(plan(), ["goal", "non_goals"], ["Changed scope."])

  defp malformed("unbounded task"),
    do: Map.put(plan(), "tasks", [Map.delete(task("a", "A", []), "execution")])

  defp malformed("invented authority"), do: Map.put(plan(), "approved", true)

  defp malformed("invented provenance"),
    do: Map.put(plan(), "planner", %{"identity" => "model:self", "version" => "1"})

  test "transport failure consumes its allowance and never enters repair", context do
    opts = options(context, [{:error, :quota_refused}])
    request!(context, opts)
    assert {:ok, %{request: row}} = Planner.generate(context.goal.id, "initial-1", opts)
    assert row.state == "transport_failed"
    assert row.errors["items"] |> hd() |> Map.get("code") == "quota_refused"
    assert row.charged_output_tokens == 4096

    assert {:error, :planner_repair_unavailable} =
             Planner.repair(context.goal.id, "initial-1", opts)

    assert {:ok, %{outcome: :replayed}} = Planner.generate(context.goal.id, "initial-1", opts)
    assert_received {:planner_input, _}
    refute_receive {:planner_input, _}
  end

  test "reported output usage above the reservation fails closed", context do
    opts = options(context, [{:ok, Jason.encode!(plan()), 4097}])
    request!(context, opts)

    assert {:ok, %{request: %{state: "budget_exceeded", result_json: nil}}} =
             Planner.generate(context.goal.id, "initial-1", opts)
  end

  test "missing observation blocks before spending; single-decision confirmation can admit",
       context do
    opts = options(context, nil, snapshot: nil)
    request!(context, opts)

    assert {:ok, %{request: row, outcome: :blocked}} =
             Planner.generate(context.goal.id, "initial-1", opts)

    assert row.attempts == 0
    assert row.charged_output_tokens == 0
    assert Commands.active_claim() == nil
    refute_receive {:planner_input, _}

    assert {:ok, %{request: %{state: "ready", attempts: 1}}} =
             Planner.generate(
               context.goal.id,
               "initial-1",
               Keyword.put(opts, :confirm_unknown_capacity, true)
             )

    admission =
      Repo.all(from e in TrajectoryEvent, where: e.type == "admission.decided")
      |> Enum.find(&(&1.payload["result"] == "admit"))

    assert admission.payload["override"]["confirmed_by"] == "human:operator"
    assert admission.payload["override"]["intent"] == "read_only"
  end

  test "five-hour and weekly reserve breaches cannot be confirmed away", context do
    for {kind, used} <- [{"five_hour", 80}, {"weekly", 90}] do
      goal = create_goal!()

      windows =
        Enum.map(snapshot().windows, fn w ->
          if w.kind == kind, do: %{w | used_percent: used}, else: w
        end)

      opts =
        options(context, nil,
          snapshot: snapshot(%{windows: windows}),
          confirm_unknown_capacity: true
        )

      assert {:ok, _} = Planner.request(goal.id, attrs(), opts)

      assert {:ok, %{request: %{attempts: 0}, outcome: :blocked}} =
               Planner.generate(goal.id, "initial-1", opts)
    end

    refute_receive {:planner_input, _}
    assert Commands.active_claim() == nil
  end

  test "capacity is re-evaluated for repair and its earlier allowance is retained", context do
    opts = options(context, [{:ok, "bad", 1}, {:ok, Jason.encode!(plan()), 2}])
    request!(context, opts)
    {:ok, _} = Planner.generate(context.goal.id, "initial-1", opts)
    windows = Enum.map(snapshot().windows, &%{&1 | used_percent: 95})
    blocked_opts = Keyword.put(opts, :snapshot, snapshot(%{windows: windows}))

    assert {:ok, %{request: row, outcome: :blocked}} =
             Planner.repair(context.goal.id, "initial-1", blocked_opts)

    assert row.attempts == 1
    assert row.charged_output_tokens == 4096

    assert {:ok, %{request: %{state: "ready", attempts: 2}}} =
             Planner.repair(context.goal.id, "initial-1", opts)
  end

  test "provider and scope mismatch stay hard stops", context do
    for override <- [
          %{scope: "planner:other"},
          %{
            source: %{
              adapter_id: "other",
              provider_id: "other",
              invocation_mode: "structured-planning",
              event: :explicit_read
            }
          }
        ] do
      goal = create_goal!()
      opts = options(context, nil, snapshot: snapshot(override), confirm_unknown_capacity: true)
      assert {:ok, _} = Planner.request(goal.id, attrs(), opts)
      assert {:ok, %{outcome: :blocked}} = Planner.generate(goal.id, "initial-1", opts)
    end

    refute_receive {:planner_input, _}
  end

  test "same and other goal requests cannot infer during a global claim", context do
    ref = make_ref()
    opts = options(context, [{:await, self(), ref, Jason.encode!(plan()), 10}])
    request!(context, opts)

    task =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        Planner.generate(context.goal.id, "initial-1", opts)
      end)

    assert_receive {:planner_waiting, pid, ^ref}
    assert Planner.get(context.goal.id).state == "running"
    assert Planner.get(context.goal.id).charged_output_tokens == 4096
    assert Commands.active_claim().goal_id == context.goal.id
    assert {:ok, %{outcome: :replayed}} = Planner.generate(context.goal.id, "initial-1", opts)
    other = create_goal!()
    {:ok, _} = Planner.request(other.id, attrs(), opts)
    assert {:ok, %{outcome: :blocked}} = Planner.generate(other.id, "initial-1", opts)
    send(pid, {:continue, ref})
    assert {:ok, %{request: %{state: "ready"}}} = Task.await(task)
    assert Commands.active_claim() == nil
  end

  test "lost result survives process restart without inference duplication or budget reset",
       context do
    ref = make_ref()
    opts = options(context, [{:await, self(), ref, Jason.encode!(plan()), 10}])
    request!(context, opts)

    task =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        Planner.generate(context.goal.id, "initial-1", opts)
      end)

    assert_receive {:planner_waiting, pid, ^ref}
    monitor = Process.monitor(pid)
    _ = Task.shutdown(task, :brutal_kill)
    :ok = stop_supervised(Task.Supervisor)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    replacement = start_supervised!(Task.Supervisor)
    opts = Keyword.put(opts, :task_supervisor, replacement)

    assert {:ok, %{request: row, outcome: :replayed}} =
             Planner.generate(context.goal.id, "initial-1", opts)

    assert row.state == "running"

    assert {:ok, %{consistent?: true, request: %{state: "running"}}} =
             Planner.rebuild(context.goal.id)

    assert row.attempts == 1
    assert row.charged_output_tokens == 4096
    assert Commands.active_claim().goal_id == context.goal.id
    assert_received {:planner_input, _}
    refute_receive {:planner_input, _}
  end

  test "configuration changes cannot reset or reroute a durable request", context do
    opts = options(context)
    request!(context, opts)
    changed = Keyword.update!(opts, :config, &Keyword.put(&1, :model, "another-model"))

    assert {:error, :planner_configuration_changed} =
             Planner.generate(context.goal.id, "initial-1", changed)

    assert {:error, :planner_request_conflict} =
             Planner.request(context.goal.id, attrs(), changed)

    refute_receive {:planner_input, _}
  end

  test "disabled and unbounded configuration is refused before storing a request", context do
    assert {:error, :planner_disabled} = Planner.request(context.goal.id, attrs(), config: [])

    assert {:error, {:invalid_planner_configuration, :max_output_tokens}} =
             Planner.request(context.goal.id, attrs(),
               config: [adapter: :fixture, model: "fixture", max_output_tokens: 0]
             )

    assert Planner.get(context.goal.id) == nil
  end

  test "input cannot carry credentials or oversized context and required evidence is kept",
       context do
    opts = options(context)
    secret_goal = goal(%{"constraints" => ["Bearer abcdefghijklmnop"]})

    assert {:error, _} =
             Planner.request(context.goal.id, attrs(%{goal_contract: secret_goal}), opts)

    assert {:error, _} =
             Planner.request(
               context.goal.id,
               attrs(%{context_event_ids: List.duplicate(Ecto.UUID.generate(), 16)}),
               opts
             )

    assert {:ok, %{request: row}} = Planner.request(context.goal.id, attrs(), opts)
    refute Jason.encode!(row.projection) =~ "abcdefghijklmnop"

    assert row.projection["goal_contract"]["acceptance"]["gates"] == [
             %{"gate" => "mix_precommit"}
           ]
  end

  test "context references must belong to this goal", context do
    other = create_goal!()

    {:ok, event} =
      Shoestring.Trajectory.append(other.id, %{
        type: "decision.recorded",
        actor: "human",
        schema_version: 1,
        payload: %{"decision" => "Bound scope."}
      })

    opts = options(context)

    assert {:error, :planner_context_not_owned} =
             Planner.request(context.goal.id, attrs(%{context_event_ids: [event.id]}), opts)

    {:ok, owned} =
      Shoestring.Trajectory.append(context.goal.id, %{
        type: "decision.recorded",
        actor: "human",
        schema_version: 1,
        payload: %{"decision" => "Bound scope."}
      })

    assert {:ok, %{request: row}} =
             Planner.request(context.goal.id, attrs(%{context_event_ids: [owned.id]}), opts)

    assert row.projection["source_context_refs"] == ["event:#{owned.id}:decision.recorded"]

    assert hd(row.projection["evidence_summaries"]["items"])["facts"] == %{
             "decision" => "Bound scope."
           }

    assert {:ok, %{consistent?: true}} = Planner.rebuild(context.goal.id)
  end

  test "cache divergence prevents inference without resetting the budget", context do
    opts = options(context)
    request!(context, opts)
    {:ok, %{request: row}} = Planner.generate(context.goal.id, "initial-1", opts)

    Repo.update_all(from(r in PlannerRequestRecord, where: r.id == ^row.id),
      set: [attempts: 0, state: "pending"]
    )

    assert {:ok, %{consistent?: false, request: %{attempts: 1, state: "ready"}}} =
             Planner.rebuild(context.goal.id)

    assert {:error, :planner_state_diverged} =
             Planner.generate(context.goal.id, "initial-1", opts)

    assert_received {:planner_input, _}
    refute_receive {:planner_input, _}
  end

  test "finished result tampering prevents adoption", context do
    opts = options(context)
    request!(context, opts)
    {:ok, %{request: row}} = Planner.generate(context.goal.id, "initial-1", opts)
    changed = put_in(plan(), ["goal", "statement"], "Different unreviewed goal.")
    {:ok, contract} = Shoestring.Cobbler.PlanContract.new(changed)

    Repo.update_all(from(r in PlannerRequestRecord, where: r.id == ^row.id),
      set: [
        result_json: Shoestring.Cobbler.PlanContract.canonical_json(contract),
        result_digest: contract.digest
      ]
    )

    assert {:error, :planner_result_corrupt} =
             Planner.adopt(
               context.goal.id,
               "initial-1",
               %{digest: contract.digest, authored_by: "human:operator"},
               opts
             )

    assert Plans.list_revisions(context.goal.id) == []
  end

  test "planner event schemas reject oversized budgets and forged result digests", context do
    opts = options(context)
    request!(context, opts)
    {:ok, _} = Planner.generate(context.goal.id, "initial-1", opts)

    event =
      Repo.one(from e in TrajectoryEvent, where: e.type == "cobbler.planner.attempt.finished")

    forged = Map.put(event.payload, "plan_digest", String.duplicate("0", 64))

    assert {:error, {:invalid_payload, _, _, _}} =
             Shoestring.Trajectory.EventRegistry.validate_payload(event.type, 1, forged)

    assert {:ok, _} =
             Shoestring.Trajectory.EventRegistry.validate_payload(event.type, 1, event.payload)

    started =
      Repo.one(from e in TrajectoryEvent, where: e.type == "cobbler.planner.attempt.started")

    assert {:error, {:invalid_payload, _, _, _}} =
             Shoestring.Trajectory.EventRegistry.validate_payload(
               started.type,
               1,
               Map.put(started.payload, "attempt", 3)
             )
  end

  test "initial planning cannot create a fresh budget over existing plan history", context do
    opts = options(context)
    assert {:ok, _} = Plans.propose(context.goal.id, propose_attrs(), opts)

    assert {:error, :initial_planning_already_has_revision} =
             Planner.request(context.goal.id, attrs(), opts)

    assert Planner.get(context.goal.id) == nil
    refute_receive {:planner_input, _}
  end
end
