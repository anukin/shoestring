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

    test "supports 1-arity function runner" do
      runner = fn
        "codex" -> {"codex-cli 0.150.1\n", 0}
        "claude" -> {"2.1.251\n", 0}
      end

      assert {:ok, %{version: "0.150.1"}} = Capacity.discover_version(:codex, runner: runner)
      assert {:ok, %{version: "2.1.251"}} = Capacity.discover_version(:claude, runner: runner)
    end
  end

  describe "failure redaction and diagnostic bounds (B4)" do
    defmodule CredentialLeakingRunner do
      @behaviour CommandRunner

      @impl true
      def find_executable(_), do: "/fake/bin/codex"

      @impl true
      def cmd(_path, _args, _opts) do
        leaking_output = """
        error: authentication failed using api_key: sk-1234567890abcdef123456
        Authorization: Bearer secret-bearer-token-123456
        password=super_secret_password_here
        failed to read config at /Users/developer_alice/.config/codex.json
        failed to read cache at /home/developer_bob/.cache/codex
        """

        {leaking_output, 1}
      end
    end

    test "redacts credentials and user paths from CLI failure snippet" do
      assert {:error, {:command_failed, 1, snippet}} =
               Capacity.discover_version(:codex, runner: CredentialLeakingRunner)

      refute snippet =~ "sk-1234567890abcdef123456"
      refute snippet =~ "secret-bearer-token-123456"
      refute snippet =~ "super_secret_password_here"
      refute snippet =~ "/Users/developer_alice"
      refute snippet =~ "/home/developer_bob"

      assert snippet =~ "Bearer [REDACTED]"
      assert snippet =~ "/Users/[REDACTED]"
      assert snippet =~ "/home/"
      assert snippet =~ "[REDACTED]"
      assert String.length(snippet) <= 200
    end
  end

  describe "execution timeout and malformed runner resilience" do
    defmodule RaisingRunner do
      @behaviour CommandRunner
      @impl true
      def find_executable(_), do: "/fake/bin/codex"
      @impl true
      def cmd(_path, _args, _opts), do: raise("unexpected crash inside runner")
    end

    test "bounded execution timeout returns {:error, :timeout} without Process.sleep" do
      hanging_runner = fn _cmd ->
        receive do
          :never_received -> :ok
        end
      end

      assert {:error, :timeout} =
               Capacity.discover_version(:codex, runner: hanging_runner, timeout: 50)
    end

    test "handles malformed runner modules gracefully" do
      # Module not implementing CommandRunner
      assert {:error, :invalid_runner} =
               Capacity.discover_version(:codex, runner: String)

      # Module raising an exception
      assert {:error, :invalid_runner} =
               Capacity.discover_version(:codex, runner: RaisingRunner)
    end

    test "handles malformed runner functions gracefully" do
      # Function returning nil instead of {output, status}
      nil_runner = fn _cmd, _args -> nil end
      assert {:error, :invalid_runner} = Capacity.discover_version(:codex, runner: nil_runner)

      # Function returning atom
      atom_runner = fn _cmd -> :ok end
      assert {:error, :invalid_runner} = Capacity.discover_version(:codex, runner: atom_runner)

      # Function returning invalid tuple types
      bad_tuple_runner = fn _cmd -> {"out", "not_int"} end

      assert {:error, :invalid_runner} =
               Capacity.discover_version(:codex, runner: bad_tuple_runner)

      # Function raising an exception
      crash_runner = fn _cmd -> raise "runtime crash" end
      assert {:error, :invalid_runner} = Capacity.discover_version(:codex, runner: crash_runner)
    end

    test "handles malformed runner maps gracefully" do
      bad_map = %{"codex" => 12345}
      assert {:error, :invalid_runner} = Capacity.discover_version(:codex, runner: bad_map)
    end

    test "handles non-runner types gracefully" do
      assert {:error, :invalid_runner} = Capacity.discover_version(:codex, runner: 99_999)
      assert {:error, :invalid_runner} = Capacity.discover_version(:codex, runner: [:a, :b])
    end
  end

  describe "unsupported provider handling" do
    test "rejects unknown provider before attempting command execution" do
      assert {:error, :unsupported_provider} =
               Capacity.discover_version(:unsupported, runner: FakeRunner)
    end
  end
end
