defmodule Mix.Tasks.Shoestring.Capacity.Fixtures do
  @shortdoc "Validates, scans, and manages tracked capacity test fixtures"

  @moduledoc """
  Manages tracked capacity fixtures for ExUnit tests.

  ## Commands

      $ mix shoestring.capacity.fixtures --scan
      $ mix shoestring.capacity.fixtures --sync

  ## Options

    * `--scan` - Scans all tracked fixtures in `test/fixtures/capacity/` for secrets,
      authentication tokens, user filesystem paths, and forbidden keys.
    * `--sync` - Copies redacted fixtures from `plans/evidence/00a-capacity-feasibility/fixtures/`
      to `test/fixtures/capacity/`, preserving evidence originals while populating tracked test fixtures.
  """

  use Mix.Task

  alias Shoestring.Harness.Capacity.Fixtures

  @impl Mix.Task
  def run(args) do
    cond do
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
