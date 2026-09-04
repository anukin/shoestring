defmodule ShoestringWeb.CapacityObservatoryLiveTest do
  use ShoestringWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Shoestring.Harness.Observatory
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Repo
  alias ShoestringWeb.CapacityObservatoryLive

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

  test "empty: zero observations render an explicit empty state, not a blank grid", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/observatory")

    assert html =~ "No observations yet"
    assert has_element?(view, "#observations-empty")
    refute has_element?(view, "#observations-list > div")
  end

  test "normal: both windows present, correct values + reset + provenance", %{conn: conn} do
    ingest_fixture(%{})

    {:ok, view, html} = live(conn, "/observatory")

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
    assert has_element?(view, "[data-status=\"healthy\"]")
    assert has_element?(view, "[data-stale=\"false\"]")
    # No version reported by default
    assert html =~ "CLI version: not reported"
  end

  test "cli version: discovered adapter version from extensions is rendered", %{conn: conn} do
    ingest_fixture(%{extensions: %{"capacity:cli_version" => "2.1.7"}})

    {:ok, _view, html} = live(conn, "/observatory")

    assert html =~ "CLI version: 2.1.7"
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

    {:ok, view, html} = live(conn, "/observatory")

    assert html =~ "Capacity Observatory"
    assert html =~ "Unknown / Absent"
    assert html =~ "missing in output"
    refute html =~ ">0%<"
    refute html =~ ">0.0%<"
    assert html =~ "45.5%"
    assert has_element?(view, "[data-status=\"partial\"]")
    assert html =~ "Partial observation"
  end

  test "stale: degraded past the configured staleness boundary keeps its primary state plus a stale marker",
       %{conn: conn} do
    past = DateTime.add(DateTime.utc_now(), -600, :second)

    ingest_fixture(
      observed_at: past,
      capacity_state: :degraded,
      confidence: :medium,
      reason: "stale_observation: capacity probe overdue"
    )

    {:ok, view, html} = live(conn, "/observatory")

    # Primary state is preserved (both default windows observed -> degraded) ...
    assert has_element?(view, "[data-status=\"degraded\"]")
    assert html =~ "Degraded observation"
    # ... and staleness is surfaced additively, not instead of the primary.
    assert has_element?(view, "[data-stale=\"true\"]")
    assert has_element?(view, "[data-stale-badge=\"true\"]")
    assert html =~ "Stale observation"
    assert html =~ "stale_observation"
  end

  test "stale refusal: a refusal that is also stale shows BOTH the refusal and the stale marker",
       %{conn: conn} do
    past = DateTime.add(DateTime.utc_now(), -600, :second)

    ingest_fixture(
      observed_at: past,
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "provider refused"
    )

    {:ok, view, html} = live(conn, "/observatory")

    assert has_element?(view, "[data-status=\"refused\"]")
    assert html =~ "Refused by provider"
    assert has_element?(view, "[data-stale=\"true\"]")
    assert has_element?(view, "[data-stale-badge=\"true\"]")
    assert html =~ "Stale observation"
    refute has_element?(view, "[data-status=\"hard-block\"]")
  end

  test "version drift / incompatible -> degraded badge WITH a human-readable reason", %{
    conn: conn
  } do
    ingest_fixture(
      compatibility_state: :degraded,
      support_tier: :reactive_only,
      capacity_state: :degraded,
      confidence: :medium,
      reason: "Version drift detected"
    )

    {:ok, view, html} = live(conn, "/observatory")

    assert html =~ "degraded"
    assert html =~ "Version drift detected"
    # Assert on the specific presentational badge, not the raw capacity_state text
    assert has_element?(view, "[data-status=\"degraded\"]")
    assert html =~ "Degraded observation"
  end

  test "hard block: refused with rate-limit reason renders the hard-block state", %{conn: conn} do
    ingest_fixture(
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "rate limit reached: quota exhausted"
    )

    {:ok, view, html} = live(conn, "/observatory")

    assert html =~ "refused"
    assert html =~ "rate limit reached"
    assert has_element?(view, "[data-status=\"hard-block\"]")
    assert html =~ "Hard block"
  end

  test "authentication-required: refused with auth reason renders a distinct state", %{
    conn: conn
  } do
    ingest_fixture(
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "authentication required: provider login expired"
    )

    {:ok, view, html} = live(conn, "/observatory")

    assert html =~ "refused"
    assert html =~ "authentication required"
    assert has_element?(view, "[data-status=\"auth-required\"]")
    assert html =~ "Authentication required"
    refute has_element?(view, "[data-status=\"hard-block\"]")
  end

  test "generic refusal: refused without hard-block keywords renders refused, NOT hard-block",
       %{conn: conn} do
    ingest_fixture(
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "provider refused"
    )

    {:ok, view, html} = live(conn, "/observatory")

    assert html =~ "Refused by provider"
    assert has_element?(view, "[data-status=\"refused\"]")
    refute has_element?(view, "[data-status=\"hard-block\"]")
  end

  test "hard block, auth-required, and disconnected render as distinguishable states", %{
    conn: conn
  } do
    ingest_fixture(
      scope: "scope-block",
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "rate limit reached: quota exhausted"
    )

    ingest_fixture(
      scope: "scope-auth",
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "authentication required: provider login expired"
    )

    ingest_fixture(
      scope: "scope-disc",
      capacity_state: :unknown,
      confidence: :none,
      windows: [],
      reason: "disconnected: provider unreachable"
    )

    {:ok, view, _html} = live(conn, "/observatory")

    assert has_element?(view, "[data-status=\"hard-block\"]")
    assert has_element?(view, "[data-status=\"auth-required\"]")
    assert has_element?(view, "[data-status=\"disconnected\"]")
  end

  test "unknown / disconnected -> honest unknown, never 0% and never available", %{conn: conn} do
    ingest_fixture(
      capacity_state: :unknown,
      confidence: :none,
      windows: [],
      reason: "disconnected: provider unreachable"
    )

    {:ok, view, html} = live(conn, "/observatory")

    assert html =~ "disconnected"
    assert html =~ "No windows recorded."
    refute html =~ ">0%<"
    assert has_element?(view, "[data-status=\"disconnected\"]")
    assert html =~ "Disconnected"
  end

  test "a secret-bearing reason is redacted at the UI boundary before rendering", %{
    conn: conn
  } do
    ingest_fixture(
      windows: [
        %{kind: "five_hour", state: :unknown, reason: "missing output at /Users/eve/.cache/dump"}
      ],
      capacity_state: :refused,
      confidence: :none,
      reason: "probe failed reading /Users/eve/.config/provider-cache"
    )

    {:ok, _view, html} = live(conn, "/observatory")

    # The real rendered reason text must not leak the raw path ...
    refute html =~ "/Users/eve"
    refute html =~ "/Users/eve/.config/provider-cache"
    refute html =~ "/Users/eve/.cache/dump"
    # ... and the redaction marker is shown instead.
    assert html =~ "[REDACTED]"
  end

  test "AWS access key IDs never reach the rendered HTML", %{conn: conn} do
    key_id = "AKIAIOSFODNN7EXAMPLE"

    ingest_fixture(
      scope: "scope-aws",
      windows: [
        %{kind: "five_hour", state: :unknown, reason: "probe saw key #{key_id} in output"}
      ],
      capacity_state: :refused,
      confidence: :none,
      reason: "refused after reporting key #{key_id}"
    )

    {:ok, _view, html} = live(conn, "/observatory")

    refute html =~ key_id
    assert html =~ "[REDACTED_API_KEY]"
  end

  test "GitHub-shaped tokens never reach the rendered HTML", %{conn: conn} do
    classic = "ghp_abcdefghijklmnopqrstuvwx1234567890"
    fine_grained = "github_pat_abcDEF1234567890_xyzTOKEN"

    ingest_fixture(
      scope: "scope-ghp",
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "refused with token #{classic} present"
    )

    ingest_fixture(
      scope: "scope-pat",
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "refused with token #{fine_grained} present"
    )

    {:ok, _view, html} = live(conn, "/observatory")

    refute html =~ classic
    refute html =~ fine_grained
    assert html =~ "[REDACTED_API_KEY]"
  end

  test "XML/tag-wrapped secret contents never reach the rendered HTML", %{conn: conn} do
    ingest_fixture(
      scope: "scope-xml",
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "failure: <secret>hunter2-xml-value</secret> end"
    )

    {:ok, _view, html} = live(conn, "/observatory")

    refute html =~ "hunter2-xml-value"
    assert html =~ "[REDACTED]"
  end

  test "compound secret/key assignments never reach the rendered HTML", %{conn: conn} do
    ingest_fixture(
      scope: "scope-compound",
      windows: [],
      capacity_state: :refused,
      confidence: :none,
      reason: "config aws_secret_access_key=SUPERSECRET123 with custom_key=other-secret-456"
    )

    {:ok, _view, html} = live(conn, "/observatory")

    refute html =~ "SUPERSECRET123"
    refute html =~ "other-secret-456"
    assert html =~ "[REDACTED]"
  end

  describe "presentational_state/1" do
    defp summary(overrides) do
      Map.merge(
        %{
          eligible?: false,
          capacity_state: :degraded,
          freshness_state: :fresh,
          compatibility_state: :compatible,
          reason: "Version drift detected",
          windows: [%{kind: "five_hour", state: :observed}]
        },
        Map.new(overrides)
      )
    end

    test "eligible summaries are healthy" do
      assert CapacityObservatoryLive.presentational_state(summary(eligible?: true)) == :healthy
    end

    test "refused splits into auth-required, hard-block, and generic refused" do
      base = %{capacity_state: :refused, freshness_state: :unknown, windows: []}

      assert CapacityObservatoryLive.presentational_state(
               summary(Map.put(base, :reason, "authentication required"))
             ) == :auth_required

      assert CapacityObservatoryLive.presentational_state(
               summary(Map.put(base, :reason, "rate limit reached: quota exhausted"))
             ) == :hard_block

      assert CapacityObservatoryLive.presentational_state(
               summary(Map.put(base, :reason, "provider said no"))
             ) == :refused
    end

    test "unknown splits into disconnected and generic unknown" do
      base = %{capacity_state: :unknown, freshness_state: :unknown, windows: []}

      assert CapacityObservatoryLive.presentational_state(
               summary(Map.put(base, :reason, "disconnected: unreachable"))
             ) == :disconnected

      assert CapacityObservatoryLive.presentational_state(
               summary(Map.put(base, :reason, "no data yet"))
             ) == :unknown
    end

    test "stale is additive: staleness never replaces the primary state" do
      assert CapacityObservatoryLive.presentational_state(
               summary(%{
                 capacity_state: :degraded,
                 freshness_state: :stale,
                 reason: "stale_observation",
                 windows: [
                   %{kind: "five_hour", state: :observed},
                   %{kind: "seven_day", state: :unknown}
                 ]
               })
             ) == :partial

      assert CapacityObservatoryLive.stale?(
               summary(%{freshness_state: :stale, reason: "stale_observation"})
             )

      refute CapacityObservatoryLive.stale?(summary(%{freshness_state: :fresh}))
    end

    test "stale refusals and unknowns keep their primary state plus the stale marker" do
      refused_stale =
        summary(%{
          capacity_state: :refused,
          freshness_state: :stale,
          reason: "provider refused",
          windows: []
        })

      assert CapacityObservatoryLive.presentational_state(refused_stale) == :refused
      assert CapacityObservatoryLive.stale?(refused_stale)

      unknown_stale =
        summary(%{capacity_state: :unknown, freshness_state: :stale, reason: "no data yet"})

      assert CapacityObservatoryLive.presentational_state(unknown_stale) == :unknown
      assert CapacityObservatoryLive.stale?(unknown_stale)
    end

    test "stale observed summaries demote to degraded plus the stale marker, never healthy" do
      stale_observed =
        summary(%{
          capacity_state: :observed,
          freshness_state: :stale,
          reason: "stale_observation",
          windows: [%{kind: "five_hour", state: :observed}]
        })

      assert CapacityObservatoryLive.presentational_state(stale_observed) == :degraded
      assert CapacityObservatoryLive.stale?(stale_observed)
    end

    test "generic refusal prose renders refused, not hard-block" do
      base = %{capacity_state: :refused, freshness_state: :unknown, windows: []}

      assert CapacityObservatoryLive.presentational_state(
               summary(Map.put(base, :reason, "provider refused"))
             ) == :refused

      assert CapacityObservatoryLive.presentational_state(
               summary(Map.put(base, :reason, "provider blocked the request"))
             ) == :refused
    end

    test "degraded splits into partial and generic degraded" do
      assert CapacityObservatoryLive.presentational_state(
               summary(%{
                 capacity_state: :degraded,
                 reason: "missing_window: secondary",
                 windows: [
                   %{kind: "five_hour", state: :observed},
                   %{kind: "seven_day", state: :unknown}
                 ]
               })
             ) == :partial

      assert CapacityObservatoryLive.presentational_state(
               summary(%{capacity_state: :degraded, reason: "Version drift detected"})
             ) == :degraded
    end

    test "every state maps to a distinct status tag" do
      statuses =
        [
          :healthy,
          :hard_block,
          :auth_required,
          :disconnected,
          :partial,
          :stale,
          :degraded,
          :refused,
          :unknown
        ]
        |> Enum.map(&CapacityObservatoryLive.status_presentation(&1).status)

      assert length(Enum.uniq(statuses)) == length(statuses)
    end
  end
end
