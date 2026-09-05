defmodule Shoestring.Harness.CodexAppServer.LiveSmokeTest do
  @moduledoc """
  Opt-in live smoke test for the Codex App-Server execution adapter (`@tag :live`).

  Excluded from ordinary CI and plain `mix test` via `test/test_helper.exs`.
  Run explicitly:

      mix test test/shoestring/harness/codex_app_server/live_smoke_test.exs --include live

  Verifies provider binary availability, version compatibility, and identity reporting.
  """
  use ExUnit.Case, async: false

  @moduletag :live

  alias Shoestring.Harness.CodexAppServer
  alias Shoestring.Test.CapacityLiveSmoke

  @command "codex"

  test "installed codex CLI version is available and identity matches" do
    case CapacityLiveSmoke.version_only(@command) do
      {:error, :not_found} ->
        IO.puts("SKIP (codex live smoke): `codex` binary not found on PATH; provider absent.")
        assert true

      {:error, reason} ->
        flunk(
          "ENVIRONMENT MISMATCH (codex live smoke): `codex --version` failed with #{inspect(reason)}"
        )

      {:ok, raw_version} ->
        assert is_binary(raw_version)
        identity = CodexAppServer.identity()
        assert identity.adapter_id == "codex_app_server_stdio"
        assert identity.provider == "codex"
        assert is_binary(identity.adapter_version)
    end
  end

  test "adapter declares verified capabilities" do
    caps = CodexAppServer.capabilities()
    assert :cancel in caps
    assert :resume in caps
  end
end
