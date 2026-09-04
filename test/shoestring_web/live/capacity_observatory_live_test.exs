defmodule ShoestringWeb.CapacityObservatoryLiveTest do
  use ShoestringWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Shoestring.Harness.Observatory
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Repo

  setup do
    # Clear the capacity observer repo
    Repo.delete_all(Shoestring.Harness.CapacitySnapshotRecord)
    :ok
  end

  defp ingest_fixture(opts) do
    # helper
    defaults = %{
      version: 2,
      capacity_state: :observed,
      windows: [
        %{
          kind: "five_hour",
          state: :observed,
          used_percent: 25.0,
          reset_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        %{
          kind: "seven_day",
          state: :observed,
          used_percent: 45.0,
          reset_at: DateTime.add(DateTime.utc_now(), 86400, :second)
        }
      ],
      freshness: %{max_age_seconds: 300},
      source: %{
        adapter_id: "fake_adapter",
        provider_id: "fake_provider",
        invocation_mode: "cli",
        event: :explicit_read
      },
      scope: "account-123",
      confidence: :high,
      support_tier: :proactive,
      compatibility_state: :compatible,
      observed_at: DateTime.utc_now(),
      snapshot_id: Ecto.UUID.generate(),
      reason: nil,
      extensions: %{}
    }

    merged = Map.merge(defaults, Map.new(opts))
    {:ok, snapshot} = CapacitySnapshot.new(merged)
    {:ok, _, _} = Observatory.ingest(snapshot)
    snapshot
  end

  test "normal: both windows present, correct values + reset + provenance", %{conn: conn} do
    ingest_fixture(%{})

    {:ok, _view, html} = live(conn, "/observatory")

    assert html =~ "Capacity Observatory"
    assert html =~ "fake_provider"
    assert html =~ "Scope: account-123"
    assert html =~ "25.0%"
    assert html =~ "45.0%"
    assert html =~ "five_hour"
    assert html =~ "seven_day"
    assert html =~ "fake_adapter"
    assert html =~ "proactive"
    assert html =~ "compatible"
    assert html =~ "Eligible for automatic admission"
  end

  test "partial: ONE window absent must render as partial/absent, and must NOT contain 0% for the missing window",
       %{conn: conn} do
    ingest_fixture(
      windows: [
        %{kind: "five_hour", state: :unknown, reason: "missing in output"},
        %{kind: "seven_day", state: :observed, used_percent: 45.5, reset_at: nil}
      ],
      capacity_state: :degraded,
      confidence: :medium,
      reason: "Partial failure",
      support_tier: :conservative_partial
    )

    {:ok, _view, html} = live(conn, "/observatory")

    assert html =~ "Capacity Observatory"
    assert html =~ "Unknown / Absent"
    assert html =~ "missing in output"
    refute html =~ ">0%<"
    refute html =~ ">0.0%<"
    assert html =~ "45.5%"
    assert html =~ "Ineligible for automatic admission"
  end

  test "stale: past the configured staleness boundary -> ineligible, and not presented as usable capacity",
       %{conn: conn} do
    past = DateTime.add(DateTime.utc_now(), -600, :second)

    ingest_fixture(
      windows: [],
      observed_at: past,
      capacity_state: :unknown,
      confidence: :none,
      reason: "stale"
    )

    {:ok, _view, html} = live(conn, "/observatory")

    assert html =~ "stale"
    assert html =~ "Ineligible for automatic admission"
  end

  test "version drift / incompatible -> degraded WITH a human-readable reason", %{conn: conn} do
    ingest_fixture(
      compatibility_state: :degraded,
      support_tier: :reactive_only,
      capacity_state: :degraded,
      confidence: :medium,
      reason: "Version drift detected"
    )

    {:ok, _view, html} = live(conn, "/observatory")

    assert html =~ "degraded"
    assert html =~ "Version drift detected"
    assert html =~ "Ineligible for automatic admission"
  end

  test "hard block and authentication-required states", %{conn: conn} do
    ingest_fixture(
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "authentication required"
    )

    {:ok, _view, html} = live(conn, "/observatory")

    assert html =~ "refused"
    assert html =~ "authentication required"
    assert html =~ "Ineligible for automatic admission"
  end

  test "unknown / disconnected -> honest unknown, never 0% and never available", %{conn: conn} do
    ingest_fixture(
      capacity_state: :unknown,
      confidence: :none,
      windows: [],
      reason: "disconnected"
    )

    {:ok, _view, html} = live(conn, "/observatory")

    assert html =~ "disconnected"
    assert html =~ "No windows recorded."
    refute html =~ ">0%<"
    assert html =~ "Ineligible for automatic admission"
  end

  test "a secret-bearing fixture -> auth/path fields never appear in the rendered HTML", %{
    conn: conn
  } do
    ingest_fixture(
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "Failed due to auth: <secret>MY_SUPER_SECRET</secret>",
      extensions: %{"claude:path" => "/secret/path"}
    )

    {:ok, _view, html} = live(conn, "/observatory")

    refute html =~ "/secret/path"
  end
end
