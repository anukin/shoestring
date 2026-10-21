defmodule Shoestring.Diagnostics.Runtime do
  @moduledoc "Passive, allowlisted diagnostic metadata; never probes providers or reads credentials."

  @codex_fixture Path.expand(
                   "../../../test/fixtures/codex/app_server/initialize-handshake.json",
                   __DIR__
                 )
  @claude_fixture Path.expand(
                    "../../../test/fixtures/capacity/claude/normal-official-shape.json",
                    __DIR__
                  )
  @external_resource @codex_fixture
  @external_resource @claude_fixture
  @fixture_hashes %{
    "codex-initialize-v1" =>
      :crypto.hash(:sha256, File.read!(@codex_fixture)) |> Base.encode16(case: :lower),
    "claude-capacity-v1" =>
      :crypto.hash(:sha256, File.read!(@claude_fixture)) |> Base.encode16(case: :lower)
  }

  def collect do
    %{
      "runtime" => %{
        "shoestring" => Application.spec(:shoestring, :vsn) |> to_string(),
        "elixir" => System.version(),
        "otp" => System.otp_release(),
        "os" => os(),
        "architecture" => architecture(),
        "terminal_protocol" => Shoestring.Terminal.Protocol.version(),
        "release" => if(System.get_env("RELEASE_NAME"), do: "release", else: "development")
      },
      "configuration" => configuration(),
      "health" => %{
        "repository" => "readable",
        "sqlite_version" => sqlite_version(),
        "state_directory" => state_directory(),
        "provider_authentication" => "not_checked",
        "helper_compatibility" => "not_checked"
      },
      "compatibility_fixtures" => @fixture_hashes
    }
  end

  defp configuration do
    api = Application.get_env(:shoestring, :api_execution, %{})
    api = if is_map(api), do: api, else: %{}

    %{
      "forecast_enforcement" => false,
      "api_enabled" => api[:enabled] == true,
      "api_cap_microusd" => cap(api[:monthly_cap_microusd]),
      "capacity_monitors" =>
        Map.new([:claude, :codex], fn provider ->
          monitors = Application.get_env(:shoestring, :capacity_monitors, [])
          config = if is_list(monitors), do: Keyword.get(monitors, provider, []), else: []
          enabled = is_list(config) and Keyword.get(config, :enabled) == true
          {Atom.to_string(provider), enabled}
        end)
    }
  end

  defp cap(value) when is_integer(value) and value >= 0 and value <= 1_000_000_000_000, do: value
  defp cap(_), do: 0

  defp sqlite_version do
    case Shoestring.Repo.query("SELECT sqlite_version()", [], log: false) do
      {:ok, %{rows: [[version]]}} -> version
      _ -> nil
    end
  end

  defp state_directory do
    case File.stat(Shoestring.State.root()) do
      {:ok, %{type: :directory, access: :read_write}} -> "read_write"
      {:ok, %{type: :directory}} -> "not_writable"
      _ -> "unavailable"
    end
  end

  defp os do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, :linux} -> "linux"
      _ -> "unknown"
    end
  end

  defp architecture do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      String.starts_with?(arch, "aarch64") -> "arm64"
      String.starts_with?(arch, "x86_64") -> "x86_64"
      true -> "unknown"
    end
  end
end
