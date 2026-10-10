defmodule Shoestring.Test.PlannerFixtures do
  @moduledoc "Synthetic, scoped capacity and deterministic tool-free planner responses."
  alias Shoestring.Harness.CapacitySnapshot

  def config(responses),
    do: [adapter: :fixture, model: "fixture-v1", responses: responses, observer: self()]

  def snapshot(now) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :observed,
          windows:
            Enum.map([{"five_hour", 3600}, {"weekly", 86_400}], fn {kind, seconds} ->
              %{
                kind: kind,
                state: :observed,
                used_percent: 10,
                reset_at: DateTime.add(now, seconds)
              }
            end),
          observed_at: now,
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
        now: now
      )

    snapshot
  end
end
