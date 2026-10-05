defmodule Shoestring.Cobbler.PlanContract do
  @moduledoc """
  The strict, versioned plan representation: a goal acceptance contract plus a
  validated task DAG, with a deterministic content digest.

  A contract is a pure value. Building one validates every field against an
  explicit bound, rejects every unknown field, rejects anything that looks
  like a command the plan wants run, validates the dependency graph, and
  computes the digest that an approval later binds to. Nothing here touches
  the database, spawns a process, or executes a gate.

  ## Fail closed

  Malformed input, unknown fields, oversized input, an unbounded task, an
  unknown acceptance gate, or an invalid graph all reject the whole plan.
  Nothing is coerced, defaulted into validity, or truncated to fit: a plan
  that does not validate has no partial form that can be stored or approved.

  ## No embedded commands

  A plan never carries a shell string. Acceptance is expressed as references
  into `Shoestring.Cobbler.PlanGate`, the closed registry of trusted gates;
  a key that names a command (`command`, `argv`, `shell`, `script`, ...)
  anywhere in the document rejects the plan with its path, before any other
  validation, so the error names the real problem rather than "unsupported
  field". Model self-report is never acceptance, which is why every task
  must cite at least one trusted gate.

  ## Deterministic digest

  `canonical_json/1` renders the normalized content with every object key
  sorted, so two structurally identical plans produce byte-identical JSON
  regardless of map iteration order, and `digest/1` is the SHA-256 of that
  rendering. Normalization also makes optional list fields always present
  and empty rather than absent, so "no constraints" has one representation
  and one digest. This is the digest an approval binds to and the digest
  replay must reproduce.

  ## Error shapes

  Every failure is a structured tagged tuple, never a bare `:error`:

    * `{:invalid_plan, Ecto.Changeset.t()}` — a field violated its contract
    * `{:invalid_graph, reason}` — see `Shoestring.Cobbler.PlanGraph`
    * `{:forbidden_command_field, %{path: [...], key: binary}}`
    * `{:plan_too_large, %{bytes: integer, limit: integer}}`
    * `{:budget_exceeded, %{field: atom, declared: integer, required: integer}}`
    * `{:malformed_plan_json, term}` — only from `from_canonical_json/1`
  """

  alias Shoestring.Cobbler.{PlanGate, PlanGraph}
  alias Shoestring.Harness.Contract

  @version 1

  # Bounds. Each exists so a plan cannot grow without a reviewer noticing;
  # the whole-document byte cap is the backstop that makes the rest safe to
  # walk.
  @max_plan_bytes 65_536
  @max_input_nodes 10_000
  @max_tasks 32
  @max_dependencies 16
  @max_list 16
  @max_gates 4
  @max_criteria 8
  @max_evidence 8
  @max_hints 32
  @max_risks 8
  @min_attempts 1
  @max_task_attempts 20
  @max_total_attempts 200
  @max_task_duration_seconds 14_400
  @max_total_duration_seconds 86_400

  # Keys that would turn a reviewed plan into an execution channel. Rejected
  # anywhere in the document, at any depth, under any parent.
  @forbidden_keys ~w(
    command commands cmd argv shell script exec entrypoint run_command
    bash sh eval system spawn
  )

  @base_revision_pattern ~r/\A[0-9a-f]{7,40}\z/
  @task_id_pattern ~r/\A[a-z0-9][a-z0-9_-]{0,62}\z/
  @remote_ref_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_.\/-]{0,199}\z/
  @file_hint_pattern ~r/\A[A-Za-z0-9_][A-Za-z0-9_.\/-]{0,199}\z/

  @goal_keys ~w(statement repository constraints non_goals acceptance)
  @repository_keys ~w(base_revision remote_ref)
  @acceptance_keys ~w(gates evidence)
  @budget_keys ~w(max_total_attempts max_total_duration_seconds)
  @task_keys ~w(
    id title outcome depends_on inputs expected_artifacts hints
    acceptance_criteria gates checkpoint risks execution
  )
  @hint_keys ~w(files symbols)
  @checkpoint_keys ~w(condition evidence)
  @execution_keys ~w(max_attempts max_duration_seconds)
  @planner_keys ~w(identity version source_context_refs)
  @plan_keys ~w(version goal budget tasks planner)

  @enforce_keys [:version, :content, :digest, :ordered_task_ids]
  defstruct [:version, :content, :digest, :ordered_task_ids]

  @type t :: %__MODULE__{
          version: pos_integer(),
          content: map(),
          digest: String.t(),
          ordered_task_ids: [String.t()]
        }

  @type error ::
          {:invalid_plan, Ecto.Changeset.t()}
          | {:invalid_graph, PlanGraph.error()}
          | {:forbidden_command_field, %{path: [String.t()], key: String.t()}}
          | {:plan_too_large, %{bytes: non_neg_integer(), limit: pos_integer()}}
          | {:budget_exceeded, %{field: atom(), declared: integer(), required: integer()}}
          | {:malformed_plan_json, term()}

  @spec version() :: pos_integer()
  def version, do: @version

  @spec max_plan_bytes() :: pos_integer()
  def max_plan_bytes, do: @max_plan_bytes

  @spec max_tasks() :: pos_integer()
  def max_tasks, do: @max_tasks

  @doc "Validates a goal acceptance contract before asking a planner to decompose it."
  def validate_goal(goal) do
    with :ok <- bound_input(goal),
         :ok <- scan_forbidden_keys(goal),
         {:ok, normalized} <- normalize_goal({:ok, goal}),
         {:ok, _encoded} <- bound_encoded(normalized) do
      {:ok, normalized}
    end
    |> tag_error()
  end

  @doc """
  Validates untrusted plan attributes into a contract.

  Accepts atom- or string-keyed input and returns normalized string-keyed
  content with a deterministic digest and topological task order.
  """
  @spec new(term()) :: {:ok, t()} | {:error, error()}
  def new(attrs) when is_map(attrs) do
    with :ok <- scan_forbidden_keys(attrs),
         :ok <- bound_input(attrs),
         {:ok, content} <- normalize(attrs),
         {:ok, ordered} <- validate_graph(content),
         {:ok, encoded} <- bound_encoded(content) do
      {:ok,
       %__MODULE__{
         version: @version,
         content: content,
         digest: digest_encoded(encoded),
         ordered_task_ids: ordered
       }}
    end
    |> tag_error()
  end

  def new(_attrs), do: invalid(:base, "must be an object")

  # `Shoestring.Harness.Contract` helpers answer with a bare changeset. Every
  # error leaving this module is a tagged tuple instead, so a caller never
  # has to pattern match two shapes to find out why a plan was rejected.
  defp tag_error({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, {:invalid_plan, changeset}}

  defp tag_error(result), do: result

  @doc "Renders normalized content as canonical JSON with every object key sorted."
  @spec canonical_json(t() | map()) :: String.t()
  def canonical_json(%__MODULE__{content: content}), do: canonical_json(content)
  def canonical_json(content) when is_map(content), do: encode_canonical(content)

  @doc "The SHA-256 digest of the canonical rendering of a contract or its content."
  @spec digest(t() | map()) :: String.t()
  def digest(%__MODULE__{digest: digest}), do: digest
  def digest(content) when is_map(content), do: content |> canonical_json() |> digest_encoded()

  @doc """
  Re-validates a canonical JSON rendering back into a contract.

  This is the replay path: a stored event carries the canonical rendering,
  and rebuilding runs it through the same validation as a fresh proposal, so
  a plan that could not be proposed today cannot be resurrected from history
  either.
  """
  @spec from_canonical_json(term()) :: {:ok, t()} | {:error, error()}
  def from_canonical_json(json) when is_binary(json) do
    if byte_size(json) > @max_plan_bytes do
      {:error, {:plan_too_large, %{bytes: byte_size(json), limit: @max_plan_bytes}}}
    else
      case Jason.decode(json) do
        {:ok, decoded} when is_map(decoded) -> new(decoded)
        {:ok, _other} -> {:error, {:malformed_plan_json, :not_an_object}}
        {:error, reason} -> {:error, {:malformed_plan_json, reason}}
      end
    end
  end

  def from_canonical_json(_json), do: {:error, {:malformed_plan_json, :not_a_string}}

  @doc "The declared task ids, in the order the author wrote them."
  @spec task_ids(t()) :: [String.t()]
  def task_ids(%__MODULE__{content: content}),
    do: Enum.map(content["tasks"], & &1["id"])

  @doc "Resolves every gate the plan cites to its trusted argv, for inspection only."
  @spec gate_argv(t()) :: {:ok, [[String.t()]]} | {:error, Ecto.Changeset.t()}
  def gate_argv(%__MODULE__{content: content}) do
    references =
      get_in(content, ["goal", "acceptance", "gates"]) ++
        Enum.flat_map(content["tasks"], & &1["gates"])

    Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, acc} ->
      case PlanGate.argv(reference) do
        {:ok, argv} -> {:cont, {:ok, [argv | acc]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, argv} -> {:ok, Enum.reverse(argv)}
      error -> error
    end
  end

  # ----------------------------------------------------------------------------
  # Pre-validation guards
  # ----------------------------------------------------------------------------

  defp scan_forbidden_keys(term), do: scan_forbidden_keys(term, [])

  defp scan_forbidden_keys(term, path) when is_map(term) do
    Enum.reduce_while(term, :ok, fn {key, value}, :ok ->
      key_string = to_string(key)

      if key_string in @forbidden_keys do
        {:halt,
         {:error,
          {:forbidden_command_field, %{path: Enum.reverse([key_string | path]), key: key_string}}}}
      else
        case scan_forbidden_keys(value, [key_string | path]) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    end)
  end

  defp scan_forbidden_keys(term, path) when is_list(term) do
    term
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case scan_forbidden_keys(value, [Integer.to_string(index) | path]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp scan_forbidden_keys(_term, _path), do: :ok

  # Bound the term before walking it field by field, so a pathological input
  # cannot spend the validator's time before the byte cap would have caught
  # it. Oversized input fails; it is never trimmed to fit.
  defp bound_input(term) do
    case count_nodes(term, 0) do
      {:ok, _count} -> :ok
      :overflow -> {:error, {:plan_too_large, %{bytes: :unknown, limit: @max_plan_bytes}}}
    end
  end

  defp count_nodes(_term, count) when count > @max_input_nodes, do: :overflow

  defp count_nodes(term, count) when is_map(term) do
    Enum.reduce_while(term, {:ok, count + 1}, fn {_key, value}, {:ok, acc} ->
      case count_nodes(value, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        :overflow -> {:halt, :overflow}
      end
    end)
  end

  defp count_nodes(term, count) when is_list(term) do
    Enum.reduce_while(term, {:ok, count + 1}, fn value, {:ok, acc} ->
      case count_nodes(value, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        :overflow -> {:halt, :overflow}
      end
    end)
  end

  defp count_nodes(_term, count), do: {:ok, count + 1}

  defp bound_encoded(content) do
    encoded = encode_canonical(content)

    if byte_size(encoded) > @max_plan_bytes do
      {:error, {:plan_too_large, %{bytes: byte_size(encoded), limit: @max_plan_bytes}}}
    else
      {:ok, encoded}
    end
  end

  # ----------------------------------------------------------------------------
  # Normalization
  # ----------------------------------------------------------------------------

  defp normalize(attrs) do
    with :ok <- strict_keys(attrs, @plan_keys, :base),
         {:ok, _version} <- plan_version(attrs),
         {:ok, goal} <- normalize_goal(Contract.fetch(attrs, :goal)),
         {:ok, budget} <- normalize_budget(Contract.fetch(attrs, :budget)),
         {:ok, tasks} <- normalize_tasks(Contract.fetch(attrs, :tasks)),
         {:ok, planner} <- normalize_planner(Contract.fetch(attrs, :planner)),
         :ok <- check_budget(budget, tasks) do
      content =
        %{
          "version" => @version,
          "goal" => goal,
          "budget" => budget,
          "tasks" => tasks
        }
        |> maybe_put("planner", planner)

      {:ok, content}
    end
  end

  defp plan_version(attrs) do
    case Contract.fetch(attrs, :version) do
      :error -> {:ok, @version}
      {:ok, @version} -> {:ok, @version}
      {:ok, _other} -> invalid(:version, "must equal #{@version}")
    end
  end

  defp normalize_goal({:ok, goal}) when is_map(goal) do
    with :ok <- strict_keys(goal, @goal_keys, :goal),
         {:ok, statement} <-
           Contract.text(Contract.required(goal, :statement), :statement, max: 2_000),
         {:ok, repository} <- normalize_repository(Contract.fetch(goal, :repository)),
         {:ok, constraints} <- text_list(goal, :constraints, :constraints, @max_list, 500),
         {:ok, non_goals} <- text_list(goal, :non_goals, :non_goals, @max_list, 500),
         {:ok, acceptance} <- normalize_acceptance(Contract.fetch(goal, :acceptance)) do
      {:ok,
       %{
         "statement" => statement,
         "repository" => repository,
         "constraints" => constraints,
         "non_goals" => non_goals,
         "acceptance" => acceptance
       }}
    end
  end

  defp normalize_goal(_other), do: invalid(:goal, "must be an object")

  defp normalize_repository({:ok, repository}) when is_map(repository) do
    with :ok <- strict_keys(repository, @repository_keys, :repository),
         {:ok, base_revision} <- base_revision(Contract.required(repository, :base_revision)),
         {:ok, remote_ref} <- remote_ref(Contract.optional(repository, :remote_ref)) do
      {:ok, maybe_put(%{"base_revision" => base_revision}, "remote_ref", remote_ref)}
    end
  end

  defp normalize_repository(_other), do: invalid(:repository, "must be an object")

  # A base revision is a resolved commit, never a moving ref: a plan approved
  # against "main" would silently mean something different tomorrow, and the
  # approval digest would no longer describe the work.
  defp base_revision({:ok, value}) when is_binary(value) do
    if Regex.match?(@base_revision_pattern, value) do
      {:ok, value}
    else
      invalid(:base_revision, "must be a lowercase hexadecimal git revision")
    end
  end

  defp base_revision({:error, _changeset} = error), do: error
  defp base_revision(_other), do: invalid(:base_revision, "must be a string")

  defp remote_ref({:ok, nil}), do: {:ok, nil}

  defp remote_ref({:ok, value}) when is_binary(value) do
    if Regex.match?(@remote_ref_pattern, value) and not String.contains?(value, "..") do
      {:ok, value}
    else
      invalid(:remote_ref, "must be a simple ref name")
    end
  end

  defp remote_ref(_other), do: invalid(:remote_ref, "must be a string")

  defp normalize_acceptance({:ok, acceptance}) when is_map(acceptance) do
    with :ok <- strict_keys(acceptance, @acceptance_keys, :acceptance),
         {:ok, gates} <- gate_list(Contract.fetch(acceptance, :gates), :acceptance_gates),
         {:ok, evidence} <-
           required_text_list(acceptance, :evidence, :acceptance_evidence, @max_evidence, 500) do
      {:ok, %{"gates" => gates, "evidence" => evidence}}
    end
  end

  defp normalize_acceptance(_other), do: invalid(:acceptance, "must be an object")

  defp normalize_budget({:ok, budget}) when is_map(budget) do
    with :ok <- strict_keys(budget, @budget_keys, :budget),
         {:ok, attempts} <-
           bounded_integer(
             Contract.required(budget, :max_total_attempts),
             :max_total_attempts,
             @min_attempts,
             @max_total_attempts
           ),
         {:ok, seconds} <-
           bounded_integer(
             Contract.required(budget, :max_total_duration_seconds),
             :max_total_duration_seconds,
             1,
             @max_total_duration_seconds
           ) do
      {:ok, %{"max_total_attempts" => attempts, "max_total_duration_seconds" => seconds}}
    end
  end

  defp normalize_budget(_other), do: invalid(:budget, "must be an object")

  defp normalize_tasks({:ok, tasks}) when is_list(tasks) do
    cond do
      tasks == [] -> invalid(:tasks, "must declare at least one task")
      length(tasks) > @max_tasks -> invalid(:tasks, "declares too many tasks")
      true -> reduce_ok(tasks, &normalize_task/1)
    end
  end

  defp normalize_tasks(_other), do: invalid(:tasks, "must be a list")

  defp normalize_task(task) when is_map(task) do
    with :ok <- strict_keys(task, @task_keys, :task),
         {:ok, id} <- task_id(Contract.required(task, :id)),
         {:ok, title} <- Contract.text(Contract.required(task, :title), :task_title, max: 200),
         {:ok, outcome} <-
           Contract.text(Contract.required(task, :outcome), :task_outcome, max: 1_000),
         {:ok, depends_on} <- dependency_list(Contract.optional(task, :depends_on)),
         {:ok, inputs} <- text_list(task, :inputs, :task_inputs, @max_list, 500),
         {:ok, artifacts} <-
           text_list(task, :expected_artifacts, :task_expected_artifacts, @max_list, 300),
         {:ok, hints} <- normalize_hints(Contract.optional(task, :hints)),
         {:ok, criteria} <-
           required_text_list(
             task,
             :acceptance_criteria,
             :task_acceptance_criteria,
             @max_criteria,
             500
           ),
         {:ok, gates} <- gate_list(Contract.fetch(task, :gates), :task_gates),
         {:ok, checkpoint} <- normalize_checkpoint(Contract.fetch(task, :checkpoint)),
         {:ok, risks} <- text_list(task, :risks, :task_risks, @max_risks, 500),
         {:ok, execution} <- normalize_execution(Contract.fetch(task, :execution)) do
      {:ok,
       %{
         "id" => id,
         "title" => title,
         "outcome" => outcome,
         "depends_on" => depends_on,
         "inputs" => inputs,
         "expected_artifacts" => artifacts,
         "hints" => hints,
         "acceptance_criteria" => criteria,
         "gates" => gates,
         "checkpoint" => checkpoint,
         "risks" => risks,
         "execution" => execution
       }}
    end
  end

  defp normalize_task(_task), do: invalid(:task, "must be an object")

  defp task_id({:ok, value}) when is_binary(value) do
    if Regex.match?(@task_id_pattern, value) do
      {:ok, value}
    else
      invalid(:task_id, "must be a lowercase slug of letters, digits, underscores, and hyphens")
    end
  end

  defp task_id({:error, _changeset} = error), do: error
  defp task_id(_other), do: invalid(:task_id, "must be a string")

  defp dependency_list({:ok, nil}), do: {:ok, []}

  defp dependency_list({:ok, value}) when is_list(value) do
    cond do
      length(value) > @max_dependencies ->
        invalid(:depends_on, "declares too many dependencies")

      not Enum.all?(value, &(is_binary(&1) and Regex.match?(@task_id_pattern, &1))) ->
        invalid(:depends_on, "must reference task ids")

      true ->
        {:ok, value}
    end
  end

  defp dependency_list(_other), do: invalid(:depends_on, "must be a list")

  defp normalize_hints({:ok, nil}), do: {:ok, %{"files" => [], "symbols" => []}}

  defp normalize_hints({:ok, hints}) when is_map(hints) do
    with :ok <- strict_keys(hints, @hint_keys, :hints),
         {:ok, files} <- file_hints(Contract.optional(hints, :files)),
         {:ok, symbols} <- text_list(hints, :symbols, :hint_symbols, @max_hints, 200) do
      {:ok, %{"files" => files, "symbols" => symbols}}
    end
  end

  defp normalize_hints(_other), do: invalid(:hints, "must be an object")

  defp file_hints({:ok, nil}), do: {:ok, []}

  defp file_hints({:ok, value}) when is_list(value) do
    cond do
      length(value) > @max_hints ->
        invalid(:hint_files, "lists too many files")

      not Enum.all?(value, &file_hint?/1) ->
        invalid(:hint_files, "must be repository-relative paths")

      true ->
        {:ok, value}
    end
  end

  defp file_hints(_other), do: invalid(:hint_files, "must be a list")

  defp file_hint?(path) when is_binary(path),
    do: Regex.match?(@file_hint_pattern, path) and not String.contains?(path, "..")

  defp file_hint?(_path), do: false

  defp normalize_checkpoint({:ok, checkpoint}) when is_map(checkpoint) do
    with :ok <- strict_keys(checkpoint, @checkpoint_keys, :checkpoint),
         {:ok, condition} <-
           Contract.text(Contract.required(checkpoint, :condition), :checkpoint_condition,
             max: 500
           ),
         {:ok, evidence} <-
           required_text_list(checkpoint, :evidence, :checkpoint_evidence, @max_evidence, 500) do
      {:ok, %{"condition" => condition, "evidence" => evidence}}
    end
  end

  defp normalize_checkpoint(_other), do: invalid(:checkpoint, "must be an object")

  # The boundedness rule the milestone asks for, stated in numbers rather
  # than in planner adjectives: a task that will not say how many attempts
  # and how long it may take is not a bounded task and cannot be approved.
  defp normalize_execution({:ok, execution}) when is_map(execution) do
    with :ok <- strict_keys(execution, @execution_keys, :execution),
         {:ok, attempts} <-
           bounded_integer(
             Contract.required(execution, :max_attempts),
             :max_attempts,
             @min_attempts,
             @max_task_attempts
           ),
         {:ok, seconds} <-
           bounded_integer(
             Contract.required(execution, :max_duration_seconds),
             :max_duration_seconds,
             1,
             @max_task_duration_seconds
           ) do
      {:ok, %{"max_attempts" => attempts, "max_duration_seconds" => seconds}}
    end
  end

  defp normalize_execution(_other), do: invalid(:execution, "must be an object")

  # Planner provenance is recorded, never trusted. It says which planner
  # produced the proposal and what it looked at; it authorizes nothing, and
  # a human still has to approve the revision.
  defp normalize_planner({:ok, nil}), do: {:ok, nil}
  defp normalize_planner(:error), do: {:ok, nil}

  defp normalize_planner({:ok, planner}) when is_map(planner) do
    with :ok <- strict_keys(planner, @planner_keys, :planner),
         {:ok, identity} <-
           Contract.text(Contract.required(planner, :identity), :planner_identity, max: 200),
         {:ok, version} <-
           Contract.text(Contract.required(planner, :version), :planner_version, max: 64),
         {:ok, refs} <-
           text_list(planner, :source_context_refs, :planner_source_context_refs, @max_list, 300) do
      {:ok,
       %{
         "identity" => identity,
         "version" => version,
         "source_context_refs" => refs
       }}
    end
  end

  defp normalize_planner(_other), do: invalid(:planner, "must be an object")

  defp check_budget(budget, tasks) do
    required_attempts = Enum.reduce(tasks, 0, &(&1["execution"]["max_attempts"] + &2))
    required_seconds = Enum.reduce(tasks, 0, &(&1["execution"]["max_duration_seconds"] + &2))

    cond do
      budget["max_total_attempts"] < required_attempts ->
        {:error,
         {:budget_exceeded,
          %{
            field: :max_total_attempts,
            declared: budget["max_total_attempts"],
            required: required_attempts
          }}}

      budget["max_total_duration_seconds"] < required_seconds ->
        {:error,
         {:budget_exceeded,
          %{
            field: :max_total_duration_seconds,
            declared: budget["max_total_duration_seconds"],
            required: required_seconds
          }}}

      true ->
        :ok
    end
  end

  defp validate_graph(content) do
    case PlanGraph.validate(content["tasks"]) do
      {:ok, ordered} -> {:ok, ordered}
      {:error, reason} -> {:error, {:invalid_graph, reason}}
    end
  end

  # ----------------------------------------------------------------------------
  # Shared validation helpers
  # ----------------------------------------------------------------------------

  defp strict_keys(map, allowed, field) do
    unknown = map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in allowed))

    case unknown do
      [] ->
        :ok

      keys ->
        invalid(field, "contains unsupported fields: #{Enum.join(Enum.sort(keys), ", ")}")
    end
  end

  defp text_list(map, key, field, max, max_length) do
    case Contract.optional(map, key) do
      {:ok, nil} -> {:ok, []}
      {:ok, value} -> bounded_text_list(value, field, max, max_length, allow_empty: true)
      error -> error
    end
  end

  defp required_text_list(map, key, field, max, max_length) do
    case Contract.fetch(map, key) do
      {:ok, value} -> bounded_text_list(value, field, max, max_length, allow_empty: false)
      :error -> invalid(field, "can't be blank")
    end
  end

  defp bounded_text_list(value, field, max, max_length, opts) when is_list(value) do
    cond do
      value == [] and not Keyword.fetch!(opts, :allow_empty) ->
        invalid(field, "must list at least one entry")

      length(value) > max ->
        invalid(field, "contains too many entries")

      true ->
        reduce_ok(value, &Contract.text(&1, field, max: max_length))
    end
  end

  defp bounded_text_list(_value, field, _max, _max_length, _opts),
    do: invalid(field, "must be a list")

  defp gate_list({:ok, value}, field) when is_list(value) do
    cond do
      value == [] ->
        invalid(field, "must cite at least one trusted acceptance gate")

      length(value) > @max_gates ->
        invalid(field, "cites too many gates")

      true ->
        with {:ok, gates} <- reduce_ok(value, &PlanGate.validate(&1, field)) do
          names = Enum.map(gates, & &1["gate"])

          if length(Enum.uniq(names)) == length(names) do
            {:ok, gates}
          else
            invalid(field, "must not cite the same gate twice")
          end
        end
    end
  end

  defp gate_list({:ok, _other}, field), do: invalid(field, "must be a list")
  defp gate_list(:error, field), do: invalid(field, "can't be blank")

  defp bounded_integer({:ok, value}, field, min, max) when is_integer(value) do
    if value >= min and value <= max do
      {:ok, value}
    else
      invalid(field, "must be between #{min} and #{max}")
    end
  end

  defp bounded_integer({:error, _changeset} = error, _field, _min, _max), do: error
  defp bounded_integer(_value, field, _min, _max), do: invalid(field, "must be an integer")

  defp reduce_ok(values, fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, %Ecto.Changeset{} = changeset} -> {:halt, {:error, {:invalid_plan, changeset}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp invalid(field, message) do
    {:error, changeset} = Contract.invalid(field, message)
    {:error, {:invalid_plan, changeset}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ----------------------------------------------------------------------------
  # Canonical rendering and digest
  # ----------------------------------------------------------------------------

  defp encode_canonical(value) when is_map(value) do
    inner =
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
      |> Enum.sort_by(fn {key, _nested} -> key end)
      |> Enum.map_join(",", fn {key, nested} ->
        Jason.encode!(key) <> ":" <> encode_canonical(nested)
      end)

    "{" <> inner <> "}"
  end

  defp encode_canonical(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &encode_canonical/1) <> "]"

  defp encode_canonical(value), do: Jason.encode!(value)

  defp digest_encoded(encoded),
    do: :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
end
