defmodule Shoestring.Cobbler.ScopeEvidence do
  @moduledoc "Bounded, NUL-delimited Git observations for scope policy; no provider or source writes."
  alias Shoestring.Cobbler.{GateProcess, PlanIndependence}
  @timeout 5_000
  @max_bytes 1_048_576

  def repository(path, accepted_base) do
    with true <-
           is_binary(path) and is_binary(accepted_base) and
             Regex.match?(~r/\A[0-9a-f]{40,64}\z/, accepted_base),
         {:ok, head} <- git(path, ["rev-parse", "--verify", "HEAD"]),
         true <- String.trim(head) == accepted_base,
         {:ok, status} <-
           git(path, ["status", "--porcelain=v1", "-z", "--untracked-files=normal"]),
         true <- status == "",
         {:ok, tree} <- git(path, ["ls-tree", "-r", "-z", "--full-tree", accepted_base]),
         {:ok, entries} <- tree_entries(tree) do
      {:ok,
       %{
         verified?: true,
         base: accepted_base,
         files: Enum.map(entries, &elem(&1, 1)),
         symlinks: for({"120000", file} <- entries, do: file)
       }}
    else
      false -> {:error, :repository_base_or_state_changed}
      error -> error
    end
  end

  def changes(path, base) do
    with true <- is_binary(base) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/, base),
         {:ok, changed} <- git(path, ["diff", "--no-renames", "--name-only", "-z", base, "--"]),
         {:ok, untracked} <- git(path, ["ls-files", "--others", "--exclude-standard", "-z"]),
         paths = String.split(changed <> untracked, "\0", trim: true),
         true <- length(paths) <= 1024 and Enum.all?(paths, &PlanIndependence.valid_path?/1),
         true <-
           Enum.all?(paths, fn file ->
             case File.lstat(Path.join(path, file)) do
               {:ok, %{type: :symlink}} -> false
               {:ok, _} -> true
               {:error, :enoent} -> true
               _ -> false
             end
           end) do
      {:ok, Enum.sort(Enum.uniq(paths))}
    else
      false -> {:error, :changed_scope_invalid_or_oversized}
      error -> error
    end
  end

  @doc "Observes a clean, pinned final commit, including deletions and both sides of renames."
  def final_changes(path, base, commit) do
    with true <- is_binary(base) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/, base),
         {:ok, metadata} <- repository(path, commit),
         {:ok, changed} <-
           git(path, ["diff", "--no-renames", "--name-only", "-z", base, commit, "--"]),
         paths = String.split(changed, "\0", trim: true),
         true <- length(paths) <= 1024 and Enum.all?(paths, &PlanIndependence.valid_path?/1),
         true <- Enum.all?(paths, &(&1 not in metadata.symlinks)),
         {:ok, _} <- repository(path, commit) do
      {:ok, Enum.sort(Enum.uniq(paths))}
    else
      false -> {:error, :changed_scope_invalid_or_oversized}
      error -> error
    end
  end

  defp tree_entries(output) do
    entries = String.split(output, "\0", trim: true)

    if length(entries) <= 20_000 do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        case String.split(entry, "\t", parts: 2) do
          [header, path] ->
            case String.split(header, " ") do
              [mode, _type, _object] when mode in ["100644", "100755", "120000"] ->
                if PlanIndependence.valid_path?(path),
                  do: {:cont, {:ok, [{mode, path} | acc]}},
                  else: {:halt, {:error, :repository_scope_invalid}}

              _ ->
                {:halt, {:error, :repository_scope_unsupported}}
            end

          _ ->
            {:halt, {:error, :repository_scope_invalid}}
        end
      end)
    else
      {:error, :repository_scope_oversized}
    end
  end

  defp git(path, argv) do
    case GateProcess.run(["git" | argv], path, @timeout, @max_bytes) do
      {:ok, %{exit_status: 0, output: output}} -> {:ok, output}
      _ -> {:error, :repository_scope_unavailable}
    end
  end
end
