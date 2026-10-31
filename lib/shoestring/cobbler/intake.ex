defmodule Shoestring.Cobbler.Intake do
  @moduledoc """
  Deterministic inputs for `shoestring do`: repository facts, acceptance gates,
  the goal contract and a bounded repository map for the planner.

  Only read-only `git` commands run (`rev-parse`, `status`, `ls-files`). The
  base revision is the repository's `HEAD`, and by default a dirty working
  tree is refused: uncommitted changes would not be in the approved base.
  `repository/2` can instead let untracked files, or every uncommitted path,
  through; they are then listed in the facts as left out of the base. Gates come
  from explicit flags or detection over tracked files; a model never chooses
  them. The repository map lists tracked paths only, never file contents.
  """

  alias Shoestring.Cobbler.{PlanContract, PlanGate}
  alias Shoestring.Harness.Security

  @max_python_tests 16
  @max_map_paths 400
  @max_map_bytes 12_288
  @python_test ~r/\Atest\/(?:[A-Za-z_][A-Za-z0-9_]*\/)*test_[A-Za-z0-9_]+\.py\z/
  @elixir_test ~r/\Atest\/[A-Za-z0-9_][A-Za-z0-9_.\/-]{0,180}_test\.exs\z/
  @parameterless_gates ~w(mix_test mix_precommit mix_format_check mix_compile_strict)

  @default_constraints [
    "Change only what the request needs; leave unrelated files unchanged.",
    "Do not edit or delete existing tests unless the request asks for it."
  ]
  @default_non_goals ["Unrelated refactoring, dependency upgrades or formatting changes."]

  @type facts :: %{
          root: Path.t(),
          head: String.t(),
          tracked: [String.t()],
          uncommitted: [String.t()]
        }

  @doc """
  Reads a repository's root, `HEAD` commit and tracked paths, and the
  uncommitted paths (`uncommitted`, `git status` order) that are not in
  `HEAD`. `:uncommitted` decides which are allowed: `:refuse` (the default)
  none, `:untracked` untracked files only, `:allow` any.
  """
  @spec repository(Path.t(), keyword()) :: {:ok, facts()} | {:error, term()}
  def repository(path, opts \\ []) do
    with true <- File.dir?(path) || {:error, :not_a_directory},
         {:ok, root} <- git(path, ["rev-parse", "--show-toplevel"], :not_a_git_repository),
         root = String.trim(root),
         {:ok, head} <-
           git(root, ["rev-parse", "--quiet", "--verify", "HEAD^{commit}"], :no_commits),
         {:ok, status} <-
           git(root, ["status", "--porcelain=v1", "--untracked-files=normal"], :git_failed),
         uncommitted = uncommitted(status),
         :ok <- allowed(uncommitted, Keyword.get(opts, :uncommitted, :refuse)),
         {:ok, listing} <- git(root, ["ls-files", "-z"], :git_failed) do
      tracked = listing |> String.split(<<0>>, trim: true) |> Enum.sort()

      {:ok,
       %{
         root: root,
         head: String.trim(head),
         tracked: tracked,
         uncommitted: Enum.map(uncommitted, &elem(&1, 1))
       }}
    end
  end

  @doc """
  Chooses the acceptance gates. Explicit `:gates` (parameterless gate names) and
  `:tests` (tracked test files) win; otherwise a Mix project gets `mix_test` and
  a Python project with 1 to #{@max_python_tests} `test/**/test_*.py` files gets
  `python_unittest` over them.
  """
  @spec gates(facts(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def gates(%{tracked: tracked}, opts \\ []) do
    names = Keyword.get(opts, :gates, [])
    tests = Keyword.get(opts, :tests, [])

    gates =
      if names == [] and tests == [],
        do: detect(tracked),
        else: explicit(names, tests, tracked)

    with {:ok, gates} <- gates, do: validate_gates(gates)
  end

  @doc "Builds and validates the goal contract for a request at the facts' `HEAD`."
  @spec goal_contract(String.t(), facts(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def goal_contract(request, %{head: head}, gates, opts \\ []) when is_binary(request) do
    request = String.trim(request)

    if request == "" do
      {:error, :empty_request}
    else
      PlanContract.validate_goal(%{
        "statement" => request,
        "repository" => %{"base_revision" => head},
        "constraints" => @default_constraints ++ Keyword.get(opts, :constraints, []),
        "non_goals" => @default_non_goals,
        "acceptance" => %{
          "gates" => gates,
          "evidence" => ["Every named gate passes at the final commit."]
        }
      })
    end
  end

  @doc """
  The planner's view of the repository: sorted tracked paths, at most
  #{@max_map_paths} entries and #{@max_map_bytes} bytes. `complete` says whether
  every path is listed. Paths the secret scanner would flag are left out and
  counted in `omitted_paths`.
  """
  @spec repository_map(facts()) :: map()
  def repository_map(%{tracked: tracked}) do
    {safe, unsafe} = Enum.split_with(tracked, &(Security.scan_term(&1) == []))

    {listed, _bytes} =
      Enum.reduce_while(safe, {[], 0}, fn path, {acc, bytes} ->
        size = byte_size(path) + 4

        if length(acc) < @max_map_paths and bytes + size <= @max_map_bytes,
          do: {:cont, {[path | acc], bytes + size}},
          else: {:halt, {acc, bytes}}
      end)

    listed = Enum.reverse(listed)

    %{
      "paths" => listed,
      "total_paths" => length(tracked),
      "omitted_paths" => length(unsafe),
      "complete" => length(listed) == length(tracked)
    }
  end

  # `{untracked?, path}` for each line of `git status --porcelain=v1`.
  defp uncommitted(status) do
    for line <- String.split(status, "\n", trim: true),
        do: {String.starts_with?(line, "??"), String.slice(line, 3..-1//1)}
  end

  defp allowed(_uncommitted, :allow), do: :ok

  defp allowed(uncommitted, mode) do
    case Enum.reject(uncommitted, fn {untracked?, _path} -> untracked? and mode == :untracked end) do
      [] -> :ok
      refused -> {:error, {:dirty_worktree, refused |> Enum.map(&elem(&1, 1)) |> Enum.take(5)}}
    end
  end

  defp detect(tracked) do
    python = Enum.filter(tracked, &Regex.match?(@python_test, &1))

    cond do
      "mix.exs" in tracked ->
        {:ok, [%{"gate" => "mix_test"}]}

      length(python) in 1..@max_python_tests ->
        {:ok, [%{"gate" => "python_unittest", "test_paths" => python}]}

      python != [] ->
        {:error, {:too_many_python_tests, length(python)}}

      true ->
        {:error, :no_gate_detected}
    end
  end

  defp explicit(names, tests, tracked) do
    with :ok <- known_names(names),
         :ok <- tracked_tests(tests, tracked) do
      python = Enum.filter(tests, &Regex.match?(@python_test, &1))
      elixir = Enum.filter(tests, &Regex.match?(@elixir_test, &1))

      cond do
        length(python) + length(elixir) != length(tests) ->
          {:error, {:unsupported_test_path, hd(tests -- (python ++ elixir))}}

        elixir != [] and "mix_test" in names ->
          {:error, :mix_test_given_twice}

        true ->
          {:ok,
           Enum.map(Enum.uniq(names), &%{"gate" => &1}) ++
             if(elixir == [], do: [], else: [%{"gate" => "mix_test", "test_paths" => elixir}]) ++
             if(python == [],
               do: [],
               else: [%{"gate" => "python_unittest", "test_paths" => python}]
             )}
      end
    end
  end

  # A project gate must be configured when the goal is recorded; it is
  # resolved again when it runs.
  defp known_names(names) do
    configured = PlanGate.configured()

    case Enum.reject(names, &(&1 in @parameterless_gates or Map.has_key?(configured, &1))) do
      [] -> :ok
      [name | _] -> {:error, {:unknown_gate, name}}
    end
  end

  defp tracked_tests(tests, tracked) do
    case Enum.reject(tests, &(&1 in tracked)) do
      [] -> :ok
      [path | _] -> {:error, {:untracked_test_path, path}}
    end
  end

  defp validate_gates(gates) do
    Enum.reduce_while(gates, {:ok, []}, fn gate, {:ok, acc} ->
      case PlanGate.validate(gate, :acceptance_gates) do
        {:ok, gate} -> {:cont, {:ok, acc ++ [gate]}}
        {:error, _changeset} -> {:halt, {:error, {:invalid_gate, gate["gate"]}}}
      end
    end)
  end

  # stderr is not captured: a Git warning must never be parsed as output.
  defp git(dir, args, error) do
    case System.cmd("git", ["-C", dir | args]) do
      {output, 0} -> {:ok, output}
      _ -> {:error, error}
    end
  rescue
    ErlangError -> {:error, :git_unavailable}
  end
end
