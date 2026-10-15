defmodule Shoestring.Cobbler.PlanFanoutActivationRegressionTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers
  alias Shoestring.AgentProfiles
  alias Shoestring.Cobbler.{PlanExecutionWorker, PlanExecutor}
  alias Shoestring.Test.CobblerHelpers

  setup do
    keys = [:plan_fanout, :plan_reservation_policy, :plan_execution_opts]
    previous = Map.new(keys, &{&1, Application.fetch_env(:shoestring, &1)})

    # An unset key must be deleted, not stored as nil: readers default only
    # absent keys, so a leaked nil breaks later tests in the run.
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
    %{profile: profile}
  end

  test "an enabled production execution worker fans out independent tasks", %{profile: profile} do
    candidate =
      CobblerHelpers.admission_payload(provider_id: "codex", adapter_id: "codex_app_server_stdio")[
        "candidate"
      ]

    codex = fn goal -> admission!(goal, %{"candidate" => candidate}) end

    c =
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

    Application.put_env(:shoestring, :plan_fanout, enabled: true)

    Application.put_env(:shoestring, :plan_reservation_policy, %{
      global_limit: 2,
      provider_account_limit: 2,
      goal_limit: 2,
      account_units: 2
    })

    Application.put_env(:shoestring, :plan_execution_opts,
      admission_fun: fn goal_id, _, _, _ -> {:ok, codex.(%{c.goal | id: goal_id}).id} end,
      reconciliation_opts: [group_probe: fn _ -> :absent end],
      worktrees_dir: Keyword.fetch!(c.opts, :worktrees_dir),
      clock: Keyword.fetch!(c.opts, :clock)
    )

    job = %Oban.Job{
      args: %{"goal_id" => c.goal.id, "execution_id" => c.execution.execution_id}
    }

    assert {:snooze, 5} = PlanExecutionWorker.perform(job)

    # The baseline worker ignores the configuration and runs one sequential task.
    assert {:ok, %{dispatch_mode: :fanout_v1, active_children: [_, _]}} =
             PlanExecutor.status(c.goal.id, c.opts)
  end
end
