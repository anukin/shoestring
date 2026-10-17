defmodule Shoestring.Cobbler.PlanGate do
  @moduledoc """
  The closed registry of named, trusted acceptance gates a plan may cite.

  A plan never carries a shell string. Every acceptance gate in a goal
  contract or a task contract is a reference to a name in this registry, and
  the registry — not the plan, and never a model — owns the argv that name
  resolves to. An unknown name fails the plan closed; there is no escape
  hatch, no free-form `command` field, and no "whatever the planner said".

  A gate may accept a bounded, allow-listed parameter. `mix_test` accepts
  `test_paths`: repository-relative `test/**.exs` paths, each matched against
  a strict pattern that admits no shell metacharacter, no absolute path, and
  no parent-directory segment. The Mix formatting, compilation and precommit
  gates accept no parameters. Parameters a gate does not declare reject the plan.
  `python_unittest` requires named repository-relative `test/**/test_*.py`
  files and uses Python's standard-library unittest runner with bytecode
  writing disabled, preserving the tested Git snapshot.

  Model success is never an acceptance gate. Acceptance is what a trusted
  deterministic command reports, not what a provider claims about itself;
  that is why this registry holds only repository gates and why
  `Shoestring.Cobbler.PlanContract` requires at least one of them per task.

  Nothing here executes. `argv/1` resolves a validated reference to the argv
  a later execution package will run; this slice only records plans.

  ## Configured project gates

  The user (never a plan or a model) may approve more commands in the
  application configuration, for projects the built-in gates do not cover:

      config :shoestring, :project_gates, %{
        "npm_test" => %{argv: ["npm", "test"], kind: "test"},
        "ruff" => %{argv: ["ruff", "check", "."], kind: "lint", required: false}
      }

  A plan cites one as `%{"gate" => "project:npm_test"}`, with no parameters.
  The name is checked here by syntax only, so a plan stays valid when the
  configuration changes; the command is resolved when the gate runs, and a
  name that is not configured (or configured invalidly) makes that gate
  unavailable, never passed. `argv` is an argument array run without a shell;
  its program must be a bare name found on `PATH`, and no argument may look
  like a secret (it is recorded with every run). `kind` orders gates
  (cheap first) and `required: false` records a failure without blocking the
  task. `timeout_ms` (at most 300 000) replaces the default timeout.

  ## Specification

  `spec/2` gives the versioned specification (`Shoestring.Cobbler.GateSpec`)
  a run is recorded against: the gate, its version and source, kind and run
  order, the exact argv, working directory, environment allowlist, timeout,
  output limit, exit semantics, whether it is required, and its artifact
  policy.
  """

  alias Shoestring.Harness.Contract

  # `version` changes whenever a gate's argv or meaning changes.
  @gates %{
    "mix_precommit" => %{
      argv: ["mix", "precommit"],
      parameters: [],
      kind: "precommit",
      version: 1
    },
    "mix_test" => %{argv: ["mix", "test"], parameters: ["test_paths"], kind: "test", version: 1},
    "python_unittest" => %{
      argv: ["python3", "-B", "-m", "unittest"],
      parameters: ["test_paths"],
      kind: "test",
      version: 1
    },
    "mix_format_check" => %{
      argv: ["mix", "format", "--check-formatted"],
      parameters: [],
      kind: "format",
      version: 1
    },
    "mix_compile_strict" => %{
      argv: ["mix", "compile", "--warnings-as-errors"],
      parameters: [],
      kind: "compile",
      version: 1
    }
  }

  @project_prefix "project:"
  @project_name ~r/\Aproject:[a-z][a-z0-9_]{0,39}\z/
  @program ~r/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\z/
  @max_argv 32
  @max_arg_bytes 512
  @max_timeout_ms 300_000

  @max_test_paths 16
  @test_path_pattern ~r/\Atest\/[A-Za-z0-9_][A-Za-z0-9_.\/-]{0,180}_test\.exs\z/
  @python_test_path_pattern ~r/\Atest\/(?:[A-Za-z_][A-Za-z0-9_]*\/)*test_[A-Za-z0-9_]+\.py\z/

  @doc "The sorted list of built-in trusted gate names a plan may reference."
  @spec names() :: [String.t()]
  def names, do: @gates |> Map.keys() |> Enum.sort()

  @doc "Whether `name` is a built-in gate or a syntactically valid project gate name."
  @spec known?(term()) :: boolean()
  def known?(name) when is_binary(name), do: Map.has_key?(@gates, name) or project?(name)
  def known?(_name), do: false

  @doc "Whether `name` cites a configured project gate (`project:<name>`)."
  @spec project?(term()) :: boolean()
  def project?(name) when is_binary(name), do: Regex.match?(@project_name, name)
  def project?(_name), do: false

  @doc """
  The project gates the configuration approves, by cited name. Entries that
  are not valid are left out, and so are unavailable when cited.
  """
  @spec configured() :: %{String.t() => map()}
  def configured do
    :shoestring
    |> Application.get_env(:project_gates, %{})
    |> Enum.flat_map(fn {name, attrs} ->
      case project_spec(to_string(name), attrs) do
        {:ok, spec} -> [{@project_prefix <> to_string(name), spec}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  @doc """
  The specification facts of a validated reference: `argv` (with
  parameters), `kind`, `version`, `source`, `required` and `timeout_ms`
  (`nil` for the runner's default). A project gate that is not configured is
  `{:error, :project_gate_not_configured}`.
  """
  @spec spec(map()) :: {:ok, map()} | {:error, :project_gate_not_configured | :unknown_gate}
  def spec(%{"gate" => name} = reference) do
    cond do
      Map.has_key?(@gates, name) ->
        gate = Map.fetch!(@gates, name)

        {:ok,
         %{
           gate: name,
           argv: gate.argv ++ Map.get(reference, "test_paths", []),
           kind: gate.kind,
           version: gate.version,
           source: "builtin",
           required: true,
           timeout_ms: nil
         }}

      project?(name) ->
        case Map.fetch(configured(), name) do
          {:ok, spec} -> {:ok, Map.put(spec, :gate, name)}
          :error -> {:error, :project_gate_not_configured}
        end

      true ->
        {:error, :unknown_gate}
    end
  end

  def spec(_reference), do: {:error, :unknown_gate}

  defp project_spec(name, attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    argv = attrs["argv"]
    timeout = attrs["timeout_ms"]

    if Regex.match?(@project_name, @project_prefix <> name) and
         Map.keys(attrs) -- ~w(argv kind required timeout_ms) == [] and
         valid_argv?(argv) and attrs["kind"] in Shoestring.Cobbler.GateSpec.kinds() and
         Map.get(attrs, "required", true) in [true, false] and
         (is_nil(timeout) or (is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms)) do
      {:ok,
       %{
         argv: argv,
         kind: attrs["kind"],
         version: 1,
         source: "configuration",
         required: Map.get(attrs, "required", true),
         timeout_ms: timeout
       }}
    else
      :error
    end
  end

  defp project_spec(_name, _attrs), do: :error

  defp valid_argv?([program | _] = argv) when length(argv) <= @max_argv do
    is_binary(program) and Regex.match?(@program, program) and
      Enum.all?(argv, fn arg ->
        is_binary(arg) and arg != "" and byte_size(arg) <= @max_arg_bytes and
          String.valid?(arg) and not String.contains?(arg, <<0>>) and
          not Shoestring.Harness.Security.secret_value?(arg)
      end)
  end

  defp valid_argv?(_argv), do: false

  @doc """
  Validates one gate reference and returns it normalized.

  Returns `{:ok, reference}` or `{:error, Ecto.Changeset.t()}`.
  """
  @spec validate(term(), atom()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def validate(reference, field) when is_map(reference) do
    with {:ok, name} <- gate_name(reference, field),
         {:ok, spec} <- fetch_spec(name, field),
         {:ok, parameters} <- validate_parameters(reference, name, spec, field) do
      {:ok, Map.merge(%{"gate" => name}, parameters)}
    end
  end

  def validate(_reference, field), do: Contract.invalid(field, "must be an object")

  @doc "Resolves a validated gate reference to the trusted argv it names."
  @spec argv(map()) :: {:ok, [String.t()]} | {:error, Ecto.Changeset.t()}
  def argv(%{"gate" => _name} = reference) do
    case spec(reference) do
      {:ok, %{argv: argv}} -> {:ok, argv}
      {:error, :project_gate_not_configured} -> Contract.invalid(:gate, "is not configured")
      {:error, :unknown_gate} -> Contract.invalid(:gate, "must be a trusted gate name")
    end
  end

  def argv(_reference), do: Contract.invalid(:gate, "must be an object naming a gate")

  defp gate_name(reference, field) do
    case Contract.fetch(reference, :gate) do
      {:ok, name} when is_binary(name) -> {:ok, name}
      {:ok, _other} -> Contract.invalid(field, "gate must be a string")
      :error -> Contract.invalid(field, "must name a gate")
    end
  end

  defp fetch_spec(name, field) do
    case Map.fetch(@gates, name) do
      {:ok, spec} ->
        {:ok, spec}

      :error ->
        if project?(name),
          do: {:ok, %{parameters: []}},
          else:
            Contract.invalid(
              field,
              "must be one of #{Enum.join(names(), ", ")}, or project:<configured name>"
            )
    end
  end

  defp validate_parameters(reference, name, spec, field) do
    supplied = reference |> Map.keys() |> Enum.map(&to_string/1) |> List.delete("gate")

    cond do
      Enum.any?(supplied, &(&1 not in spec.parameters)) ->
        Contract.invalid(field, "carries a parameter this gate does not accept")

      "test_paths" in supplied ->
        with {:ok, paths} <- test_paths(Map.get(reference, "test_paths"), name, field) do
          {:ok, %{"test_paths" => paths}}
        end

      name == "python_unittest" ->
        Contract.invalid(field, "python_unittest requires named test_paths")

      true ->
        {:ok, %{}}
    end
  end

  defp test_paths(value, name, field) when is_list(value) do
    cond do
      value == [] ->
        Contract.invalid(field, "test_paths must list at least one path")

      length(value) > @max_test_paths ->
        Contract.invalid(field, "test_paths contains too many entries")

      not Enum.all?(value, &test_path?(&1, name)) ->
        pattern = if name == "python_unittest", do: "test/**/test_*.py", else: "test/*_test.exs"
        Contract.invalid(field, "test_paths must be repository-relative #{pattern} paths")

      length(Enum.uniq(value)) != length(value) ->
        Contract.invalid(field, "test_paths must not repeat a path")

      true ->
        {:ok, value}
    end
  end

  defp test_paths(_value, _name, field), do: Contract.invalid(field, "test_paths must be a list")

  defp test_path?(path, name) when is_binary(path) do
    pattern =
      if name == "python_unittest", do: @python_test_path_pattern, else: @test_path_pattern

    byte_size(path) <= 200 and Regex.match?(pattern, path) and not String.contains?(path, "..")
  end

  defp test_path?(_path, _name), do: false
end
