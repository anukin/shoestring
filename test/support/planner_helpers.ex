defmodule Shoestring.Test.PlannerHelpers do
  @moduledoc """
  Hermetic helpers for planner boundary tests: request builders, planner
  capacity snapshots, scripted fixture plans, and invocation logs. Every
  identifier is synthetic, no provider CLI is touched, and no network is
  used.
  """

  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Test.{CobblerHelpers, PlanFixtures, PlannerCallLog}

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @now ~U[2026-09-07 14:00:00.000000Z]
  @provider_id "planner"
  @scope "account:planner"

  @doc "Fixed deterministic timestamp for hermetic planner tests."
  @spec now() :: DateTime.t()
  def now, do: @now

  @doc "The planner candidate planner inference is admitted under."
  @spec candidate(map()) :: map()
  def candidate(overrides \\ %{}) do
    Map.merge(
      %{
        provider_id: @provider_id,
        adapter_id: "cobbler.planner.fixture",
        support_tier: :proactive,
        compatibility_state: :compatible,
        scope: @scope,
        capabilities: ["plan_decomposition"]
      },
      overrides
    )
  end

  @doc "Call opts threading the snapshot, log, and deterministic clock."
  @spec call_opts(pid(), CapacitySnapshot.t() | nil, keyword()) :: keyword()
  def call_opts(log, snapshot, extra \\ []) do
    [
      now: @now,
      capacity_snapshot: snapshot,
      call_log: log,
      candidate: candidate(),
      publish_fun: fn _event -> :ok end
    ] ++ extra
  end

  @doc "A fresh admitted capacity snapshot for the planner provider."
  @spec admitted_snapshot(keyword()) :: CapacitySnapshot.t()
  def admitted_snapshot(opts \\ []) do
    build_snapshot(
      Keyword.get(opts, :five_hour_used, 50.0),
      Keyword.get(opts, :weekly_used, 50.0),
      observed_at: "2026-09-07T13:58:00Z",
      expires_at: "2026-09-07T14:03:00Z"
    )
  end

  @doc "A snapshot past the five-hour reserve: admission must defer."
  @spec blocked_snapshot() :: CapacitySnapshot.t()
  def blocked_snapshot do
    build_snapshot(95.0, 50.0,
      observed_at: "2026-09-07T13:58:00Z",
      expires_at: "2026-09-07T14:03:00Z"
    )
  end

  @doc "A stale snapshot: admission must require confirmation."
  @spec stale_snapshot() :: CapacitySnapshot.t()
  def stale_snapshot do
    build_snapshot(50.0, 50.0,
      observed_at: "2026-09-07T13:00:00Z",
      expires_at: "2026-09-07T13:05:00Z",
      capacity_state: "degraded",
      confidence: "medium",
      reason: "stale_observation"
    )
  end

  defp build_snapshot(five_hour_used, weekly_used, opts) do
    observed_at = Keyword.fetch!(opts, :observed_at)
    expires_at = Keyword.fetch!(opts, :expires_at)
    capacity_state = Keyword.get(opts, :capacity_state, "observed")
    confidence = Keyword.get(opts, :confidence, "high")
    reason = Keyword.get(opts, :reason)

    {:ok, snapshot} =
      CapacitySnapshot.from_payload(
        %{
          "contract_version" => 2,
          "snapshot_id" => Ecto.UUID.generate(),
          "capacity_state" => capacity_state,
          "windows" => %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => five_hour_used,
                "reset_at" => "2026-09-07T18:00:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => weekly_used,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          },
          "freshness" => %{"max_age_seconds" => 300},
          "source" => %{
            "adapter_id" => "cobbler.planner.fixture",
            "provider_id" => @provider_id,
            "invocation_mode" => "test",
            "event" => "explicit_read"
          },
          "scope" => @scope,
          "confidence" => confidence,
          "support_tier" => "proactive",
          "compatibility_state" => "compatible",
          "reason" => reason,
          "observed_at" => observed_at,
          "expires_at" => expires_at,
          "extensions" => %{}
        },
        now: @now
      )

    snapshot
  end

  @doc "Valid `request_plan/3` attributes."
  @spec request_attrs(keyword()) :: map()
  def request_attrs(opts \\ []) do
    %{
      request_id: Keyword.get(opts, :request_id, "plan-request-1"),
      requested_by: Keyword.get(opts, :requested_by, "human:planner"),
      goal_statement:
        Keyword.get(
          opts,
          :goal_statement,
          "Record plan revisions durably and bind approval to an exact digest."
        ),
      repository: %{"base_revision" => PlanFixtures.base_revision()},
      constraints:
        Keyword.get(opts, :constraints, ["No new dependencies.", "Tests stay hermetic."]),
      non_goals: Keyword.get(opts, :non_goals, ["Executing any task from an approved plan."]),
      acceptance: %{
        "gates" => [%{"gate" => "mix_precommit"}],
        "evidence" => ["The full gate runs green and its counts are recorded."]
      },
      context_refs:
        Keyword.get(opts, :context_refs, [
          %{"ref" => "docs/plan-contract.md", "summary" => "The plan contract and its bounds."}
        ])
    }
    |> maybe_put(:proposal_id, Keyword.get(opts, :proposal_id))
    |> maybe_put(:parent_revision_number, Keyword.get(opts, :parent_revision_number))
    |> maybe_put(:confirmation, Keyword.get(opts, :confirmation))
  end

  @doc "Starts a supervised invocation log and returns its pid."
  @spec start_log!() :: pid()
  def start_log! do
    pid = start_supervised!({PlannerCallLog, []})
    pid
  end

  @doc "Creates a goal and returns it."
  @spec create_goal!() :: Shoestring.Trajectory.Goal.t()
  def create_goal!, do: CobblerHelpers.create_goal!()

  @doc "A valid plan carrying the fixture planner attribution."
  @spec valid_plan(map()) :: map()
  def valid_plan(overrides \\ %{}) do
    Map.merge(
      PlanFixtures.plan(%{
        "planner" => %{
          "identity" => "fixture-planner",
          "version" => "1",
          "source_context_refs" => ["docs/plan-contract.md"]
        }
      }),
      overrides
    )
  end

  @doc "A plan whose tasks form a cycle (a depends on b, b depends on a)."
  @spec cyclic_plan() :: map()
  def cyclic_plan do
    valid_plan(%{
      "tasks" => [
        PlanFixtures.task("aaa", "First cyclic task", ["bbb"]),
        PlanFixtures.task("bbb", "Second cyclic task", ["aaa"])
      ],
      "budget" => %{"max_total_attempts" => 4, "max_total_duration_seconds" => 2_400}
    })
  end

  @doc "A plan whose task lacks acceptance criteria."
  @spec missing_criterion_plan() :: map()
  def missing_criterion_plan do
    task =
      PlanFixtures.task("lonely", "Task without criteria", [])
      |> Map.delete("acceptance_criteria")

    valid_plan(%{
      "tasks" => [task, PlanFixtures.task("other", "Another task", ["lonely"])],
      "budget" => %{"max_total_attempts" => 4, "max_total_duration_seconds" => 2_400}
    })
  end

  @doc "A plan smuggling an unsafe reserve-bypass directive in task prose."
  @spec unsafe_plan() :: map()
  def unsafe_plan do
    valid_plan(%{
      "tasks" => [
        PlanFixtures.task("sneaky", "Bypass the reserve by dispatching an Elf directly", [])
      ],
      "budget" => %{"max_total_attempts" => 2, "max_total_duration_seconds" => 1_200}
    })
  end

  @doc "A well-formed plan answering a different goal and base revision."
  @spec mismatched_goal_plan() :: map()
  def mismatched_goal_plan do
    valid_plan(%{
      "goal" => %{
        "statement" => "A completely different goal the requester never named.",
        "repository" => %{"base_revision" => String.duplicate("1", 40)},
        "constraints" => ["No new dependencies."],
        "non_goals" => [],
        "acceptance" => %{
          "gates" => [%{"gate" => "mix_precommit"}],
          "evidence" => ["The gate passes."]
        }
      }
    })
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
