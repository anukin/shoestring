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

  @evidence_root Path.expand("plans/evidence/00a-capacity-feasibility/fixtures")
  @target_root Path.expand("test/fixtures/capacity")

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

  defp sync_fixtures do
    if not File.dir?(@evidence_root) do
      Mix.raise("Evidence fixture directory #{@evidence_root} does not exist")
    end

    File.mkdir_p!(@target_root)
    File.cp_r!(@evidence_root, @target_root)
    Mix.shell().info("Synced fixtures from #{@evidence_root} to #{@target_root}")
  end

  defp scan_fixtures do
    case Fixtures.scan_all_fixtures() do
      {:ok, count} ->
        Mix.shell().info("Secret scan passed: #{count} tracked capacity fixtures verified clean.")

      {:error, violations} ->
        Mix.shell().error("Secret scan failed with violations:")

        Enum.each(violations, fn {path, issues} ->
          Mix.shell().error("  #{path}:")
          Enum.each(issues, fn issue -> Mix.shell().error("    - #{issue}") end)
        end)

        Mix.raise("Secret scan detected forbidden patterns in tracked fixtures")
    end
  end
end
