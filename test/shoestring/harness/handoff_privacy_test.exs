defmodule Shoestring.Harness.HandoffPrivacyTest do
  @moduledoc """
  Hermetic privacy tests for handoff payloads: sensitive content is gone
  AND required content is still present (both directions asserted).

  Status per the standing contract: DOCUMENTATION for the
  `Shoestring.Harness.Continuation`-dependent tests (missing module on the
  base commit `d3ca088`, per the T1 new-surface precedent). The
  `RunRequest` struct-closedness test locks pre-existing behaviour and
  passes on base; it is labeled as such where it appears.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.{Continuation, Contract, RunRequest}
  alias Shoestring.Harness.Security
  alias Shoestring.Trajectory.EventRegistry

  @required_keys ~w(handoff_id run_id checkpoint_id from_provider_id to_provider_id
    contract_version next_action decision_refs reason extensions)

  defp handoff_params(overrides \\ %{}) do
    Map.merge(
      %{
        handoff_id: Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate(),
        checkpoint_id: Ecto.UUID.generate(),
        from_provider_id: "shoestring.harness.fake",
        to_provider_id: "fake-harness-b",
        contract_version: 1,
        next_action: "resume from the established checkpoint",
        decision_refs: [Ecto.UUID.generate()],
        reason: "quota handoff",
        extensions: %{},
        prior_run_id: Ecto.UUID.generate()
      },
      overrides
    )
  end

  describe "handoff payload: required present" do
    test "builder returns exactly the registry-required keys plus declared optionals" do
      assert {:ok, payload} = Continuation.handoff_payload(handoff_params())

      for key <- @required_keys do
        assert Map.has_key?(payload, key), "required key #{key} missing"
      end

      assert Map.has_key?(payload, "prior_run_id")
      refute Map.has_key?(payload, "lease_grant_id")

      assert payload["contract_version"] == 1
      assert is_binary(payload["next_action"])
      assert is_list(payload["decision_refs"])
    end

    test "registry accepts the built payload as handoff.created v1" do
      assert {:ok, payload} = Continuation.handoff_payload(handoff_params())
      assert {:ok, _} = EventRegistry.validate_payload("handoff.created", 1, payload)
    end
  end

  describe "handoff payload: sensitive gone" do
    test "every forbidden key in builder params is refused" do
      for key <- Continuation.forbidden_keys() do
        assert {:error, _} =
                 Continuation.handoff_payload(Map.put(handoff_params(), key, "smuggled")),
               "expected refusal for forbidden handoff key #{key}"
      end
    end

    test "secret-bearing values are refused by the builder and the registry" do
      secret_action = "continue with sk-abcdefghijklmnop123456"

      assert {:error, _} =
               Continuation.handoff_payload(handoff_params(%{next_action: secret_action}))

      assert {:ok, clean} = Continuation.handoff_payload(handoff_params())
      tainted = Map.put(clean, "next_action", secret_action)

      assert {:error, {:invalid_payload, "handoff.created", 1, _}} =
               EventRegistry.validate_payload("handoff.created", 1, tainted)
    end

    test "clean payload sweeps secret-free in both directions" do
      assert {:ok, payload} = Continuation.handoff_payload(handoff_params())

      # Sensitive gone: no forbidden key, no credential-shaped content.
      for key <- Continuation.forbidden_keys() do
        refute Map.has_key?(payload, Atom.to_string(key))
      end

      assert Security.scan_term(payload) == []
      assert Contract.safe_term?(payload)

      # Required present: the pointer still identifies the checkpoint run.
      assert is_binary(payload["handoff_id"])
      assert is_binary(payload["run_id"])
      assert is_binary(payload["checkpoint_id"])
    end

    test "registry rejects transcript-scale keys smuggled into the payload" do
      assert {:ok, clean} = Continuation.handoff_payload(handoff_params())

      for key <- ["transcript", "raw_transcript", "messages", "model_response", "stdout"] do
        tainted = Map.put(clean, key, "smuggled content")

        assert {:error, _} =
                 EventRegistry.validate_payload("handoff.created", 1, tainted),
               "expected registry rejection for #{key}"
      end
    end
  end

  describe "struct closedness (locks pre-existing RunRequest behaviour)" do
    test "RunRequest continuation stays closed to all non-pointer fields" do
      # Passes on base: documents the closed struct this slice relies on.
      base = %{
        version: 1,
        goal_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        workspace_ref: "workspace/test",
        prompt: "do the thing",
        policy: %{mode: "supervised"},
        requested_capabilities: [],
        dispatch_id: Ecto.UUID.generate(),
        extensions: %{}
      }

      assert {:ok, _} =
               RunRequest.new(
                 Map.put(base, :continuation, %{
                   checkpoint_id: Ecto.UUID.generate(),
                   next_action: "go",
                   decision_refs: []
                 })
               )

      for key <- Continuation.forbidden_keys() do
        assert {:error, _} =
                 RunRequest.new(
                   Map.put(base, :continuation, %{
                     checkpoint_id: Ecto.UUID.generate(),
                     next_action: "go",
                     decision_refs: [],
                     "#{key}": "smuggled"
                   })
                 ),
               "expected RunRequest to reject #{key}"
      end
    end
  end
end
