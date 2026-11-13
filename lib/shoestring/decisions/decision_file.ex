defmodule Shoestring.Decisions.DecisionFile do
  @moduledoc """
  Reads and validates the decision file a plan task wrote in its worktree
  (`.shoestring/decisions/<id>/decision.json`, see
  `Shoestring.Cobbler.PlanContract.decision_file/1`).

  The file names the candidates; Shoestring never learns what they mean:

      {"id": "cover",
       "question": "Which cover?",            (optional; else the plan's)
       "note": "Three takes on the brief.",   (optional)
       "options": [
         {"key": "a", "label": "Warm", "file": ".shoestring/decisions/cover/a.png",
          "media_type": "image/png"},
         {"key": "b", "label": "Cut", "file": ".shoestring/decisions/cover/b-poster.png",
          "media_type": "image/png", "source": "renders/b.mp4"}
       ]}

  Every path is worktree-relative, without `..`, and no component may be a
  symlink. `file` is stored as an artifact, so it must fit the artifact cap;
  `source` (optional, any size, never stored) names the full candidate when
  `file` is only its poster or thumbnail. Option keys are slugs, unique, and
  never `reject` (reserved for "none of these").

  A file that breaks any rule is refused with a reason a person can act on;
  the executor records it as the task's gate failure. Nothing is truncated
  or coerced.
  """

  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Trajectory.ArtifactStore

  @max_file_bytes 65_536
  @max_options 12
  @max_question 2_000
  @max_note 2_000
  @max_label 200
  @max_path 300
  @file_keys ~w(id question note options)
  @option_keys ~w(key label file media_type source)
  @key_pattern ~r/\A[a-z0-9][a-z0-9_-]{0,62}\z/
  @media_type_pattern ~r/\A[a-z0-9][a-z0-9!#$&^_.+-]{0,62}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,62}\z/

  @type option :: %{required(String.t()) => String.t()}
  @type t :: %{question: String.t(), note: String.t() | nil, options: [option()]}

  @doc """
  Reads the decision `decision` (the plan task's normalized `decision` map)
  from `worktree`. Returns `{:ok, %{question, note, options}}`, each option
  with `"key"`, `"label"`, `"file"`, `"media_type"`, and `"source"` when
  given, or `{:error, reason}` with a bounded human-readable reason.
  """
  @spec read(Path.t(), map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def read(worktree, decision, opts \\ []) when is_binary(worktree) and is_map(decision) do
    relative = PlanContract.decision_file(decision["id"])

    with {:ok, bytes} <- read_file(worktree, relative, @max_file_bytes),
         {:ok, map} <- decode(bytes),
         :ok <- keys(map, @file_keys, "the decision file"),
         :ok <- same_id(map, decision),
         {:ok, question} <- optional_text(map, "question", @max_question, decision["question"]),
         {:ok, note} <- optional_text(map, "note", @max_note, nil),
         {:ok, options} <- options(map, decision, worktree, opts) do
      {:ok, %{question: question, note: note, options: options}}
    end
  end

  @doc "Reads one validated worktree-relative file, refusing symlinks and oversize."
  @spec read_file(Path.t(), String.t(), non_neg_integer()) ::
          {:ok, binary()} | {:error, String.t()}
  def read_file(worktree, relative, max_bytes) do
    with :ok <- safe_relative(relative),
         {:ok, %{size: size}} <- regular_file(worktree, relative) do
      cond do
        size > max_bytes ->
          {:error, "#{relative} is #{size} bytes, over the #{max_bytes}-byte limit"}

        true ->
          case File.read(Path.join(worktree, relative)) do
            {:ok, bytes} when byte_size(bytes) <= max_bytes -> {:ok, bytes}
            {:ok, _bytes} -> {:error, "#{relative} grew past the #{max_bytes}-byte limit"}
            {:error, reason} -> {:error, "#{relative} could not be read (#{reason})"}
          end
      end
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, "the decision file must be a JSON object"}
      {:error, _} -> {:error, "the decision file is not valid JSON"}
    end
  end

  defp keys(map, allowed, what) do
    case Map.keys(map) -- allowed do
      [] ->
        :ok

      extra ->
        {:error, "#{what} has unsupported fields: #{extra |> Enum.sort() |> Enum.join(", ")}"}
    end
  end

  defp same_id(%{"id" => id}, %{"id" => id}), do: :ok

  defp same_id(_map, decision),
    do: {:error, "the decision file must have \"id\": \"#{decision["id"]}\""}

  defp optional_text(map, field, max, default) do
    case Map.fetch(map, field) do
      :error ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" -> {:error, "#{field} must not be empty"}
          String.length(value) > max -> {:error, "#{field} is longer than #{max} characters"}
          not String.printable?(value) -> {:error, "#{field} must be printable text"}
          true -> {:ok, value}
        end

      {:ok, _value} ->
        {:error, "#{field} must be text"}
    end
  end

  defp options(%{"options" => options}, decision, worktree, opts) when is_list(options) do
    min = decision["min_options"]
    max = min(decision["max_options"], @max_options)

    cond do
      length(options) < min ->
        {:error, "the decision needs at least #{min} options, the file gives #{length(options)}"}

      length(options) > max ->
        {:error, "the decision allows at most #{max} options, the file gives #{length(options)}"}

      true ->
        options
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {option, n}, {:ok, acc} ->
          case option(option, worktree, opts) do
            {:ok, option} -> {:cont, {:ok, [option | acc]}}
            {:error, reason} -> {:halt, {:error, "option #{n}: #{reason}"}}
          end
        end)
        |> case do
          {:ok, list} -> unique_keys(Enum.reverse(list))
          error -> error
        end
    end
  end

  defp options(_map, _decision, _worktree, _opts),
    do: {:error, "the decision file must list its options"}

  defp option(option, worktree, opts) when is_map(option) do
    max_size = ArtifactStore.max_size(opts)

    with :ok <- keys(option, @option_keys, "it"),
         {:ok, key} <- key(option["key"]),
         {:ok, label} <- required_text(option, "label", @max_label),
         {:ok, media_type} <- media_type(option["media_type"]),
         {:ok, file} <- path(option, "file"),
         {:ok, %{size: size}} <- regular_file(worktree, file),
         :ok <- fits(file, size, max_size),
         {:ok, source} <- optional_source(option, worktree) do
      {:ok,
       %{"key" => key, "label" => label, "media_type" => media_type, "file" => file}
       |> then(&if(source, do: Map.put(&1, "source", source), else: &1))}
    end
  end

  defp option(_option, _worktree, _opts), do: {:error, "must be an object"}

  defp key("reject"), do: {:error, "key \"reject\" is reserved for \"none of these\""}

  defp key(key) when is_binary(key) do
    if Regex.match?(@key_pattern, key),
      do: {:ok, key},
      else: {:error, "key must be a lowercase slug of letters, digits, _ and -"}
  end

  defp key(_key), do: {:error, "key must be text"}

  defp required_text(map, field, max) do
    case optional_text(map, field, max, nil) do
      {:ok, nil} -> {:error, "#{field} is required"}
      other -> other
    end
  end

  defp media_type(value) when is_binary(value) do
    if Regex.match?(@media_type_pattern, value),
      do: {:ok, value},
      else: {:error, "media_type must look like type/subtype, in lowercase"}
  end

  defp media_type(_value), do: {:error, "media_type is required"}

  defp path(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) ->
        with :ok <- safe_relative(value), do: {:ok, value}

      {:ok, _value} ->
        {:error, "#{field} must be a path"}

      :error ->
        {:error, "#{field} is required"}
    end
  end

  defp fits(_file, size, max) when size <= max, do: :ok

  defp fits(file, size, max),
    do:
      {:error,
       "#{file} is #{size} bytes, over the #{max}-byte artifact limit; give a smaller " <>
         "poster or thumbnail as file and the full candidate as source"}

  defp optional_source(%{"source" => _} = option, worktree) do
    with {:ok, source} <- path(option, "source"),
         {:ok, _stat} <- regular_file(worktree, source),
         do: {:ok, source}
  end

  defp optional_source(_option, _worktree), do: {:ok, nil}

  defp unique_keys(options) do
    keys = Enum.map(options, & &1["key"])

    if length(keys) == length(Enum.uniq(keys)),
      do: {:ok, options},
      else: {:error, "option keys must be unique"}
  end

  # Worktree-relative, no `..`, no `.` or empty components, printable.
  defp safe_relative(path) do
    parts = String.split(path, "/")

    cond do
      byte_size(path) > @max_path ->
        {:error, "a path is longer than #{@max_path} bytes"}

      not String.printable?(path) or String.contains?(path, ["\\", <<0>>]) ->
        {:error, "#{inspect(path)} is not a plain path"}

      Path.type(path) != :relative ->
        {:error, "#{path} must be relative to the worktree"}

      Enum.any?(parts, &(&1 in ["", ".", ".."])) ->
        {:error, "#{path} must not contain empty, . or .. parts"}

      true ->
        :ok
    end
  end

  # Every component is checked with lstat: a symlink anywhere on the path,
  # including a linked directory, is refused, so a candidate can never point
  # outside the worktree.
  defp regular_file(worktree, relative) do
    parts = String.split(relative, "/")
    {dirs, [_name]} = Enum.split(parts, -1)

    dirs
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case File.lstat(Path.join(worktree, dir)) do
        {:ok, %{type: :directory}} -> {:cont, :ok}
        {:ok, %{type: :symlink}} -> {:halt, {:error, "#{dir} is a symlink"}}
        {:ok, _} -> {:halt, {:error, "#{dir} is not a directory"}}
        {:error, _} -> {:halt, {:error, "#{relative} does not exist"}}
      end
    end)
    |> case do
      :ok ->
        case File.lstat(Path.join(worktree, relative)) do
          {:ok, %{type: :regular} = stat} -> {:ok, stat}
          {:ok, %{type: :symlink}} -> {:error, "#{relative} is a symlink"}
          {:ok, _} -> {:error, "#{relative} is not a regular file"}
          {:error, _} -> {:error, "#{relative} does not exist"}
        end

      error ->
        error
    end
  end
end
