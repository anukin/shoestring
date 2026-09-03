defmodule Shoestring.Harness.Capacity.CommandRunnerTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.Capacity
  alias Shoestring.Harness.Capacity.CommandRunner

  defmodule FakeRunner do
    @behaviour CommandRunner

    @impl true
    def find_executable("codex"), do: "/fake/bin/codex"
    def find_executable("claude"), do: "/fake/bin/claude"
    def find_executable(_other), do: nil

    @impl true
    def cmd("/fake/bin/codex", ["--version"], _opts) do
      {"codex-cli 0.150.1\n", 0}
    end

    def cmd("/fake/bin/claude", ["--version"], _opts) do
      {"2.1.251 (Claude Code)\n", 0}
    end

    def cmd(_path, _args, _opts) do
      {"command not found", 127}
    end
  end

  defmodule MissingRunner do
    @behaviour CommandRunner

    @impl true
    def find_executable(_), do: nil

    @impl true
    def cmd(_, _, _), do: {"", 127}
  end

  defmodule FailingRunner do
    @behaviour CommandRunner

    @impl true
    def find_executable("codex"), do: "/fake/bin/codex"
    def find_executable(_), do: nil

    @impl true
    def cmd("/fake/bin/codex", ["--version"], _opts) do
      {"Segmentation fault (core dumped)\n", 139}
    end
  end

  describe "discover_version/2 with injected module runner" do
    test "successfully discovers and normalizes Codex version" do
      assert {:ok, result} = Capacity.discover_version(:codex, runner: FakeRunner)
      assert result.raw == "codex-cli 0.150.1"
      assert result.version == "0.150.1"
    end

    test "successfully discovers and normalizes Claude version" do
      assert {:ok, result} = Capacity.discover_version(:claude, runner: FakeRunner)
      assert result.raw == "2.1.251 (Claude Code)"
      assert result.version == "2.1.251"
    end

    test "returns {:error, :not_found} when executable is not on path" do
      assert {:error, :not_found} = Capacity.discover_version(:codex, runner: MissingRunner)
      assert {:error, :not_found} = Capacity.discover_version(:claude, runner: MissingRunner)
    end

    test "returns bounded error when command exits non-zero" do
      assert {:error, {:command_failed, 139, snippet}} =
               Capacity.discover_version(:codex, runner: FailingRunner)

      assert snippet =~ "Segmentation fault"
    end
  end

  describe "discover_version/2 with function and map runners" do
    test "supports 3-arity function runner" do
      runner = fn cmd, ["--version"], _opts ->
        case cmd do
          "codex" -> {"codex-cli 0.150.1\n", 0}
          "claude" -> {"2.1.251 (Claude Code)\n", 0}
        end
      end

      assert {:ok, %{version: "0.150.1"}} = Capacity.discover_version(:codex, runner: runner)
      assert {:ok, %{version: "2.1.251"}} = Capacity.discover_version(:claude, runner: runner)
    end

    test "supports 2-arity function runner" do
      runner = fn
        "codex", ["--version"] -> {"0.150.1\n", 0}
        "claude", ["--version"] -> {"2.1.251\n", 0}
      end

      assert {:ok, %{version: "0.150.1"}} = Capacity.discover_version(:codex, runner: runner)
      assert {:ok, %{version: "2.1.251"}} = Capacity.discover_version(:claude, runner: runner)
    end

    test "supports map runner" do
      runner = %{
        "codex" => {"codex-cli 0.150.1\n", 0},
        "claude" => "2.1.251 (Claude Code)\n"
      }

      assert {:ok, %{version: "0.150.1"}} = Capacity.discover_version(:codex, runner: runner)
      assert {:ok, %{version: "2.1.251"}} = Capacity.discover_version(:claude, runner: runner)
      assert {:error, :not_found} = Capacity.discover_version(:codex, runner: %{})
    end
  end

  describe "unsupported provider handling" do
    test "rejects unknown provider before attempting command execution" do
      assert {:error, :unsupported_provider} =
               Capacity.discover_version(:unsupported, runner: FakeRunner)
    end
  end
end
