defmodule Shoestring.Cobbler.GateSpec do
  @moduledoc """
  The versioned specification a gate run is recorded against (iteration 8,
  work package A).

  A specification is built from a validated gate reference
  (`Shoestring.Cobbler.PlanGate`) and Shoestring's own runner settings, never
  from plan or model text beyond the gate's name and its allow-listed
  parameters. It names everything that decides what a green result means:

  - `gate`, `version` and `source` (`builtin` or `configuration`);
  - `kind` and `order`: gates run cheap first (repository status, format,
    lint/compile/typecheck, build, test, precommit), in plan order within a
    kind;
  - `argv`, an argument array run without a shell, in the task's worktree;
  - `environment`: the names of the only variables the gate sees
    (`Shoestring.Cobbler.GateSandbox`);
  - `timeout_ms`, `output_limit_bytes`, and `success` (exit status zero);
  - `required`: a failed optional gate is recorded but does not block;
  - `artifact`: the gate's combined output is kept as a redacted artifact.

  `identity/1` is `<gate>@<version>:sha256:<digest of the canonical JSON>`,
  recorded with every run so a changed command or setting is visible in the
  evidence. The commit a run verifies is recorded beside it, not in it.
  """

  alias Shoestring.Cobbler.{GateSandbox, PlanContract, PlanGate}

  @schema_version 1
  @order %{
    "status" => 0,
    "format" => 1,
    "lint" => 2,
    "compile" => 2,
    "typecheck" => 2,
    "build" => 3,
    "test" => 4,
    "precommit" => 5
  }
  @default_timeout_ms 120_000
  @output_limit_bytes 65_536

  @type t :: %{String.t() => term()}

  @doc "The gate kinds, cheapest first."
  @spec kinds() :: [String.t()]
  def kinds, do: @order |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

  @doc "The combined output limit every gate runs under."
  @spec output_limit_bytes() :: pos_integer()
  def output_limit_bytes, do: @output_limit_bytes

  @doc """
  Builds the specification of a validated reference. `default_timeout_ms`
  applies when the gate does not set its own.
  """
  @spec build(map(), pos_integer()) ::
          {:ok, t()} | {:error, :project_gate_not_configured | :unknown_gate}
  def build(reference, default_timeout_ms \\ @default_timeout_ms) do
    with {:ok, facts} <- PlanGate.spec(reference) do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "gate" => facts.gate,
         "version" => facts.version,
         "source" => facts.source,
         "kind" => facts.kind,
         "order" => Map.fetch!(@order, facts.kind),
         "argv" => facts.argv,
         "working_directory" => "worktree",
         "environment" => GateSandbox.environment_names(),
         "timeout_ms" => facts.timeout_ms || default_timeout_ms,
         "output_limit_bytes" => @output_limit_bytes,
         "success" => "exit_status_zero",
         "required" => facts.required,
         "artifact" => "combined_output_redacted"
       }}
    end
  end

  @doc "The recorded identity of a specification."
  @spec identity(t()) :: String.t()
  def identity(%{"gate" => gate, "version" => version} = spec),
    do: "#{gate}@#{version}:sha256:#{PlanContract.digest(spec)}"

  @doc "Whether `value` has the shape of a recorded identity."
  @spec identity?(term()) :: boolean()
  def identity?(value) when is_binary(value) do
    case Regex.run(~r/\A(.+)@([1-9][0-9]{0,3}):sha256:[0-9a-f]{64}\z/, value) do
      [_, gate, _version] -> PlanGate.known?(gate)
      _ -> false
    end
  end

  def identity?(_value), do: false

  @doc """
  Specifies and orders a list of references for one run: cheap kinds first,
  plan order within a kind. Returns `[{reference, spec}]`, or
  `{:error, {reference, reason}}` for the first reference that cannot be
  specified (nothing runs then).

  When none of the gates is required, every one of them is: a task is never
  accepted on optional evidence alone.
  """
  @spec plan([map()], pos_integer()) :: {:ok, [{map(), t()}]} | {:error, {map(), atom()}}
  def plan(references, default_timeout_ms \\ @default_timeout_ms) do
    references
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {reference, index}, {:ok, acc} ->
      case build(reference, default_timeout_ms) do
        {:ok, spec} -> {:cont, {:ok, [{reference, spec, index} | acc]}}
        {:error, reason} -> {:halt, {:error, {reference, reason}}}
      end
    end)
    |> case do
      {:ok, specified} ->
        any_required? = Enum.any?(specified, fn {_ref, spec, _index} -> spec["required"] end)

        {:ok,
         specified
         |> Enum.sort_by(fn {_ref, spec, index} -> {spec["order"], index} end)
         |> Enum.map(fn {ref, spec, _index} ->
           {ref, if(any_required?, do: spec, else: Map.put(spec, "required", true))}
         end)}

      error ->
        error
    end
  end
end
