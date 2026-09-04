defmodule Shoestring.Harness.Capacity.CodexLiveSmokeTest do
  @moduledoc """
  Opt-in live smoke test for the Codex provider (`@tag :live`).

  Excluded from ordinary CI and plain `mix test` via `test/test_helper.exs`.
  Run explicitly:

      mix test test/shoestring/harness/capacity/codex_live_smoke_test.exs --include live

  or a single test by line number:

      mix test test/shoestring/harness/capacity/codex_live_smoke_test.exs:19 --include live

  Low-consumption: the only provider process ever invoked is `codex --version`.
  No coding session is started, no prompt is sent, and no model inference is
  consumed. Safe to skip: when the `codex` binary is absent the tests report a
  skip, never a failure. A version mismatch reports an environment/version
  mismatch and MUST NOT modify tracked fixtures.
  """
  use ExUnit.Case, async: false

  @moduletag :live

  alias Shoestring.Harness.Capacity
  alias Shoestring.Harness.Capacity.Registry
  alias Shoestring.Test.CapacityLiveSmoke

  @provider :codex
  @mode :app_server_stdio
  @command "codex"

  test "installed codex CLI version matches a tested registry version (version check only)" do
    case CapacityLiveSmoke.version_only(@command) do
      {:error, :not_found} ->
        IO.puts("SKIP (codex live smoke): `codex` binary not found on PATH; provider absent.")
        assert true

      {:error, reason} ->
        flunk(
          "ENVIRONMENT MISMATCH (codex live smoke): `codex --version` failed " <>
            "with #{inspect(reason)}. Fixtures unchanged. See docs/capacity-fixtures.md."
        )

      {:ok, raw} ->
        version = Registry.normalize_version(raw)
        {:ok, entry} = Registry.lookup(@provider, @mode)

        if Capacity.tested_version?(entry, version) do
          compat = Capacity.compatibility(@provider, @mode, version)
          assert compat.compatibility_state == :compatible
          assert compat.support_tier == :proactive
        else
          flunk(CapacityLiveSmoke.mismatch_message(@provider, version, entry.tested_versions))
        end
    end
  end

  test "live smoke performs no inference and leaves tracked fixtures untouched" do
    before_hashes = CapacityLiveSmoke.snapshot_fixture_hashes()

    # The only provider invocation permitted in live smoke.
    _ = CapacityLiveSmoke.version_only(@command)

    after_hashes = CapacityLiveSmoke.snapshot_fixture_hashes()

    assert before_hashes == after_hashes,
           "Live smoke must never modify test/fixtures/capacity/; " <>
             "a live failure reports a mismatch instead of updating fixtures."

    assert map_size(after_hashes) > 0
  end
end
