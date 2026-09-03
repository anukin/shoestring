defmodule Shoestring.Harness.Capacity.RegistryTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.Capacity.Registry
  alias Shoestring.Harness.Capacity.Registry.Entry

  describe "entries/0 and lookup/2" do
    test "seeds authoritative Gate 0A support matrix entries" do
      entries = Registry.entries()

      assert length(entries) == 5

      providers = Enum.map(entries, & &1.provider) |> Enum.uniq() |> Enum.sort()
      assert providers == [:claude, :codex]

      codex_stdio =
        Enum.find(entries, &(&1.provider == :codex and &1.invocation_mode == :app_server_stdio))

      assert %Entry{} = codex_stdio
      assert codex_stdio.supported_tier == :proactive
      assert codex_stdio.compatibility_outcome == :compatible
      assert codex_stdio.tested_versions == ["0.150.1"]
      assert "rateLimits" in codex_stdio.required_semantic_fields
      assert "primary" in codex_stdio.required_semantic_fields
      assert "secondary" in codex_stdio.required_semantic_fields

      claude_statusline =
        Enum.find(
          entries,
          &(&1.provider == :claude and &1.invocation_mode == :interactive_status_line)
        )

      assert %Entry{} = claude_statusline
      assert claude_statusline.supported_tier == :conservative_partial
      assert claude_statusline.compatibility_outcome == :compatible
      assert claude_statusline.tested_versions == ["2.1.251"]
      assert "rate_limits" in claude_statusline.required_semantic_fields

      claude_headless_json =
        Enum.find(entries, &(&1.provider == :claude and &1.invocation_mode == :headless_json))

      assert %Entry{} = claude_headless_json
      assert claude_headless_json.supported_tier == :unsupported
      assert claude_headless_json.compatibility_outcome == :incompatible

      claude_headless_stream =
        Enum.find(
          entries,
          &(&1.provider == :claude and &1.invocation_mode == :headless_stream_json)
        )

      assert %Entry{} = claude_headless_stream
      assert claude_headless_stream.supported_tier == :unsupported
      assert claude_headless_stream.compatibility_outcome == :incompatible

      claude_scrape =
        Enum.find(entries, &(&1.provider == :claude and &1.invocation_mode == :terminal_scrape))

      assert %Entry{} = claude_scrape
      assert claude_scrape.supported_tier == :unsupported
      assert claude_scrape.compatibility_outcome == :incompatible
    end

    test "lookup/2 resolves supported modes with atoms and strings" do
      assert {:ok, %Entry{provider: :codex, invocation_mode: :app_server_stdio}} =
               Registry.lookup(:codex, :app_server_stdio)

      assert {:ok, %Entry{provider: :codex, invocation_mode: :app_server_stdio}} =
               Registry.lookup("codex", "codex app-server --stdio")

      assert {:ok, %Entry{provider: :codex, invocation_mode: :app_server_stdio}} =
               Registry.lookup("codex", "stdio")

      assert {:ok, %Entry{provider: :claude, invocation_mode: :interactive_status_line}} =
               Registry.lookup(:claude, :interactive_status_line)

      assert {:ok, %Entry{provider: :claude, invocation_mode: :interactive_status_line}} =
               Registry.lookup("claude", "status_line")

      assert {:ok, %Entry{provider: :claude, invocation_mode: :interactive_status_line}} =
               Registry.lookup("claude", "statusLine")

      assert {:ok, %Entry{provider: :claude, invocation_mode: :headless_json}} =
               Registry.lookup("claude", "json")

      assert {:ok, %Entry{provider: :claude, invocation_mode: :headless_stream_json}} =
               Registry.lookup("claude", "stream-json")

      assert {:ok, %Entry{provider: :claude, invocation_mode: :terminal_scrape}} =
               Registry.lookup("claude", "scrape")
    end

    test "lookup/2 rejects unsupported providers and modes" do
      assert {:error, :unsupported_provider} = Registry.lookup(:openai, :app_server_stdio)
      assert {:error, :unsupported_provider} = Registry.lookup("gemini", :app_server_stdio)
      assert {:error, :unsupported_mode} = Registry.lookup(:codex, :unknown_mode)
      assert {:error, :unsupported_mode} = Registry.lookup(:claude, :unknown_mode)
    end
  end

  describe "tested_version?/2 and normalize_version/1" do
    setup do
      {:ok, codex_entry} = Registry.lookup(:codex, :app_server_stdio)
      {:ok, claude_entry} = Registry.lookup(:claude, :interactive_status_line)
      %{codex_entry: codex_entry, claude_entry: claude_entry}
    end

    test "normalizes and matches tested versions", %{codex_entry: codex, claude_entry: claude} do
      assert Registry.tested_version?(codex, "0.150.1")
      assert Registry.tested_version?(codex, "codex-cli 0.150.1")
      assert Registry.tested_version?(codex, "  0.150.1 \n")

      assert Registry.tested_version?(claude, "2.1.251")
      assert Registry.tested_version?(claude, "2.1.251 (Claude Code)")
      assert Registry.tested_version?(claude, "claude 2.1.251")
    end

    test "rejects version drift or unparseable versions", %{
      codex_entry: codex,
      claude_entry: claude
    } do
      refute Registry.tested_version?(codex, "0.151.0")
      refute Registry.tested_version?(codex, "1.0.0")
      refute Registry.tested_version?(codex, nil)
      refute Registry.tested_version?(codex, "")

      refute Registry.tested_version?(claude, "2.2.0")
      refute Registry.tested_version?(claude, "3.0.0")
      refute Registry.tested_version?(claude, nil)
      refute Registry.tested_version?(claude, "")
    end

    test "normalize_version/1 extracts semantic version numbers" do
      assert Registry.normalize_version("codex-cli 0.150.1") == "0.150.1"
      assert Registry.normalize_version("2.1.251 (Claude Code)") == "2.1.251"
      assert Registry.normalize_version("v1.2.3") == "1.2.3"
      assert Registry.normalize_version("0.150.1-beta.1") == "0.150.1-beta.1"
      assert Registry.normalize_version("non_semver_string") == "non_semver_string"
      assert Registry.normalize_version(nil) == nil
      assert Registry.normalize_version(123) == nil
      assert Registry.normalize_version(0.150) == nil
      assert Registry.normalize_version(%{"ver" => "1.0"}) == nil
      assert Registry.normalize_version([1, 2, 3]) == nil
      assert Registry.normalize_version(:some_atom) == nil
    end

    test "tested_version?/2 safely rejects non-string versions", %{
      codex_entry: codex,
      claude_entry: claude
    } do
      refute Registry.tested_version?(codex, 123)
      refute Registry.tested_version?(codex, %{"version" => "0.150.1"})
      refute Registry.tested_version?(codex, [:a, :b])
      refute Registry.tested_version?(codex, :atom)

      refute Registry.tested_version?(claude, 123)
      refute Registry.tested_version?(claude, %{"version" => "2.1.251"})
      refute Registry.tested_version?(claude, [:a, :b])
      refute Registry.tested_version?(claude, :atom)
    end
  end
end
