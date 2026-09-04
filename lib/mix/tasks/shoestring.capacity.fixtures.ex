defmodule Mix.Tasks.Shoestring.Capacity.Fixtures do
  @shortdoc "Validates, scans, and manages tracked capacity test fixtures"

  @moduledoc """
  Manages tracked capacity fixtures for ExUnit tests.

  ## Commands

      $ mix shoestring.capacity.fixtures --scan
      $ mix shoestring.capacity.fixtures --sync
      $ mix shoestring.capacity.fixtures --live-smoke

  ## Options

    * `--scan` - Scans all tracked fixtures in `test/fixtures/capacity/` for secrets,
      authentication tokens, user filesystem paths, and forbidden keys.
    * `--sync` - Copies redacted fixtures from `plans/evidence/00a-capacity-feasibility/fixtures/`
      to `test/fixtures/capacity/`, preserving evidence originals while populating tracked test fixtures.
    * `--live-smoke` - Read-only live pre-check: runs `<cli> --version` only (no
      sessions, no prompts, no inference) for each installed provider CLI and
      compares the result against the tested registry versions. Never reads,
      writes, or modifies fixtures. A provider whose binary is absent is
      reported as skipped. Exits non-zero on version mismatch.

  See `docs/capacity-fixtures.md` for the full fixture lifecycle, regeneration,
  and secret-review procedure.
  """

  use Mix.Task

  alias Shoestring.Harness.Capacity
  alias Shoestring.Harness.Capacity.{Fixtures, Registry}

  @live_smoke_providers [
    {:codex, :app_server_stdio},
    {:claude, :interactive_status_line}
  ]

  @impl Mix.Task
  def run(args) do
    cond do
      "--live-smoke" in args ->
        live_smoke()

      "--sync" in args ->
        sync_fixtures()
        scan_fixtures()

      true ->
        scan_fixtures()
    end
  end

  defp project_root do
    case File.cwd() do
      {:ok, cwd} -> cwd
      _ -> Path.expand("../../../..", __DIR__)
    end
  end

  defp evidence_root do
    Path.expand("plans/evidence/00a-capacity-feasibility/fixtures", project_root())
  end

  defp target_root do
    Fixtures.fixture_root()
  end

  defp sync_fixtures do
    source = evidence_root()
    target = target_root()

    if not File.dir?(source) do
      Mix.raise("Evidence fixture directory #{source} does not exist")
    end

    File.mkdir_p!(target)
    File.cp_r!(source, target)
    Mix.shell().info("Synced fixtures from #{source} to #{target}")
  end

  defp live_smoke do
    mismatches =
      Enum.flat_map(@live_smoke_providers, fn {provider, mode} ->
        {:ok, entry} = Registry.lookup(provider, mode)

        case Capacity.discover_version(provider, timeout: 5_000) do
          {:error, :not_found} ->
            Mix.shell().info("SKIP (#{provider}): provider CLI not found on PATH.")
            []

          {:ok, %{raw: raw, version: version}} ->
            if Capacity.tested_version?(entry, version) do
              Mix.shell().info("OK (#{provider}): version #{version} is tested (raw: #{raw}).")
              []
            else
              Mix.shell().error(
                "MISMATCH (#{provider}): installed #{inspect(version)} is not in tested " <>
                  "#{inspect(entry.tested_versions)}. Fixtures unchanged; see docs/capacity-fixtures.md."
              )

              [{provider, version}]
            end

          {:error, reason} ->
            Mix.shell().error(
              "MISMATCH (#{provider}): `--version` probe failed with #{inspect(reason)}. " <>
                "Fixtures unchanged; see docs/capacity-fixtures.md."
            )

            [{provider, inspect(reason)}]
        end
      end)

    if mismatches == [] do
      Mix.shell().info("Live smoke passed: no fixture was read, written, or modified.")
    else
      Mix.raise("Live smoke reported an environment/version mismatch; fixtures left untouched")
    end
  end

  defp scan_fixtures do
    case Fixtures.scan_all_fixtures() do
      {:ok, count} ->
        Mix.shell().info("Secret scan passed: #{count} tracked capacity fixtures verified clean.")

      {:error, :no_fixtures_found} ->
        Mix.shell().error(
          "Secret scan failed: no tracked capacity fixtures found in #{target_root()}"
        )

        Mix.raise("Secret scan detected no tracked capacity fixtures")

      {:error, violations} when is_list(violations) ->
        Mix.shell().error("Secret scan failed with violations:")

        Enum.each(violations, fn {path, issues} ->
          Mix.shell().error("  #{path}:")
          Enum.each(issues, fn issue -> Mix.shell().error("    - #{issue}") end)
        end)

        Mix.raise("Secret scan detected forbidden patterns in tracked fixtures")
    end
  end
end
