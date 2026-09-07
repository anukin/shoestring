defmodule Shoestring.Cobbler.ClaimTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.{Claim, Intent}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.Goal

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    goal =
      %Goal{}
      |> Goal.changeset(%{"title" => "Claim Test Goal"})
      |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
      |> Repo.insert!()

    intent =
      %Intent{}
      |> Intent.changeset(%{
        title: "Claim Intent 1",
        status: "pending",
        requested_capability: "supervised_execution",
        provider_id: "codex",
        account_id: "default",
        scope: "account:default",
        admission_decision_id: Ecto.UUID.generate(),
        proposed_bounds: %{"deadline" => "2026-09-07T15:00:00Z"}
      })
      |> Ecto.Changeset.put_change(:goal_id, goal.id)
      |> Repo.insert!()

    intent2 =
      %Intent{}
      |> Intent.changeset(%{
        title: "Claim Intent 2",
        status: "pending",
        requested_capability: "supervised_execution",
        provider_id: "claude",
        account_id: "default",
        scope: "account:default",
        admission_decision_id: Ecto.UUID.generate(),
        proposed_bounds: %{"deadline" => "2026-09-07T15:00:00Z"}
      })
      |> Ecto.Changeset.put_change(:goal_id, goal.id)
      |> Repo.insert!()

    %{goal: goal, intent: intent, intent2: intent2}
  end

  describe "SQLite exclusive claim constraints" do
    test "acquires singleton active claim", %{goal: goal, intent: intent} do
      claim_attrs = %{
        claim_slot: "global_active",
        active_slot: "global",
        command_id: "cmd-claim-1",
        provider_id: "codex",
        account_id: "default",
        scope: "account:default",
        status: "active",
        claimed_at: DateTime.utc_now()
      }

      assert {:ok, claim} =
               %Claim{}
               |> Claim.acquire_changeset(claim_attrs)
               |> Ecto.Changeset.put_change(:goal_id, goal.id)
               |> Ecto.Changeset.put_change(:intent_id, intent.id)
               |> Repo.insert()

      assert claim.status == "active"
      assert claim.active_slot == "global"
    end

    test "second competing active claim is rejected by SQLite unique constraint", %{
      goal: goal,
      intent: intent,
      intent2: intent2
    } do
      # First claim succeeds
      {:ok, _claim1} =
        %Claim{}
        |> Claim.acquire_changeset(%{
          claim_slot: "global_active",
          active_slot: "global",
          command_id: "cmd-claim-1",
          provider_id: "codex",
          account_id: "default",
          scope: "account:default",
          status: "active",
          claimed_at: DateTime.utc_now()
        })
        |> Ecto.Changeset.put_change(:goal_id, goal.id)
        |> Ecto.Changeset.put_change(:intent_id, intent.id)
        |> Repo.insert()

      # Second concurrent/competing claim fails at DB layer (never count-then-act alone)
      assert {:error, changeset} =
               %Claim{}
               |> Claim.acquire_changeset(%{
                 claim_slot: "global_active",
                 active_slot: "global",
                 command_id: "cmd-claim-2",
                 provider_id: "claude",
                 account_id: "default",
                 scope: "account:default",
                 status: "active",
                 claimed_at: DateTime.utc_now()
               })
               |> Ecto.Changeset.put_change(:goal_id, goal.id)
               |> Ecto.Changeset.put_change(:intent_id, intent2.id)
               |> Repo.insert()

      assert match?({"has already been taken", _}, changeset.errors[:active_slot]) or
               match?({"has already been taken", _}, changeset.errors[:claim_slot])
    end

    test "releasing claim vacates active_slot and allows next task to claim", %{
      goal: goal,
      intent: intent,
      intent2: intent2
    } do
      {:ok, claim1} =
        %Claim{}
        |> Claim.acquire_changeset(%{
          claim_slot: "global_active",
          active_slot: "global",
          command_id: "cmd-claim-1",
          provider_id: "codex",
          account_id: "default",
          scope: "account:default",
          status: "active",
          claimed_at: DateTime.utc_now()
        })
        |> Ecto.Changeset.put_change(:goal_id, goal.id)
        |> Ecto.Changeset.put_change(:intent_id, intent.id)
        |> Repo.insert()

      # Explicit release upon terminal transition
      {:ok, released_claim1} =
        claim1
        |> Claim.release_changeset(%{
          status: "released",
          active_slot: nil,
          released_at: DateTime.utc_now(),
          release_reason: "completed"
        })
        |> Repo.update()

      assert released_claim1.status == "released"
      assert is_nil(released_claim1.active_slot)

      # Now intent2 can claim the slot without conflict
      assert {:ok, claim2} =
               %Claim{}
               |> Claim.acquire_changeset(%{
                 claim_slot: "global_active",
                 active_slot: "global",
                 command_id: "cmd-claim-2",
                 provider_id: "claude",
                 account_id: "default",
                 scope: "account:default",
                 status: "active",
                 claimed_at: DateTime.utc_now()
               })
               |> Ecto.Changeset.put_change(:goal_id, goal.id)
               |> Ecto.Changeset.put_change(:intent_id, intent2.id)
               |> Repo.insert()

      assert claim2.status == "active"
      assert claim2.active_slot == "global"
    end

    test "multiple released claims can coexist in database", %{
      goal: goal,
      intent: intent,
      intent2: intent2
    } do
      # Create and release first
      {:ok, c1} =
        %Claim{}
        |> Claim.acquire_changeset(%{
          claim_slot: "global_active",
          active_slot: "global",
          command_id: "cmd-1",
          provider_id: "codex",
          account_id: "default",
          scope: "account:default",
          status: "active",
          claimed_at: DateTime.utc_now()
        })
        |> Ecto.Changeset.put_change(:goal_id, goal.id)
        |> Ecto.Changeset.put_change(:intent_id, intent.id)
        |> Repo.insert()

      {:ok, _} =
        Claim.release_changeset(c1, %{
          status: "released",
          active_slot: nil,
          released_at: DateTime.utc_now(),
          release_reason: "completed"
        })
        |> Repo.update()

      # Create and release second
      {:ok, c2} =
        %Claim{}
        |> Claim.acquire_changeset(%{
          claim_slot: "global_active",
          active_slot: "global",
          command_id: "cmd-2",
          provider_id: "claude",
          account_id: "default",
          scope: "account:default",
          status: "active",
          claimed_at: DateTime.utc_now()
        })
        |> Ecto.Changeset.put_change(:goal_id, goal.id)
        |> Ecto.Changeset.put_change(:intent_id, intent2.id)
        |> Repo.insert()

      {:ok, _} =
        Claim.release_changeset(c2, %{
          status: "released",
          active_slot: nil,
          released_at: DateTime.utc_now(),
          release_reason: "cancelled"
        })
        |> Repo.update()

      # Both exist as released
      claims = Repo.all(Claim)
      assert length(claims) == 2
      assert Enum.all?(claims, &(&1.status == "released" and is_nil(&1.active_slot)))
    end
  end
end
