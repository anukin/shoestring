defmodule Shoestring.Test.PlanFixtures do
  @moduledoc """
  Synthetic, hermetic plan fixtures for Cobbler plan contract tests.

  Every identifier here is synthetic. Base revisions are fabricated
  hexadecimal strings that are not commits in this repository, identities
  are `human:` placeholders, and no fixture carries a credential, a provider
  identifier, a machine identifier, or an absolute path. Nothing in this
  module touches a provider CLI or the network.
  """

  @base_revision "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"

  @doc "The synthetic base revision every fixture plan is written against."
  @spec base_revision() :: String.t()
  def base_revision, do: @base_revision

  @doc """
  A valid three-task plan whose graph is a diamond: `survey` first, then
  `widen` and `narrow` in parallel, then `verify`.

  `overrides` is deep-merged at the top level, so a test can replace the
  whole `goal`, `budget`, `tasks`, or `planner` section.
  """
  @spec plan(map()) :: map()
  def plan(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "goal" => goal(),
        "budget" => %{"max_total_attempts" => 12, "max_total_duration_seconds" => 7_200},
        "tasks" => tasks()
      },
      overrides
    )
  end

  @doc "The fixture goal acceptance contract."
  @spec goal(map()) :: map()
  def goal(overrides \\ %{}) do
    Map.merge(
      %{
        "statement" => "Record plan revisions durably and bind approval to an exact digest.",
        "repository" => %{"base_revision" => @base_revision},
        "constraints" => ["No new dependencies.", "Tests stay hermetic."],
        "non_goals" => ["Executing any task from an approved plan."],
        "acceptance" => %{
          "gates" => [%{"gate" => "mix_precommit"}],
          "evidence" => ["The full gate runs green and its counts are recorded."]
        }
      },
      overrides
    )
  end

  @doc "The fixture task list: a diamond over four stable task ids."
  @spec tasks() :: [map()]
  def tasks do
    [
      task("survey", "Survey the existing contract surface", []),
      task("widen", "Widen validation to cover dependency references", ["survey"]),
      task("narrow", "Narrow acceptance to named trusted gates", ["survey"]),
      task("verify", "Verify replay reproduces the digest", ["widen", "narrow"])
    ]
  end

  @doc "One fixture task with a bounded outcome, a gate, a checkpoint, and bounds."
  @spec task(String.t(), String.t(), [String.t()], map()) :: map()
  def task(id, title, depends_on, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "title" => title,
        "outcome" => "#{title}, with the change visible in the committed diff.",
        "depends_on" => depends_on,
        "inputs" => ["The current plan contract module."],
        "expected_artifacts" => ["lib/shoestring/cobbler/plan_contract.ex"],
        "hints" => %{
          "files" => ["lib/shoestring/cobbler/plan_contract.ex"],
          "symbols" => ["PlanContract.new/1"]
        },
        "acceptance_criteria" => ["The named gate passes against the change."],
        "gates" => [
          %{
            "gate" => "mix_test",
            "test_paths" => ["test/shoestring/cobbler/plan_contract_test.exs"]
          }
        ],
        "checkpoint" => %{
          "condition" => "The gate has run and its result is recorded.",
          "evidence" => ["The exact gate command and its counts."]
        },
        "risks" => ["The contract surface may be wider than the survey found."],
        "execution" => %{"max_attempts" => 2, "max_duration_seconds" => 1_200}
      },
      overrides
    )
  end

  @doc "Valid `propose/3` attributes for the fixture plan."
  @spec propose_attrs(keyword()) :: map()
  def propose_attrs(opts \\ []) do
    %{
      proposal_id: Keyword.get(opts, :proposal_id, "proposal-1"),
      authored_by: Keyword.get(opts, :authored_by, "human:planner"),
      plan: Keyword.get(opts, :plan, plan())
    }
    |> maybe_put(:parent_revision_number, Keyword.get(opts, :parent_revision_number))
  end

  @doc "Valid `approve/3` attributes bound to a revision number and digest."
  @spec approve_attrs(pos_integer(), String.t(), keyword()) :: map()
  def approve_attrs(revision_number, digest, opts \\ []) do
    %{
      decision_id: Keyword.get(opts, :decision_id, "decision-1"),
      decided_by: Keyword.get(opts, :decided_by, "human:approver"),
      revision_number: revision_number,
      digest: digest
    }
    |> maybe_put(:note, Keyword.get(opts, :note))
  end

  @doc "Valid `reject/3` attributes bound to a revision number and digest."
  @spec reject_attrs(pos_integer(), String.t(), keyword()) :: map()
  def reject_attrs(revision_number, digest, opts \\ []) do
    %{
      decision_id: Keyword.get(opts, :decision_id, "decision-1"),
      decided_by: Keyword.get(opts, :decided_by, "human:approver"),
      revision_number: revision_number,
      digest: digest,
      reason: Keyword.get(opts, :reason, "The dependency order does not match the repository.")
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
