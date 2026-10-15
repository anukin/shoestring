defmodule Shoestring.Cobbler.PlanWorkerAdmissionClockRegressionTest do
  @moduledoc """
  Production admission evaluates on the live clock after the worker step
  begins, so its decision is always later than the step's start. A reservation
  must be acquired at or after that evaluation. The baseline worker pinned
  `now` before admission and every production dispatch, fan-out or
  sequential, was refused with `reservation_admission_mismatch`.
  """
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers
  alias Shoestring.AgentProfiles
  alias Shoestring.Cobbler.{PlanExecutionWorker, PlanExecutor, Reservations}
  alias Shoestring.Test.{CobblerHelpers, ManualClock, PlanExecutorHelpers}

  setup do
    keys = [:plan_fanout, :plan_reservation_policy, :plan_execution_opts]
    previous = Map.new(keys, &{&1, Application.fetch_env(:shoestring, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {k, {:ok, v}} -> Application.put_env(:shoestring, k, v)
        {k, :error} -> Application.delete_env(:shoestring, k)
      end)
    end)

    assert {:ok, _} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{
               "codex_models" => "fixture-model"
             })

    attrs = Shoestring.ConfigurationFixtures.agent_attrs()

    roles =
      Enum.map(attrs["roles"], fn role ->
        if role["provider"] == "codex", do: Map.put(role, "model", "fixture-model"), else: role
      end)

    assert {:ok, agent} = AgentProfiles.create(Map.put(attrs, "roles", roles))
    assert {:ok, profile} = AgentProfiles.snapshot_by_id(agent.id)
    ManualClock.set(PlanExecutorHelpers.now())
    %{profile: profile}
  end

  defp execution(profile) do
    fixture(
      independent_only: true,
      reconciliation_opts: [group_probe: fn _ -> :absent end],
      request_attrs: %{
        requested_by: "human:operator",
        agent_profile: %{
          "profile_id" => profile["profile_id"],
          "revision" => 1,
          "digest" => profile["digest"],
          "role" => "Worker"
        }
      },
      request_opts: [defer_admission: true]
    )
  end

  # Like `ExecutionAdmission.admit/4`: the decision is evaluated on the
  # clock, which has moved on since the worker step started.
  defp configure_worker!(c) do
    candidate =
      CobblerHelpers.admission_payload(provider_id: "codex", adapter_id: "codex_app_server_stdio")[
        "candidate"
      ]

    admit = fn goal_id, _execution, _task, _attempt ->
      ManualClock.advance(1, :second)
      evaluated = ManualClock.now()

      event =
        admission!(%{c.goal | id: goal_id}, %{
          "candidate" => candidate,
          "evaluated_at" => DateTime.to_iso8601(evaluated),
          "proposed_bounds" => %{
            "response_budget" => 10,
            "tool_budget" => 25,
            "checkpoint_cadence" => 1,
            "reserves" => %{"response" => 1, "tool" => 1},
            "deadline" => DateTime.to_iso8601(DateTime.add(evaluated, 300))
          }
        })

      {:ok, event.id}
    end

    Application.put_env(:shoestring, :plan_execution_opts,
      admission_fun: admit,
      reconciliation_opts: [group_probe: fn _ -> :absent end],
      worktrees_dir: Keyword.fetch!(c.opts, :worktrees_dir),
      clock: ManualClock
    )
  end

  defp perform(c) do
    PlanExecutionWorker.perform(%Oban.Job{
      args: %{"goal_id" => c.goal.id, "execution_id" => c.execution.execution_id}
    })
  end

  test "fan-out reserves each admitted child after its admission", %{profile: profile} do
    c = execution(profile)
    configure_worker!(c)
    Application.put_env(:shoestring, :plan_fanout, enabled: true)

    Application.put_env(:shoestring, :plan_reservation_policy, %{
      global_limit: 2,
      provider_account_limit: 2,
      goal_limit: 2,
      account_units: 2
    })

    # The baseline returned {:error, :fanout_execution_required} after both
    # reservations were refused.
    assert {:snooze, 5} = perform(c)

    assert {:ok, %{dispatch_mode: :fanout_v1, active_children: [_, _]}} =
             PlanExecutor.status(c.goal.id, c.opts)

    assert length(Reservations.outstanding()) == 2
  end

  test "the sequential executor reserves its task after admission", %{profile: profile} do
    c = execution(profile)
    configure_worker!(c)
    # A configured policy makes sequential dispatch reservation-owned too,
    # as it is for dependents after a fan-out integration.
    Application.put_env(:shoestring, :plan_reservation_policy, %{})

    assert {:snooze, 5} = perform(c)

    assert {:ok, %{dispatch_mode: :sequential, active_task: "north"}} =
             PlanExecutor.status(c.goal.id, c.opts)

    assert [%{plan_task_id: "north"}] = Reservations.outstanding()
  end
end
