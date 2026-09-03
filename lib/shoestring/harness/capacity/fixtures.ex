defmodule Shoestring.Harness.Capacity.Fixtures do
  @moduledoc """
  Utilities for managing, loading, and secret-scanning tracked capacity fixtures.
  """

  alias Shoestring.Harness.Security

  @doc "Returns the absolute path to the tracked capacity fixture directory."
  @spec fixture_root() :: String.t()
  def fixture_root do
    Application.get_env(:shoestring, :capacity_fixture_root) || default_fixture_root()
  end

  @doc "Returns the default project-relative fixture directory path."
  @spec default_fixture_root() :: String.t()
  def default_fixture_root do
    case File.cwd() do
      {:ok, cwd} ->
        candidate = Path.join([cwd, "test", "fixtures", "capacity"])

        if File.dir?(candidate),
          do: candidate,
          else: Path.expand("../../../../test/fixtures/capacity", __DIR__)

      _ ->
        Path.expand("../../../../test/fixtures/capacity", __DIR__)
    end
  end

  @doc "Lists all tracked capacity fixture relative paths sorted."
  @spec list_fixtures(String.t()) :: [String.t()]
  def list_fixtures(root \\ fixture_root()) do
    root
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  @doc "Loads and decodes a fixture by relative path (e.g. 'codex/normal-read.json')."
  @spec load_fixture(String.t()) :: {:ok, map()} | {:error, term()}
  def load_fixture(rel_path) do
    path = Path.join(fixture_root(), rel_path)

    with {:ok, binary} <- File.read(path),
         {:ok, decoded} <- Jason.decode(binary) do
      {:ok, decoded}
    end
  end

  @doc "Loads and decodes a fixture by relative path, raising on error."
  @spec load_fixture!(String.t()) :: map()
  def load_fixture!(rel_path) do
    case load_fixture(rel_path) do
      {:ok, decoded} -> decoded
      {:error, reason} -> raise "Failed to load fixture #{rel_path}: #{inspect(reason)}"
    end
  end

  @doc "Scans a binary or term recursively for forbidden secrets, paths, and keys."
  @spec scan_term(term()) :: [String.t()]
  def scan_term(term) do
    Security.scan_term(term)
  end

  @doc "Scans all tracked fixtures on disk for secret patterns and forbidden keys."
  @spec scan_all_fixtures(String.t()) ::
          {:ok, pos_integer()} | {:error, :no_fixtures_found | [{String.t(), [String.t()]}]}
  def scan_all_fixtures(root \\ fixture_root()) do
    fixtures = list_fixtures(root)

    if fixtures == [] do
      {:error, :no_fixtures_found}
    else
      violations =
        Enum.flat_map(fixtures, fn rel_path ->
          path = Path.join(root, rel_path)
          raw_content = File.read!(path)
          issues = Security.scan_json(raw_content)

          if issues != [] do
            [{rel_path, issues}]
          else
            []
          end
        end)

      if violations == [] do
        {:ok, length(fixtures)}
      else
        {:error, violations}
      end
    end
  end
end
