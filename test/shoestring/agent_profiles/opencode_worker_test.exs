defmodule Shoestring.AgentProfiles.OpencodeWorkerTest do
  @moduledoc """
  opencode as a plan-task worker: model lists, role rules, the immutable
  execution binding and admission. No provider and no monitor start.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{AgentProfiles, ConfigurationFixtures}
  alias Shoestring.CLI.Follow
  alias Shoestring.Cobbler.{ExecutionAdmission, ExecutionProfile}
  alias Shoestring.Measurement.Collection
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    assert {:ok, _} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{
               "claude_models" => "fixture-claude",
               "opencode_models" => "opencode/fixture-free openai/fixture-mini"
             })

    :ok
  end

  defp roles(worker, overrides \\ []) do
    [
      %{"name" => "Coordinator", "provider" => "claude", "model" => "fixture-claude"},
      Map.merge(
        %{"name" => "Worker", "provider" => "opencode", "model" => worker},
        Map.new(overrides)
      ),
      %{"name" => "Reviewer", "provider" => "claude", "model" => "fixture-claude"}
    ]
  end

  defp create(roles),
    do: AgentProfiles.create(ConfigurationFixtures.agent_attrs(%{"roles" => roles}))

  describe "model lists" do
    test "start empty and accept only provider/model identifiers" do
      assert Shoestring.Repo.insert!(%AgentProfiles.Settings{}).opencode_models == ""

      assert {:error, changeset} =
               AgentProfiles.save_settings(AgentProfiles.settings(), %{
                 "opencode_models" => "glm-5"
               })

      assert %{opencode_models: [_]} = errors_on(changeset)

      assert AgentProfiles.catalog()["opencode"] == [
               "opencode/fixture-free",
               "openai/fixture-mini"
             ]
    end
  end

  describe "roles" do
    test "an opencode worker needs a listed model and pins no effort" do
      assert {:ok, _} = create(roles("opencode/fixture-free"))
      assert {:error, _} = create(roles("opencode/unlisted"))
      assert {:error, changeset} = create(roles("opencode/fixture-free", [{"effort", "low"}]))
      assert inspect(errors_on(changeset)) =~ "effort"
    end

    test "opencode can neither coordinate nor review" do
      for name <- ["Coordinator", "Reviewer"] do
        roles =
          Enum.map(roles("opencode/fixture-free"), fn
            %{"name" => ^name} = role ->
              %{role | "provider" => "opencode", "model" => "opencode/fixture-free"}

            role ->
              role
          end)

        assert {:error, changeset} = create(roles)
        assert inspect(errors_on(changeset)) =~ "opencode runs plan tasks only", name
      end
    end
  end

  test "the execution binding names the opencode adapter and model, never an effort" do
    {:ok, agent} = create(roles("openai/fixture-mini"))
    {:ok, snapshot} = AgentProfiles.snapshot_by_id(agent.id)

    attrs =
      snapshot |> Map.take(["profile_id", "revision", "digest"]) |> Map.put("role", "Worker")

    assert {:ok, binding} = ExecutionProfile.resolve(attrs, Shoestring.Repo)
    assert binding["provider"] == "opencode"
    assert binding["adapter_id"] == "opencode_acp"
    assert binding["model"] == "openai/fixture-mini"
    refute Map.has_key?(binding, "effort")
    assert ExecutionProfile.identity(binding).provider == "opencode"
  end

  describe "admission" do
    defp execution(model),
      do: %{
        execution_id: Ecto.UUID.generate(),
        agent_profile: %{
          "provider" => "opencode",
          "adapter_id" => "opencode_acp",
          "model" => model
        }
      }

    @task %{"id" => "alpha", "execution" => %{"max_duration_seconds" => 300}}

    # Base: no opencode reading ever reached the Observatory, so admission
    # waited for one forever (`no_observation_for_provider`).
    test "an opencode task asks for confirmation: its capacity is unknown, never invented" do
      goal = CobblerHelpers.create_goal!()

      assert {:error, {:execution_admission_blocked, reason}} =
               ExecutionAdmission.admit(goal.id, execution("opencode/fixture-free"), @task, 1)

      refute reason in [:no_observation, :no_observation_for_provider]

      decision =
        Repo.one!(
          from e in TrajectoryEvent,
            where: e.goal_id == ^goal.id and e.type == "admission.decided"
        )

      assert decision.payload["result"] == "require_confirmation"
      assert decision.payload["candidate"]["provider_id"] == "opencode"
    end

    test "an openai/ opencode model waits while a Codex collection window is open" do
      goal = CobblerHelpers.create_goal!()
      assert {:ok, _} = Collection.open("codex", "subscription", "operator")

      assert {:error, {:execution_admission_blocked, :codex_collection_window_open}} =
               ExecutionAdmission.admit(goal.id, execution("openai/fixture-mini"), @task, 1)

      waiting =
        Repo.one!(
          from e in TrajectoryEvent,
            where: e.goal_id == ^goal.id and e.type == "cobbler.plan.admission.waiting"
        )

      assert Follow.line(%{type: waiting.type, payload: waiting.payload}) =~
               "Codex collection window"

      # Another provider's model is not Codex's subscription.
      assert {:error, {:execution_admission_blocked, reason}} =
               ExecutionAdmission.admit(goal.id, execution("opencode/fixture-free"), @task, 2)

      refute reason == :codex_collection_window_open
    end
  end
end
