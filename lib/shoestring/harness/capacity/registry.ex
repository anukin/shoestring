defmodule Shoestring.Harness.Capacity.Registry do
  @moduledoc """
  Authoritative capacity compatibility registry seeded from the Gate 0A support matrix.

  Represents provider, observation mode, tested CLI version(s), required semantic
  fields, supported tier, and compatibility outcome (`:compatible`, `:degraded`,
  or `:incompatible`).
  """

  alias Shoestring.Harness.Capacity.Registry.Entry

  @entries [
    %Entry{
      provider: :codex,
      invocation_mode: :app_server_stdio,
      supported_tier: :proactive,
      tested_versions: ["0.150.1"],
      required_semantic_fields: ["rateLimits", "primary", "secondary", "usedPercent"],
      compatibility_outcome: :compatible,
      description:
        "Codex App Server over stdio: handshake, account/rateLimits/read, and account/rateLimits/updated"
    },
    %Entry{
      provider: :claude,
      invocation_mode: :interactive_status_line,
      supported_tier: :conservative_partial,
      tested_versions: ["2.1.251"],
      required_semantic_fields: ["rate_limits", "used_percentage"],
      compatibility_outcome: :compatible,
      description: "Claude interactive official statusLine command callback"
    },
    %Entry{
      provider: :claude,
      invocation_mode: :headless_json,
      supported_tier: :unsupported,
      tested_versions: ["2.1.251"],
      required_semantic_fields: [],
      compatibility_outcome: :incompatible,
      description: "Claude headless -p --output-format json (does not expose capacity signals)"
    },
    %Entry{
      provider: :claude,
      invocation_mode: :headless_stream_json,
      supported_tier: :unsupported,
      tested_versions: ["2.1.251"],
      required_semantic_fields: [],
      compatibility_outcome: :incompatible,
      description:
        "Claude headless -p --output-format stream-json (process errors, no capacity signals)"
    },
    %Entry{
      provider: :claude,
      invocation_mode: :terminal_scrape,
      supported_tier: :unsupported,
      tested_versions: [],
      required_semantic_fields: [],
      compatibility_outcome: :incompatible,
      description: "Claude terminal scraping (explicitly unsupported non-structured output)"
    }
  ]

  @doc "Returns all registered compatibility entries seeded from Gate 0A."
  @spec entries() :: [Entry.t()]
  def entries, do: @entries

  @doc "Looks up a registry entry by provider and mode."
  @spec lookup(atom() | String.t(), atom() | String.t()) ::
          {:ok, Entry.t()} | {:error, :unsupported_provider | :unsupported_mode}
  def lookup(provider, mode) do
    with {:ok, provider_atom} <- normalize_provider(provider),
         {:ok, mode_atom} <- normalize_mode(provider_atom, mode) do
      case Enum.find(
             @entries,
             &(&1.provider == provider_atom and &1.invocation_mode == mode_atom)
           ) do
        nil -> {:error, :unsupported_mode}
        entry -> {:ok, entry}
      end
    end
  end

  @doc "Checks if the provided version matches one of the tested versions for an entry."
  @spec tested_version?(Entry.t(), String.t() | nil) :: boolean()
  def tested_version?(%Entry{tested_versions: versions}, version) when is_binary(version) do
    case normalize_version(version) do
      nil -> false
      normalized -> normalized in versions
    end
  end

  def tested_version?(_entry, _version), do: false

  @doc "Normalizes a CLI version string to bare semver (e.g. 'codex-cli 0.150.1' -> '0.150.1')."
  @spec normalize_version(String.t() | nil) :: String.t() | nil
  def normalize_version(nil), do: nil

  def normalize_version(version_string) when is_binary(version_string) do
    trimmed = String.trim(version_string)

    case Regex.run(~r/(?:^|[^\d])(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\b/, trimmed) do
      [_, semver] -> semver
      _ -> trimmed
    end
  end

  @doc "Normalizes provider atom or string."
  @spec normalize_provider(atom() | String.t()) :: {:ok, atom()} | {:error, :unsupported_provider}
  def normalize_provider(:codex), do: {:ok, :codex}
  def normalize_provider("codex"), do: {:ok, :codex}
  def normalize_provider(:claude), do: {:ok, :claude}
  def normalize_provider("claude"), do: {:ok, :claude}
  def normalize_provider(_), do: {:error, :unsupported_provider}

  @doc "Normalizes invocation mode atom or string for a given provider."
  @spec normalize_mode(atom(), atom() | String.t()) :: {:ok, atom()} | {:error, :unsupported_mode}
  def normalize_mode(:codex, mode)
      when mode in [
             :app_server_stdio,
             "app_server_stdio",
             "codex app-server --stdio",
             "app-server --stdio",
             "stdio"
           ],
      do: {:ok, :app_server_stdio}

  def normalize_mode(:claude, mode)
      when mode in [
             :interactive_status_line,
             "interactive_status_line",
             "status_line",
             "statusLine"
           ],
      do: {:ok, :interactive_status_line}

  def normalize_mode(:claude, mode)
      when mode in [
             :headless_json,
             "headless_json",
             "json",
             "claude --print --no-session-persistence --output-format json",
             "claude -p --output-format json"
           ],
      do: {:ok, :headless_json}

  def normalize_mode(:claude, mode)
      when mode in [
             :headless_stream_json,
             "headless_stream_json",
             "stream-json",
             "claude --print --no-session-persistence --output-format stream-json",
             "claude -p --output-format stream-json"
           ],
      do: {:ok, :headless_stream_json}

  def normalize_mode(:claude, mode)
      when mode in [
             :terminal_scrape,
             "terminal_scrape",
             "scrape"
           ],
      do: {:ok, :terminal_scrape}

  def normalize_mode(_provider, _mode), do: {:error, :unsupported_mode}
end
