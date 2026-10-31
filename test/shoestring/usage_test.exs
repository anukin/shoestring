defmodule Shoestring.UsageTest do
  use Shoestring.DataCase, async: false
  import Shoestring.ConfigurationFixtures
  alias Shoestring.Usage

  test "unobserved provider has no fabricated allowance or history" do
    assert length(Usage.cards()) == 2

    for card <- Usage.cards() do
      assert card.status == "Unknown"
      assert card.observed_at == nil
      assert card.history == []
      assert Enum.all?(card.windows, &is_nil(&1.used_percent))
    end
  end

  test "shared account is grouped across invocation modes, latest refusal wins" do
    capacity_fixture()

    capacity_fixture(%{
      capacity_state: :refused,
      windows: [],
      observed_at: nil,
      confidence: :low,
      support_tier: :reactive_only,
      reason: "Allowance refused",
      source: %{
        adapter_id: "synthetic_adapter",
        provider_id: "codex",
        invocation_mode: "exec_json",
        event: :headless_result_error
      }
    })

    cards = Usage.cards() |> Enum.filter(&(&1.provider == "codex"))
    assert [card] = cards
    assert card.status == "Unavailable"
    assert card.observed_at == nil
    assert Enum.all?(card.windows, &is_nil(&1[:used_percent]))
  end

  test "stale account stays separate from provider and other account" do
    now = DateTime.utc_now()
    capacity_fixture(%{observed_at: DateTime.add(now, -600)})
    capacity_fixture(%{scope: "synthetic-other"})

    capacity_fixture(%{
      source: %{
        adapter_id: "synthetic_adapter",
        provider_id: "claude",
        invocation_mode: "cli",
        event: :status_line_input
      }
    })

    cards = Usage.cards(DateTime.utc_now())
    assert length(cards) == 3
    assert Enum.find(cards, &(&1.provider == "codex" and &1.scope == "synthetic-account")).stale?
    assert Enum.find(cards, &(&1.scope == "synthetic-other")).status == "Observed"
  end

  test "daily peak history includes real gaps and respects scope" do
    now = DateTime.utc_now()
    date = DateTime.new!(Date.add(DateTime.to_date(now), -2), ~T[12:00:00], "Etc/UTC")

    capacity_fixture(%{
      observed_at: date,
      windows: [%{kind: "five_hour", state: :observed, used_percent: 20.0}]
    })

    capacity_fixture(%{
      observed_at: DateTime.add(date, 60),
      windows: [%{kind: "five_hour", state: :observed, used_percent: 40.0}]
    })

    capacity_fixture(%{
      scope: "synthetic-other",
      observed_at: date,
      windows: [%{kind: "five_hour", state: :observed, used_percent: 90.0}]
    })

    card = Enum.find(Usage.cards(now), &(&1.scope == "synthetic-account"))
    assert length(card.history) == 7
    assert Enum.at(card.history, 4).value == 40.0
    assert Enum.count(card.history, &is_nil(&1.value)) == 6
  end

  test "Codex windows show as the allowance their reported length makes them" do
    now = DateTime.utc_now()

    capacity_fixture(%{
      observed_at: now,
      windows: [
        %{kind: "primary", state: :observed, used_percent: 3.0, reset_at: DateTime.add(now, 60)},
        %{
          kind: "secondary",
          state: :observed,
          used_percent: 19.0,
          reset_at: DateTime.add(now, 90)
        }
      ],
      extensions: %{
        "codex:primary_window_minutes" => 300,
        "codex:secondary_window_minutes" => 10_080
      }
    })

    card = Enum.find(Usage.cards(now), &(&1.provider == "codex"))

    assert [%{kind: "five_hour", used_percent: 3.0}, %{kind: "seven_day", used_percent: 19.0}] =
             card.windows

    assert List.last(card.history).value == 3.0

    # A length that is neither keeps its own name, beside the unknown slots.
    capacity_fixture(%{
      scope: "synthetic-other",
      observed_at: now,
      windows: [%{kind: "primary", state: :observed, used_percent: 5.0}],
      extensions: %{"codex:primary_window_minutes" => 60}
    })

    other = Enum.find(Usage.cards(now), &(&1.scope == "synthetic-other"))
    assert Enum.map(other.windows, & &1.kind) == ["five_hour", "seven_day", "primary"]
    assert Enum.find(other.windows, &(&1.kind == "five_hour")).used_percent == nil
  end

  test "legacy credential markers render redacted while keeping allowance and stored evidence" do
    capacity_fixture()
    record = Repo.one!(Shoestring.Harness.CapacitySnapshotRecord)
    scope = "synthetic-account token=synthetic-secret-value"
    Repo.update_all(Shoestring.Harness.CapacitySnapshotRecord, set: [scope: scope])

    card = Enum.find(Usage.cards(), &(&1.provider == "codex"))
    assert card.scope == "synthetic-account token=[REDACTED]"
    assert card.status == "Observed"
    assert Enum.find(card.windows, &(&1.kind == "five_hour")).used_percent == 25.0
    refute inspect(card) =~ "synthetic-secret-value"
    unchanged = Repo.get!(Shoestring.Harness.CapacitySnapshotRecord, record.id)
    assert unchanged.scope == scope
  end
end
