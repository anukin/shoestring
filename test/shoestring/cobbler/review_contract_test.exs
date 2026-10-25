defmodule Shoestring.Cobbler.ReviewContractTest do
  @moduledoc """
  The cross-review contract: reviewer policy from configuration and the saved
  agent, the findings schema and deterministic outcome, and the strict event
  validation that replays recorded findings. Hermetic; no provider.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.AgentProfiles
  alias Shoestring.Cobbler.ExecutionProfile
  alias Shoestring.Cobbler.Review.{Configuration, Findings}
  alias Shoestring.Trajectory.EventRegistry

  @packet %{
    "changed_files" => [%{"path" => "calc.py", "status" => "M"}],
    "repository_files" => [%{"path" => "calc.py"}, %{"path" => "test/test_calc.py"}]
  }

  describe "reviewer policy" do
    test "review is off unless trusted configuration enables it" do
      assert {:ok, :not_required} = Configuration.load(%{}, review_config: [])
      assert {:ok, :not_required} = Configuration.load(%{}, review_config: [enabled: false])
    end

    test "the saved agent's Reviewer must be another provider family than its Worker" do
      worker = profile!("codex", "claude")

      assert {:ok, {:required, %{public: public}}} =
               Configuration.load(%{agent_profile: worker}, review_config: [enabled: true])

      assert public["provider_id"] == "claude"
      assert public["model"] == "fixture-reviewer"
      assert public["implementer_provider"] == "codex"
      assert public["support_tier"] == "conservative_partial"

      same = profile!("codex", "codex")

      assert {:ok, {:unavailable, :same_provider}} =
               Configuration.load(%{agent_profile: same}, review_config: [enabled: true])
    end

    test "no Reviewer role, or no saved agent for a real provider, is unavailable" do
      assert {:ok, {:unavailable, :no_reviewer}} =
               Configuration.load(%{agent_profile: profile!("codex", nil)},
                 review_config: [enabled: true]
               )

      assert {:ok, {:unavailable, :no_reviewer}} =
               Configuration.load(%{}, review_config: [enabled: true])
    end

    test "an explicit adapter of the implementer's family is refused, not trusted" do
      assert {:ok, {:unavailable, :same_provider}} =
               Configuration.load(%{agent_profile: %{"provider" => "claude"}},
                 review_config: [enabled: true, adapter: :claude, model: "opus"]
               )

      assert {:ok, {:required, %{public: %{"provider_id" => "codex"}}}} =
               Configuration.load(%{agent_profile: %{"provider" => "claude"}},
                 review_config: [enabled: true, adapter: :codex, model: "gpt-review"]
               )
    end

    # Base (9a0f1af): families were keyed by harness, opencode had none, and
    # every opencode task's review was `:implementer_unknown`.
    test "an opencode worker is told apart by its model's vendor, not its harness" do
      worker = fn model -> %{agent_profile: %{"provider" => "opencode", "model" => model}} end
      reviewer = fn adapter -> [enabled: true, adapter: adapter, model: "fixture-reviewer"] end

      assert {:ok, {:required, %{public: %{"provider_id" => "claude"}}}} =
               Configuration.load(worker.("opencode/glm-5.3-flash-free"),
                 review_config: reviewer.(:claude)
               )

      assert {:ok, {:required, %{public: %{"provider_id" => "codex"}}}} =
               Configuration.load(worker.("anthropic/claude-sonnet"),
                 review_config: reviewer.(:codex)
               )

      assert {:ok, {:unavailable, :same_provider}} =
               Configuration.load(worker.("openai/gpt-mini"), review_config: reviewer.(:codex))

      assert {:ok, {:unavailable, :same_provider}} =
               Configuration.load(worker.("anthropic/claude-sonnet"),
                 review_config: reviewer.(:claude)
               )

      assert {:ok, {:unavailable, :implementer_unknown}} =
               Configuration.load(worker.("opencode/big-pickle"),
                 review_config: reviewer.(:claude)
               )
    end
  end

  describe "findings" do
    test "supported blocking findings decide the outcome; the verdict does not" do
      approve_with_blocker =
        result("approve", [finding("F1", "blocking", "calc.py"), finding("F2", "suggestion", nil)])

      assert {:ok, %{"outcome" => "changes_requested", "blocking_count" => 1}} =
               Findings.validate(approve_with_blocker, @packet)

      only_suggestions = result("request_changes", [finding("F1", "non_blocking", "calc.py")])

      assert {:ok, %{"outcome" => "approved", "blocking_count" => 0}} =
               Findings.validate(only_suggestions, @packet)
    end

    test "a path the packet does not contain is unsupported and does not block; a path-free finding does" do
      assert {:ok, %{"outcome" => "approved", "findings" => [%{"reference" => "unsupported"}]}} =
               Findings.validate(
                 result("request_changes", [finding("F1", "blocking", "nope.py")]),
                 @packet
               )

      assert {:ok, %{"outcome" => "changes_requested", "findings" => [%{"reference" => "none"}]}} =
               Findings.validate(
                 result("request_changes", [finding("F1", "blocking", nil)]),
                 @packet
               )

      assert {:ok, %{"findings" => [%{"reference" => "supported"}]}} =
               Findings.validate(
                 result("approve", [finding("F1", "suggestion", "test/test_calc.py")]),
                 @packet
               )
    end

    test "malformed, unbounded, unsafe and duplicate findings are refused" do
      for bad <- [
            "not json",
            ~s({"verdict":"approve","summary":"x"}),
            result("maybe", []),
            result("approve", [Map.put(finding("F1", "blocking", "calc.py"), "extra", 1)]),
            result("approve", [finding("X1", "blocking", "calc.py")]),
            result("approve", [finding("F1", "fatal", "calc.py")]),
            result("approve", [finding("F1", "blocking", "/etc/passwd")]),
            result("approve", [finding("F1", "blocking", "../calc.py")]),
            result("approve", [
              finding("F1", "blocking", "calc.py"),
              finding("F1", "blocking", "calc.py")
            ]),
            result("approve", Enum.map(1..21, &finding("F#{&1}", "suggestion", nil)))
          ] do
        assert {:error, {:schema_failed, _}} = Findings.validate(bad, @packet), bad
      end

      secret =
        result("approve", [
          Map.put(
            finding("F1", "blocking", "calc.py"),
            "evidence",
            "token sk-" <> String.duplicate("a", 40)
          )
        ])

      assert {:error, {:unsafe, _}} = Findings.validate(secret, @packet)
    end

    test "the fingerprint ignores wording but not the file or the violated contract" do
      a = finding("F1", "blocking", "calc.py")
      assert Findings.fingerprint(a) == Findings.fingerprint(%{a | "claim" => "Different words."})
      refute Findings.fingerprint(a) == Findings.fingerprint(%{a | "path" => "other.py"})
      refute Findings.fingerprint(a) == Findings.fingerprint(%{a | "violates" => "security"})
    end
  end

  describe "events" do
    test "recorded findings must replay to the recorded outcome and blocking count" do
      {:ok, findings} =
        Findings.validate(result("approve", [finding("F1", "blocking", "calc.py")]), @packet)

      json = Shoestring.Cobbler.PlanContract.canonical_json(findings)

      assert {:ok, _} =
               EventRegistry.validate_payload(
                 "cobbler.plan.task.reviewed",
                 1,
                 reviewed(json, "changes_requested", 1)
               )

      assert {:error, _} =
               EventRegistry.validate_payload(
                 "cobbler.plan.task.reviewed",
                 1,
                 reviewed(json, "approved", 1)
               )

      assert {:error, _} =
               EventRegistry.validate_payload(
                 "cobbler.plan.task.reviewed",
                 1,
                 reviewed(json, "changes_requested", 0)
               )
    end

    test "human decisions need a human identity and a reason" do
      base = %{
        "decision_id" => Ecto.UUID.generate(),
        "review_id" => Ecto.UUID.generate(),
        "execution_id" => Ecto.UUID.generate(),
        "plan_task_id" => "alpha",
        "attempt" => 1,
        "decision" => "accept",
        "reason" => "Reviewed by hand.",
        "decided_by" => "human:tester"
      }

      assert {:ok, _} = EventRegistry.validate_payload("cobbler.plan.review.decided", 1, base)

      assert {:error, _} =
               EventRegistry.validate_payload("cobbler.plan.review.decided", 1, %{
                 base
                 | "decided_by" => "cobbler"
               })

      assert {:error, _} =
               EventRegistry.validate_payload("cobbler.plan.review.decided", 1, %{
                 base
                 | "decision" => "approve"
               })
    end
  end

  # ----------------------------------------------------------------------------

  defp profile!(worker, reviewer) do
    {:ok, _} =
      AgentProfiles.save_settings(AgentProfiles.settings(), %{
        "codex_models" => "fixture-worker fixture-reviewer",
        "claude_models" => "default fixture-coordinator fixture-reviewer"
      })

    roles =
      [
        %{"name" => "Coordinator", "provider" => "claude", "model" => "fixture-coordinator"},
        %{"name" => "Worker", "provider" => worker, "model" => "fixture-worker"}
      ] ++
        if(reviewer,
          do: [%{"name" => "Reviewer", "provider" => reviewer, "model" => "fixture-reviewer"}],
          else: []
        )

    attrs = Shoestring.ConfigurationFixtures.agent_attrs()
    slug = "review-#{System.unique_integer([:positive])}"

    {:ok, agent} =
      AgentProfiles.create(
        %{attrs | "roles" => roles}
        |> Map.merge(%{"name" => slug, "slug" => slug})
      )

    {:ok, snapshot} = AgentProfiles.snapshot_by_id(agent.id)
    binding = Map.put(Map.take(snapshot, ~w(profile_id revision digest)), "role", "Worker")
    {:ok, resolved} = ExecutionProfile.resolve(binding, Repo)
    resolved
  end

  defp result(verdict, findings),
    do: Jason.encode!(%{"verdict" => verdict, "summary" => "Summary.", "findings" => findings})

  defp finding(id, severity, path) do
    %{
      "id" => id,
      "severity" => severity,
      "path" => path,
      "line" => if(path, do: 2),
      "claim" => "A claim.",
      "evidence" => "Some evidence.",
      "violates" => "correctness",
      "correction" => "A correction.",
      "confidence" => "high"
    }
  end

  defp reviewed(json, outcome, count) do
    %{
      "review_id" => Ecto.UUID.generate(),
      "execution_id" => Ecto.UUID.generate(),
      "plan_task_id" => "alpha",
      "revision_number" => 1,
      "plan_digest" => String.duplicate("a", 64),
      "run_id" => Ecto.UUID.generate(),
      "attempt" => 1,
      "round" => 1,
      "commit" => String.duplicate("b", 40),
      "packet_digest" => String.duplicate("c", 64),
      "outcome" => outcome,
      "reviewer" => "codex:gpt-review",
      "findings_json" => json,
      "blocking_count" => count
    }
  end
end
