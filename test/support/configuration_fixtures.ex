defmodule Shoestring.ConfigurationFixtures do
  def agent_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Builder",
        "slug" => "builder",
        "purpose" => "Implement and review changes.",
        "instructions" => "Plan carefully and request independent review.",
        "roles" => [
          %{"name" => "Coordinator", "provider" => "claude", "model" => "default"},
          %{"name" => "Worker", "provider" => "codex", "model" => "default"},
          %{"name" => "Reviewer", "provider" => "claude", "model" => "default"}
        ]
      },
      overrides
    )
  end

  def form_attrs(attrs),
    do:
      Map.update!(attrs, "roles", fn roles ->
        roles |> Enum.with_index() |> Map.new(fn {role, index} -> {to_string(index), role} end)
      end)

  def capacity_fixture(overrides \\ %{}) do
    now = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :observed,
          windows: [
            %{
              kind: "five_hour",
              state: :observed,
              used_percent: 25.0,
              reset_at: DateTime.add(now, 3600)
            }
          ],
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "synthetic_adapter",
            provider_id: "codex",
            invocation_mode: "cli",
            event: :explicit_read
          },
          scope: "synthetic-account",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          observed_at: now,
          reason: nil,
          extensions: %{}
        },
        overrides
      )

    clock = attrs.observed_at || now
    {:ok, snapshot} = Shoestring.Harness.CapacitySnapshot.new(attrs, now: clock)
    {:ok, _, _} = Shoestring.Harness.Observatory.ingest(snapshot, now: clock)
    snapshot
  end
end
