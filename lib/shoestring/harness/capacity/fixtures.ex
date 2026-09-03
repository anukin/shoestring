defmodule Shoestring.Harness.Capacity.Fixtures do
  @moduledoc """
  Utilities for managing, loading, and secret-scanning tracked capacity fixtures.
  """

  @fixture_root Path.expand("../../../../test/fixtures/capacity", __DIR__)

  @forbidden_patterns [
    ~r/\bsk-[A-Za-z0-9_-]{12,}/,
    ~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i,
    ~r/\b(?:api[_-]?key|access[_-]?token|password)\s*[:=]/i,
    ~r/\/Users\/[A-Za-z0-9_.-]+/,
    ~r/\/home\/[A-Za-z0-9_.-]+/
  ]

  @forbidden_keys ~w(
    raw_transcript raw_output stdout stderr prompt_messages messages
    model_response response_text completion_text session_id threadId turnId codexHome
  )

  @doc "Returns the absolute path to the tracked capacity fixture directory."
  @spec fixture_root() :: String.t()
  def fixture_root, do: @fixture_root

  @doc "Lists all tracked capacity fixture relative paths sorted."
  @spec list_fixtures() :: [String.t()]
  def list_fixtures do
    @fixture_root
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @fixture_root))
    |> Enum.sort()
  end

  @doc "Loads and decodes a fixture by relative path (e.g. 'codex/normal-read.json')."
  @spec load_fixture(String.t()) :: {:ok, map()} | {:error, term()}
  def load_fixture(rel_path) do
    path = Path.join(@fixture_root, rel_path)

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
    scan_term(term, "")
  end

  defp scan_term(str, path) when is_binary(str) do
    Enum.flat_map(@forbidden_patterns, fn regex ->
      if Regex.match?(regex, str) do
        [
          "Matched forbidden pattern #{inspect(regex)} at #{path}: #{inspect(String.slice(str, 0, 50))}"
        ]
      else
        []
      end
    end)
  end

  defp scan_term(map, path) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      key_str = to_string(k)
      current_path = if path == "", do: key_str, else: "#{path}.#{key_str}"

      key_violations =
        if key_str in @forbidden_keys do
          ["Found forbidden key #{inspect(key_str)} at #{current_path}"]
        else
          []
        end

      key_violations ++ scan_term(v, current_path)
    end)
  end

  defp scan_term(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {elem, idx} ->
      scan_term(elem, "#{path}[#{idx}]")
    end)
  end

  defp scan_term(_other, _path), do: []

  @doc "Scans all tracked fixtures on disk for secret patterns and forbidden keys."
  @spec scan_all_fixtures() :: {:ok, non_neg_integer()} | {:error, [{String.t(), [String.t()]}]}
  def scan_all_fixtures do
    fixtures = list_fixtures()

    violations =
      Enum.flat_map(fixtures, fn rel_path ->
        path = Path.join(@fixture_root, rel_path)
        raw_content = File.read!(path)

        text_violations =
          Enum.flat_map(@forbidden_patterns, fn regex ->
            if Regex.match?(regex, raw_content) do
              ["Raw text matched #{inspect(regex)}"]
            else
              []
            end
          end)

        term_violations =
          case Jason.decode(raw_content) do
            {:ok, decoded} -> scan_term(decoded)
            _ -> ["Invalid JSON"]
          end

        all = text_violations ++ term_violations

        if all != [] do
          [{rel_path, all}]
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
