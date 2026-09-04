defmodule Shoestring.Test.CapacityLiveSmoke do
  @moduledoc """
  Shared helpers for opt-in live provider smoke tests (`@tag :live`).

  Live smoke tests must be low-consumption: the ONLY provider process they may
  invoke is `<cli> --version`. They never start coding sessions, send prompts,
  or consume model inference. They never read, write, or modify tracked
  fixtures in `test/fixtures/capacity/`.
  """

  alias Shoestring.Harness.Capacity.Fixtures

  @doc """
  Locates the provider CLI binary. Returns `{:ok, path}` or `:not_found`
  (callers treat `:not_found` as a skip, never a failure).
  """
  @spec find_cli(String.t()) :: {:ok, String.t()} | :not_found
  def find_cli(command) when is_binary(command) do
    case System.find_executable(command) do
      nil -> :not_found
      path -> {:ok, path}
    end
  end

  @doc """
  Runs `<cli> --version` with a bounded timeout. This is the only provider
  invocation live smoke tests are allowed to perform.
  """
  @spec version_only(String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, :not_found | :timeout | {:exit_status, integer()}}
  def version_only(command, timeout_ms \\ 5_000) do
    with {:ok, executable} <- find_cli(command) do
      task = Task.async(fn -> System.cmd(executable, ["--version"], stderr_to_stdout: true) end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} -> {:ok, String.trim(output)}
        {:ok, {_output, status}} -> {:error, {:exit_status, status}}
        nil -> {:error, :timeout}
      end
    end
  end

  @doc """
  Hashes every tracked fixture file. Used to prove a live smoke run did not
  modify deterministic fixture expectations.
  """
  @spec snapshot_fixture_hashes() :: %{String.t() => String.t()}
  def snapshot_fixture_hashes do
    Fixtures.list_fixtures()
    |> Map.new(fn rel_path ->
      content = rel_path |> then(&Path.join(Fixtures.fixture_root(), &1)) |> File.read!()
      {rel_path, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)}
    end)
  end

  @doc """
  Builds the environment/version mismatch report. A live failure reports this
  message and MUST NOT change deterministic fixture expectations.
  """
  @spec mismatch_message(atom(), String.t() | nil, [String.t()]) :: String.t()
  def mismatch_message(provider, observed_version, tested_versions) do
    """
    ENVIRONMENT/VERSION MISMATCH (live smoke, provider: #{provider}).
    Installed CLI version: #{inspect(observed_version)}.
    Tested registry versions: #{inspect(tested_versions)}.
    Fixture expectations in test/fixtures/capacity/ were NOT modified and must
    NOT be auto-updated from live output. If the drift is legitimate, follow
    the regeneration + secret-review procedure in docs/capacity-fixtures.md and
    update fixtures in a separate, reviewed change.
    """
  end
end
