defmodule Shoestring.Cobbler.PlanDispatchClaimRecoveryTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.{Commands, PlanExecutor}
  alias Shoestring.Harness.{DispatchRecord, Fake, RunRecord}
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers}

  for mode <- [:legacy, :reserved] do
    test "#{mode} kickoff reuses its already accepted claim instead of releasing its own attempt" do
      goal = CobblerHelpers.create_goal!()
      revision = PlanExecutorHelpers.propose_and_approve!(goal)
      initial = PlanExecutorHelpers.admit!(goal)

      payload =
        initial.payload
        |> Map.put("decision_id", Ecto.UUID.generate())
        |> Map.update!(
          "candidate",
          &Map.merge(&1, %{"provider_id" => "fake", "adapter_id" => Fake.identity().adapter_id})
        )

      admission = CobblerHelpers.append_admission_event!(goal.id, payload)
      opts = PlanExecutorHelpers.exec_opts(admission_event_id: admission.id)

      opts =
        if unquote(mode) == :reserved, do: Keyword.put(opts, :reservation_policy, %{}), else: opts

      assert {:ok, _} =
               PlanExecutor.request_execution(
                 goal.id,
                 Map.put(revision, :admission_event_id, admission.id),
                 opts
               )

      # Deterministically reproduce the durable state after another kickoff has
      # accepted this attempt's command but before it reaches lease issuance.
      attrs = CobblerHelpers.claim_command(admission, command_id: "plan-alpha-1")
      assert {:ok, _} = Commands.submit(goal.id, attrs, now: PlanExecutorHelpers.now())
      claim = Commands.active_claim()

      assert {:ok, %{disposition: :dispatched}} = PlanExecutor.advance(goal.id, opts)
      assert Commands.active_claim() == claim
      assert Commands.get(goal.id, "plan-release-alpha-1") == nil
      assert Repo.aggregate(RunRecord, :count) == 1
      assert Repo.aggregate(DispatchRecord, :count) == 1
      assert Repo.aggregate(Oban.Job, :count) == 1
    end
  end
end
