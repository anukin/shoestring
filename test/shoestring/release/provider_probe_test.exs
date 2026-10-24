defmodule Shoestring.Release.ProviderProbeTest do
  use ExUnit.Case, async: true

  test "version/auth output excludes account data, paths and credentials while retaining useful status" do
    runner = fn
      "claude", ["--version"] ->
        {:ok, 0, "2.1.261 (Claude Code)"}

      "codex", ["--version"] ->
        {:ok, 0, "codex-cli 0.163.0"}

      "claude", ["auth", "status"] ->
        {:ok, 0,
         ~s({"email":"synthetic@example.invalid","configDirectory":"/Users/synthetic/.claude","apiKey":"synthetic-private-value"})}

      "codex", ["login", "status"] ->
        {:ok, 1, "Not logged in /home/synthetic/.auth"}

      # Any other opencode command (`auth list`) would start opencode's
      # detached background server; only the version may be read.
      "opencode", ["--version"] ->
        {:ok, 0, "opencode v2.0.31"}
    end

    report = Shoestring.Release.ProviderProbe.report(runner)
    assert report["claude"]["authentication"] == "reported_authenticated"
    assert report["codex"]["authentication"] == "reported_unauthenticated"
    assert report["codex"]["cli_version"] == "0.163.0"
    assert report["codex"]["compatibility"] == "requires_fixture_review"
    assert report["opencode"]["cli_version"] == "2.0.31"
    assert report["opencode"]["authentication"] == "not_detectable"
    bytes = Jason.encode!(report)

    for marker <- [
          "synthetic@example.invalid",
          "synthetic-private-value",
          "/Users/",
          "/home/",
          "configDirectory",
          "apiKey"
        ],
        do: refute(bytes =~ marker)
  end
end
