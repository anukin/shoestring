defmodule Shoestring.Harness.Capacity.FixtureLifecycleTest do
  @moduledoc """
  Deterministic lifecycle guards for tracked capacity fixtures.

  These tests run in the ordinary suite (no `:live` tag) and pin the fixture
  lifecycle contract documented in `docs/capacity-fixtures.md`:

    1. The tracked set in `test/fixtures/capacity/` mirrors the Gate 0A
       evidence set in `plans/evidence/00a-capacity-feasibility/fixtures/`
       exactly — one canonical set, never a second parallel set.
    2. Every tracked fixture is a valid JSON envelope that is secret-free per
       `Shoestring.Harness.Security`.
    3. Every tracked fixture normalizes through `Capacity.normalize/4` into one
       of the required states (`:observed`, `:degraded`, `:unknown`,
       `:refused`), and each provider's corpus covers its required states.

  Per-fixture value assertions live in `FixturesTest`; this module guards the
  lifecycle (no drift, no secrets, required-state coverage).
  """
  use ExUnit.Case, async: true

  alias Shoestring.Harness.Capacity
  alias Shoestring.Harness.Capacity.Fixtures, as: CapacityFixtures
  alias Shoestring.Harness.Security

  @required_states [:observed, :degraded, :unknown, :refused]
  # Claude is a conservative-partial source: it never reports `:observed`.
  @required_by_provider %{codex: @required_states, claude: [:degraded, :unknown, :refused]}

  @tested_version %{codex: "0.150.1", claude: "2.1.251"}
  @fallback_now %{codex: ~U[2026-08-29 04:38:25Z], claude: ~U[2026-08-29 07:34:25Z]}

  test "tracked fixture set mirrors the Gate 0A evidence set exactly" do
    evidence_root =
      Path.join([
        File.cwd!(),
        "plans",
        "evidence",
        "00a-capacity-feasibility",
        "fixtures"
      ])

    tracked = CapacityFixtures.list_fixtures() |> MapSet.new()

    evidence =
      Path.join(evidence_root, "**/*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, evidence_root))
      |> MapSet.new()

    assert MapSet.size(tracked) > 0

    assert tracked == evidence,
           "Tracked fixtures must mirror Gate 0A evidence 1:1 " <>
             "(missing: #{inspect(MapSet.difference(evidence, tracked) |> MapSet.to_list())}, " <>
             "extra: #{inspect(MapSet.difference(tracked, evidence) |> MapSet.to_list())})"
  end

  test "every tracked fixture is a valid secret-free JSON envelope" do
    for rel_path <- CapacityFixtures.list_fixtures() do
      raw = rel_path |> then(&Path.join(CapacityFixtures.fixture_root(), &1)) |> File.read!()

      assert Security.scan_json(raw) == [],
             "Secret review failed for #{rel_path}: #{inspect(Security.scan_json(raw))}"

      assert {:ok, decoded} = Jason.decode(raw)
      assert Security.scan_term(decoded) == [], "Term scan failed for #{rel_path}"
      assert is_binary(decoded["evidence_status"]), "#{rel_path} must carry evidence_status"
    end
  end

  test "every tracked fixture normalizes into a required state" do
    for rel_path <- CapacityFixtures.list_fixtures() do
      {provider, mode} = provider_and_mode(rel_path)
      fixture = CapacityFixtures.load_fixture!(rel_path)

      assert {:ok, snapshot} =
               Capacity.normalize(provider, mode, fixture,
                 version: @tested_version[provider],
                 now: eval_time(provider, rel_path, fixture)
               ),
             "Fixture #{rel_path} must normalize without error"

      assert snapshot.capacity_state in @required_states,
             "Fixture #{rel_path} normalized to unexpected state " <>
               "#{inspect(snapshot.capacity_state)}"
    end
  end

  test "each provider corpus covers its required states (live smoke optional)" do
    for {provider, required} <- @required_by_provider do
      states =
        CapacityFixtures.list_fixtures()
        |> Enum.filter(&String.starts_with?(&1, "#{provider}/"))
        |> Enum.map(fn rel_path ->
          {_provider, mode} = provider_and_mode(rel_path)
          fixture = CapacityFixtures.load_fixture!(rel_path)

          {:ok, snapshot} =
            Capacity.normalize(provider, mode, fixture,
              version: @tested_version[provider],
              now: eval_time(provider, rel_path, fixture)
            )

          snapshot.capacity_state
        end)
        |> MapSet.new()

      assert MapSet.subset?(MapSet.new(required), states),
             "Provider #{provider} corpus must cover #{inspect(required)}, got #{inspect(states)}"
    end
  end

  defp provider_and_mode("codex/" <> _), do: {:codex, :app_server_stdio}
  defp provider_and_mode("claude/auth-preflight-live.json"), do: {:claude, :headless_json}
  defp provider_and_mode("claude/" <> _), do: {:claude, :interactive_status_line}

  defp eval_time(provider, rel_path, fixture) do
    base =
      case fixture do
        %{"captured_at" => captured_at} when is_binary(captured_at) ->
          case DateTime.from_iso8601(captured_at) do
            {:ok, dt, _} -> dt
            _ -> @fallback_now[provider]
          end

        _ ->
          @fallback_now[provider]
      end

    # Stale-replay fixtures only exhibit the stale state when evaluated past
    # the freshness window; every other fixture is evaluated at capture time.
    if String.contains?(rel_path, "stale") do
      DateTime.add(base, 3_600, :second)
    else
      base
    end
  end
end
