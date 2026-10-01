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
  no parent-directory segment. Every other gate accepts no parameter at all,
  so a parameter that a gate does not declare rejects the plan.

  Model success is never an acceptance gate. Acceptance is what a trusted
  deterministic command reports, not what a provider claims about itself;
  that is why this registry holds only repository gates and why
  `Shoestring.Cobbler.PlanContract` requires at least one of them per task.

  Nothing here executes. `argv/1` resolves a validated reference to the argv
  a later execution package will run; this slice only records plans.
  """

  alias Shoestring.Harness.Contract

  @gates %{
    "mix_precommit" => %{argv: ["mix", "precommit"], parameters: []},
    "mix_test" => %{argv: ["mix", "test"], parameters: ["test_paths"]},
    "mix_format_check" => %{argv: ["mix", "format", "--check-formatted"], parameters: []},
    "mix_compile_strict" => %{
      argv: ["mix", "compile", "--warnings-as-errors"],
      parameters: []
    }
  }

  @max_test_paths 16
  @test_path_pattern ~r/\Atest\/[A-Za-z0-9_][A-Za-z0-9_.\/-]{0,180}_test\.exs\z/

  @doc "The sorted list of trusted gate names a plan may reference."
  @spec names() :: [String.t()]
  def names, do: @gates |> Map.keys() |> Enum.sort()

  @doc """
  Validates one gate reference and returns it normalized.

  Returns `{:ok, reference}` or `{:error, Ecto.Changeset.t()}`.
  """
  @spec validate(term(), atom()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def validate(reference, field) when is_map(reference) do
    with {:ok, name} <- gate_name(reference, field),
         {:ok, spec} <- fetch_spec(name, field),
         {:ok, parameters} <- validate_parameters(reference, spec, field) do
      {:ok, Map.merge(%{"gate" => name}, parameters)}
    end
  end

  def validate(_reference, field), do: Contract.invalid(field, "must be an object")

  @doc "Resolves a validated gate reference to the trusted argv it names."
  @spec argv(map()) :: {:ok, [String.t()]} | {:error, Ecto.Changeset.t()}
  def argv(%{"gate" => name} = reference) do
    case Map.fetch(@gates, name) do
      {:ok, %{argv: argv}} -> {:ok, argv ++ Map.get(reference, "test_paths", [])}
      :error -> Contract.invalid(:gate, "must be a trusted gate name")
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
        Contract.invalid(
          field,
          "must be one of #{Enum.join(names(), ", ")}"
        )
    end
  end

  defp validate_parameters(reference, spec, field) do
    supplied = reference |> Map.keys() |> Enum.map(&to_string/1) |> List.delete("gate")

    cond do
      Enum.any?(supplied, &(&1 not in spec.parameters)) ->
        Contract.invalid(field, "carries a parameter this gate does not accept")

      "test_paths" in supplied ->
        with {:ok, paths} <- test_paths(Map.get(reference, "test_paths"), field) do
          {:ok, %{"test_paths" => paths}}
        end

      true ->
        {:ok, %{}}
    end
  end

  defp test_paths(value, field) when is_list(value) do
    cond do
      value == [] ->
        Contract.invalid(field, "test_paths must list at least one path")

      length(value) > @max_test_paths ->
        Contract.invalid(field, "test_paths contains too many entries")

      not Enum.all?(value, &test_path?/1) ->
        Contract.invalid(field, "test_paths must be repository-relative test/*_test.exs paths")

      length(Enum.uniq(value)) != length(value) ->
        Contract.invalid(field, "test_paths must not repeat a path")

      true ->
        {:ok, value}
    end
  end

  defp test_paths(_value, field), do: Contract.invalid(field, "test_paths must be a list")

  defp test_path?(path) when is_binary(path) do
    Regex.match?(@test_path_pattern, path) and not String.contains?(path, "..")
  end

  defp test_path?(_path), do: false
end
