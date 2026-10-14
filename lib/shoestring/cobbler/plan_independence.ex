defmodule Shoestring.Cobbler.PlanIndependence do
  @moduledoc "Versioned deterministic scope evidence. Eligibility never allocates capacity or merges work."
  @version 1
  @shared_names ~w(mix.exs mix.lock go.mod go.sum pyproject.toml poetry.lock uv.lock requirements.txt package.json package-lock.json yarn.lock pnpm-lock.yaml cargo.toml cargo.lock .formatter.exs .gitignore .gitattributes .gitmodules .tool-versions)
  @shared_dirs ~w(config priv/repo/migrations migrations .github/workflows generated)

  def version, do: @version

  def declared([], _metadata), do: invalid(:declared, "no_ready_tasks")

  def declared(tasks, _metadata) when is_list(tasks) and length(tasks) > 64,
    do: invalid(:declared, "scope_bound_exceeded")

  def declared(tasks, metadata) when is_list(tasks) and is_map(metadata) do
    scopes = Map.new(tasks, fn task -> {task["id"], get_in(task, ["hints", "files"]) || []} end)

    if length(tasks) == map_size(scopes) and Enum.all?(Map.keys(scopes), &is_binary/1) do
      decision = evaluate(scopes, metadata, :declared)

      symbols =
        for {left, index} <- Enum.with_index(tasks),
            right <- Enum.drop(tasks, index + 1),
            symbol <- get_in(left, ["hints", "symbols"]) || [],
            symbol in (get_in(right, ["hints", "symbols"]) || []),
            do: %{
              "task_ids" => Enum.sort([left["id"], right["id"]]),
              "reason" => "symbol_overlap",
              "symbol" => symbol
            }

      if symbols == [],
        do: decision,
        else: %{
          decision
          | "disposition" => "sequential",
            "blocker_count" => decision["blocker_count"] + length(symbols),
            "blockers" => Enum.take(Enum.sort(Enum.uniq(decision["blockers"] ++ symbols)), 128),
            "evidence_complete" =>
              decision["evidence_complete"] and decision["blocker_count"] + length(symbols) <= 128
        }
    else
      invalid(:declared, "invalid_task_set")
    end
  end

  def actual(changes, metadata) when is_map(changes) and is_map(metadata),
    do: evaluate(changes, metadata, :actual)

  defp evaluate(scopes, metadata, source) do
    if map_size(scopes) > 64 or Enum.any?(Map.values(scopes), &(not is_list(&1))) or
         Enum.sum(Enum.map(Map.values(scopes), &length/1)) > 4096 do
      invalid(source, "scope_bound_exceeded")
    else
      evaluate_bounded(scopes, metadata, source)
    end
  end

  defp invalid(source, reason),
    do: %{
      "version" => @version,
      "source" => to_string(source),
      "disposition" => "sequential",
      "task_ids" => [],
      "blocker_count" => 1,
      "blockers" => [%{"reason" => reason}],
      "evidence_complete" => true
    }

  defp evaluate_bounded(scopes, metadata, source) do
    ids = Map.keys(scopes) |> Enum.sort()

    known? =
      metadata[:verified?] == true and is_list(metadata[:files]) and is_list(metadata[:symlinks])

    shared = if known?, do: Enum.filter(metadata.files, &shared?/1), else: []

    blockers =
      Enum.flat_map(ids, fn id ->
        paths = scopes[id]

        cond do
          not known? ->
            [%{"task_id" => id, "reason" => "repository_metadata_unknown"}]

          not is_list(paths) or length(paths) > 1024 or Enum.any?(paths, &(not valid_path?(&1))) ->
            [%{"task_id" => id, "reason" => "invalid_or_oversized_scope"}]

          source == :declared and paths == [] ->
            [%{"task_id" => id, "reason" => "scope_unknown"}]

          true ->
            Enum.flat_map(paths, fn path ->
              cond do
                Enum.any?(metadata.symlinks, &overlap?(path, &1)) ->
                  [%{"task_id" => id, "reason" => "symlink_scope", "path" => path}]

                shared?(path) or Enum.any?(shared, &overlap?(path, &1)) ->
                  [%{"task_id" => id, "reason" => "shared_surface", "path" => path}]

                true ->
                  []
              end
            end)
        end
      end)

    overlap_blockers =
      if Enum.all?(
           Map.values(scopes),
           &(is_list(&1) and Enum.all?(&1, fn path -> valid_path?(path) end))
         ) do
        for {left, index} <- Enum.with_index(ids),
            right <- Enum.drop(ids, index + 1),
            a <- scopes[left],
            b <- scopes[right],
            overlap?(a, b),
            do: %{"task_ids" => [left, right], "reason" => "scope_overlap", "paths" => [a, b]}
      else
        []
      end

    blockers = Enum.sort(Enum.uniq(blockers ++ overlap_blockers))

    %{
      "version" => @version,
      "source" => to_string(source),
      "disposition" => if(blockers == [], do: "eligible", else: "sequential"),
      "task_ids" => ids,
      "blocker_count" => length(blockers),
      "blockers" => Enum.take(blockers, 128),
      "evidence_complete" => length(blockers) <= 128
    }
  end

  def shared?(path) when is_binary(path) do
    path = normalize(path)

    Path.basename(path) in @shared_names or Enum.any?(@shared_dirs, &overlap?(path, &1)) or
      String.ends_with?(path, ["/application.ex", "/router.ex", "/event_registry.ex"]) or
      Regex.match?(~r/(^|\/)requirements[^\/]*\.txt\z/, path) or
      Regex.match?(~r/(^|\/)(generated|migrations)(\/|$)/, path)
  end

  def valid_path?(path) when is_binary(path) do
    String.valid?(path) and byte_size(path) in 1..4096 and
      not String.starts_with?(path, ["/", "\\"]) and
      not String.contains?(path, ["\\", "\0", "\n", "\r"]) and
      Enum.all?(String.split(String.trim_trailing(path, "/"), "/"), &(&1 not in ["", ".", ".."]))
  end

  def valid_path?(_), do: false

  def overlap?(left, right) do
    left = normalize(left)
    right = normalize(right)

    left == right or String.starts_with?(left, right <> "/") or
      String.starts_with?(right, left <> "/")
  end

  defp normalize(path),
    do: path |> String.trim_trailing("/") |> String.normalize(:nfc) |> String.downcase()
end
