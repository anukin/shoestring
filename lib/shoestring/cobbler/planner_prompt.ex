defmodule Shoestring.Cobbler.PlannerPrompt do
  @moduledoc """
  Bounded planning-prompt construction from durable goal evidence.

  The prompt is a pure value built from explicit inputs: the goal statement,
  the resolved repository base revision, bounded constraints and non-goals,
  the goal acceptance contract, and explicit context evidence carried by
  reference and short summary. There is no transcript, no hidden reasoning,
  and no machine-specific path anywhere in it.

  Every text input is bounded and secret-scanned (`Shoestring.Harness.Contract.text/3`
  refuses credentials), and absolute home paths (`/Users/…`, `/home/…`) are
  refused outright: committed planner artifacts must never carry them.
  Context evidence is capped at 16 references of 300/500 characters, and the
  whole rendered prompt is capped at 16 384 bytes — oversized input fails, it
  is never truncated to fit.

  `input_digest/1` is the SHA-256 of the canonical rendering of the
  normalized inputs, including the semantic request identity (who asked,
  under which proposal id, against which parent, with which confirmation).
  It is the replay guard a request stores: the same request id with the
  same digest is the same request, while another initiator's identical
  bytes are a conflict, never a replay of someone else's attribution.
  """

  alias Shoestring.Cobbler.PlanGate
  alias Shoestring.Harness.Contract

  @max_context_refs 16
  @max_ref_length 300
  @max_summary_length 500
  @max_prompt_bytes 16_384
  @max_constraints 16
  @max_text_length 500

  @home_path_patterns ["/Users/", "/home/"]

  @type inputs :: %{
          required(:goal_statement) => String.t(),
          required(:base_revision) => String.t(),
          required(:planner_identity) => String.t(),
          required(:planner_version) => String.t(),
          required(:planner_model) => String.t(),
          optional(:remote_ref) => String.t() | nil,
          optional(:constraints) => [String.t()],
          optional(:non_goals) => [String.t()],
          optional(:acceptance) => map(),
          optional(:context_refs) => [%{ref: String.t(), summary: String.t()}],
          optional(:repair_errors) => [String.t()],
          optional(:requested_by) => String.t() | nil,
          optional(:proposal_id) => String.t() | nil,
          optional(:parent_revision_number) => pos_integer() | nil,
          optional(:confirmation) => map() | nil
        }

  @type prompt :: %{
          required(:goal) => map(),
          required(:context) => [map()],
          required(:instructions) => map(),
          required(:planner) => map()
        }

  @doc "Maximum rendered prompt size in bytes."
  @spec max_prompt_bytes() :: pos_integer()
  def max_prompt_bytes, do: @max_prompt_bytes

  @doc """
  Validates raw request inputs into normalized planning inputs.

  Returns `{:ok, inputs}` or `{:error, {:invalid_planner_request, field, message}}`.
  """
  @spec normalize(map()) :: {:ok, inputs()} | {:error, term()}
  def normalize(attrs) when is_map(attrs) do
    with {:ok, statement} <- statement(attrs),
         {:ok, repository} <- repository(attrs),
         {:ok, constraints} <- text_list(attrs, :constraints, @max_constraints),
         {:ok, non_goals} <- text_list(attrs, :non_goals, @max_constraints),
         {:ok, acceptance} <- acceptance(attrs),
         {:ok, context_refs} <- context_refs(attrs),
         {:ok, planner} <- planner_ref(attrs) do
      {:ok,
       %{
         goal_statement: statement,
         base_revision: repository.base_revision,
         remote_ref: repository.remote_ref,
         constraints: constraints,
         non_goals: non_goals,
         acceptance: acceptance,
         context_refs: context_refs,
         planner_identity: planner.identity,
         planner_version: planner.version,
         planner_model: planner.model,
         requested_by: identity_value(attrs, :requested_by),
         proposal_id: identity_value(attrs, :proposal_id),
         parent_revision_number: identity_value(attrs, :parent_revision_number),
         confirmation: identity_value(attrs, :confirmation)
       }}
    end
  end

  def normalize(_attrs), do: {:error, {:invalid_planner_request, :base, "must be an object"}}

  @doc """
  Builds the bounded, model-visible prompt from normalized inputs.

  The prompt carries references and summaries only. On success returns
  `{:ok, %{prompt: prompt, input_digest: digest}}`; oversized rendering
  fails instead of truncating.
  """
  @spec build(inputs(), keyword()) ::
          {:ok, %{prompt: prompt(), input_digest: String.t()}} | {:error, term()}
  def build(%{} = inputs, opts \\ []) do
    repair_errors =
      case Keyword.get(opts, :repair_errors, []) do
        errors when is_list(errors) -> Enum.take(errors, 8)
        _other -> []
      end

    prompt = %{
      "goal" => %{
        "statement" => inputs.goal_statement,
        "repository" =>
          maybe_put(%{"base_revision" => inputs.base_revision}, "remote_ref", inputs[:remote_ref]),
        "constraints" => Map.get(inputs, :constraints, []),
        "non_goals" => Map.get(inputs, :non_goals, []),
        "acceptance" => inputs.acceptance
      },
      "context" =>
        inputs
        |> Map.get(:context_refs, [])
        |> Enum.map(fn entry -> %{"ref" => entry.ref, "summary" => entry.summary} end),
      "instructions" => instructions(inputs, repair_errors),
      "planner" => %{
        "identity" => inputs.planner_identity,
        "version" => inputs.planner_version,
        "model" => inputs.planner_model
      }
    }

    rendered = encode_canonical(prompt)

    if byte_size(rendered) > @max_prompt_bytes do
      {:error,
       {:planner_prompt_too_large, %{bytes: byte_size(rendered), limit: @max_prompt_bytes}}}
    else
      {:ok, %{prompt: prompt, input_digest: digest_inputs(inputs)}}
    end
  end

  @doc """
  The SHA-256 digest over the canonical normalized inputs (without repair errors).

  Repair errors describe a transient model failure, not the request, so they
  are excluded: the digest identifies the request, not the attempt.
  """
  @spec digest_inputs(inputs()) :: String.t()
  def digest_inputs(inputs) do
    canonical = %{
      "acceptance" => inputs.acceptance,
      "base_revision" => inputs.base_revision,
      "confirmation" => inputs[:confirmation],
      "constraints" => Map.get(inputs, :constraints, []),
      "context_refs" =>
        inputs
        |> Map.get(:context_refs, [])
        |> Enum.map(&%{"ref" => &1.ref, "summary" => &1.summary}),
      "goal_statement" => inputs.goal_statement,
      "non_goals" => Map.get(inputs, :non_goals, []),
      "parent_revision_number" => inputs[:parent_revision_number],
      "planner_identity" => inputs.planner_identity,
      "planner_model" => inputs.planner_model,
      "planner_version" => inputs.planner_version,
      "proposal_id" => inputs[:proposal_id],
      "remote_ref" => inputs[:remote_ref],
      "requested_by" => inputs[:requested_by]
    }

    canonical |> encode_canonical() |> sha256()
  end

  # Minimal canonical JSON rendering (sorted object keys) for prompt
  # rendering and digests. `PlanContract.canonical_json/1` covers plan
  # content; prompts are not plans and stay out of that module.
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

  # ----------------------------------------------------------------------------
  # Input validation
  # ----------------------------------------------------------------------------

  defp statement(attrs) do
    case Contract.text(Contract.required(attrs, :goal_statement), :goal_statement, max: 2_000) do
      {:ok, text} -> home_path_free(text, :goal_statement)
      error -> planner_error(error, :goal_statement)
    end
  end

  defp repository(attrs) do
    case Contract.fetch(attrs, :repository) do
      {:ok, repository} when is_map(repository) ->
        with {:ok, base_revision} <- base_revision(repository),
             {:ok, remote_ref} <- remote_ref(repository) do
          {:ok, %{base_revision: base_revision, remote_ref: remote_ref}}
        end

      _other ->
        {:error, {:invalid_planner_request, :repository, "must be an object"}}
    end
  end

  # A plan is approved against one resolved commit, so the prompt carries a
  # resolved commit too: never a moving ref.
  defp base_revision(repository) do
    case Contract.required(repository, :base_revision) do
      {:ok, value} when is_binary(value) ->
        if Regex.match?(~r/\A[0-9a-f]{7,40}\z/, value) do
          {:ok, value}
        else
          {:error,
           {:invalid_planner_request, :base_revision,
            "must be a resolved hexadecimal git revision"}}
        end

      _other ->
        {:error, {:invalid_planner_request, :base_revision, "can't be blank"}}
    end
  end

  defp remote_ref(repository) do
    case Contract.optional(repository, :remote_ref) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.\/-]{0,199}\z/, value) and
             not String.contains?(value, "..") do
          home_path_free(value, :remote_ref)
        else
          {:error, {:invalid_planner_request, :remote_ref, "must be a simple ref name"}}
        end

      _other ->
        {:error, {:invalid_planner_request, :remote_ref, "must be a string"}}
    end
  end

  defp acceptance(attrs) do
    case Contract.fetch(attrs, :acceptance) do
      {:ok, acceptance} when is_map(acceptance) ->
        with {:ok, gates} <- acceptance_gates(acceptance),
             {:ok, evidence} <- required_text_list(acceptance, :evidence, 8) do
          {:ok, %{"gates" => gates, "evidence" => evidence}}
        end

      _other ->
        {:error, {:invalid_planner_request, :acceptance, "must be an object"}}
    end
  end

  defp acceptance_gates(acceptance) do
    case Contract.fetch(acceptance, :gates) do
      {:ok, gates} when is_list(gates) and length(gates) > 0 and length(gates) <= 4 ->
        gates
        |> Enum.reduce_while({:ok, []}, fn gate, {:ok, acc} ->
          case PlanGate.validate(gate, :acceptance_gates) do
            {:ok, normalized} ->
              {:cont, {:ok, [normalized | acc]}}

            {:error, _changeset} ->
              {:halt,
               {:error,
                {:invalid_planner_request, :acceptance_gates,
                 "must cite trusted acceptance gates"}}}
          end
        end)
        |> case do
          {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
          error -> error
        end

      _other ->
        {:error,
         {:invalid_planner_request, :acceptance_gates,
          "must cite at least one trusted acceptance gate"}}
    end
  end

  defp context_refs(attrs) do
    case Contract.optional(attrs, :context_refs) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, refs} when is_list(refs) ->
        cond do
          length(refs) > @max_context_refs ->
            {:error, {:invalid_planner_request, :context_refs, "contains too many entries"}}

          true ->
            refs
            |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
              case context_entry(entry) do
                {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
                error -> {:halt, error}
              end
            end)
            |> case do
              {:ok, entries} -> {:ok, Enum.reverse(entries)}
              error -> error
            end
        end

      _other ->
        {:error, {:invalid_planner_request, :context_refs, "must be a list"}}
    end
  end

  defp context_entry(entry) when is_map(entry) do
    with {:ok, ref} <-
           bounded_secret_free(Contract.fetch(entry, :ref), :context_ref, @max_ref_length),
         {:ok, summary} <-
           bounded_secret_free(
             Contract.fetch(entry, :summary),
             :context_summary,
             @max_summary_length
           ),
         {:ok, ref} <- home_path_free(ref, :context_ref),
         {:ok, summary} <- home_path_free(summary, :context_summary) do
      {:ok, %{ref: ref, summary: summary}}
    end
  end

  defp context_entry(_entry),
    do: {:error, {:invalid_planner_request, :context_refs, "entries must be objects"}}

  defp planner_ref(attrs) do
    case Contract.fetch(attrs, :planner) do
      {:ok, planner} when is_map(planner) ->
        with {:ok, identity} <-
               bounded_secret_free(Contract.fetch(planner, :identity), :planner_identity, 200),
             {:ok, version} <-
               bounded_secret_free(Contract.fetch(planner, :version), :planner_version, 64),
             {:ok, model} <-
               bounded_secret_free(Contract.fetch(planner, :model), :planner_model, 200) do
          {:ok, %{identity: identity, version: version, model: model}}
        end

      _other ->
        {:error, {:invalid_planner_request, :planner, "must be an object"}}
    end
  end

  defp text_list(attrs, key, max) do
    case Contract.optional(attrs, key) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, values} when is_list(values) and length(values) <= max ->
        values
        |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
          case bounded_secret_free({:ok, value}, key, @max_text_length) do
            {:ok, text} ->
              case home_path_free(text, key) do
                {:ok, clean} -> {:cont, {:ok, [clean | acc]}}
                error -> {:halt, error}
              end

            error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, texts} -> {:ok, Enum.reverse(texts)}
          error -> error
        end

      {:ok, _values} ->
        {:error, {:invalid_planner_request, key, "contains too many entries"}}

      _other ->
        {:error, {:invalid_planner_request, key, "must be a list"}}
    end
  end

  defp required_text_list(map, key, max) do
    case Contract.fetch(map, key) do
      {:ok, values} when is_list(values) and length(values) > 0 and length(values) <= max ->
        values
        |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
          case bounded_secret_free({:ok, value}, key, @max_text_length) do
            {:ok, text} ->
              case home_path_free(text, key) do
                {:ok, clean} -> {:cont, {:ok, [clean | acc]}}
                error -> {:halt, error}
              end

            error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, texts} -> {:ok, Enum.reverse(texts)}
          error -> error
        end

      _other ->
        {:error, {:invalid_planner_request, key, "must list at least one entry"}}
    end
  end

  defp bounded_secret_free(:error, field, _max),
    do: {:error, {:invalid_planner_request, field, "can't be blank"}}

  defp bounded_secret_free({:ok, value}, field, max) do
    case Contract.text(value, field, max: max) do
      {:ok, text} ->
        {:ok, text}

      {:error, _changeset} ->
        {:error, {:invalid_planner_request, field, "is not bounded secret-free text"}}
    end
  end

  defp home_path_free(text, field) do
    if Enum.any?(@home_path_patterns, &String.contains?(text, &1)) do
      {:error, {:invalid_planner_request, field, "must not contain absolute machine paths"}}
    else
      {:ok, text}
    end
  end

  defp planner_error({:error, _changeset}, field),
    do: {:error, {:invalid_planner_request, field, "is not bounded secret-free text"}}

  defp planner_error(other, _field), do: other

  # Semantic request identity travels into the digest (never into the
  # model-visible prompt, which `build/2` renders from explicit fields
  # only). These bindings are validated upstream by the orchestrator;
  # `normalize/1` carries them verbatim so the digest binds who asked,
  # under which proposal id, against which parent, and with which
  # confirmation.
  defp identity_value(attrs, key) do
    case Contract.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  # ----------------------------------------------------------------------------
  # Prompt instructions
  # ----------------------------------------------------------------------------

  defp instructions(inputs, repair_errors) do
    base = %{
      "response_format" => "Respond with a single JSON object and nothing else.",
      "schema" => %{
        "version" => 1,
        "required_keys" => ["goal", "budget", "tasks"],
        "task_required_keys" => [
          "id",
          "title",
          "outcome",
          "acceptance_criteria",
          "gates",
          "checkpoint",
          "execution"
        ]
      },
      "bounds" => %{
        "max_tasks" => 32,
        "max_dependencies_per_task" => 16,
        "execution" => "every task needs max_attempts (1..20) and max_duration_seconds",
        "gates" =>
          "every task and the goal must cite trusted gates: #{Enum.join(PlanGate.names(), ", ")}",
        "base_revision" => inputs.base_revision
      },
      "prohibitions" => [
        "no shell strings or command fields of any kind",
        "no reserve, quota, lifecycle, dispatch, lease, approval, or worktree directives",
        "no destructive integration steps",
        "no invented repository observations beyond the goal and context above",
        "model self-report is never acceptance"
      ],
      "planner_attribution" => %{
        "identity" => inputs.planner_identity,
        "version" => inputs.planner_version,
        "model" => inputs.planner_model,
        "rule" => "echo this attribution exactly in the plan planner block"
      }
    }

    if repair_errors == [] do
      base
    else
      Map.put(base, "repair", %{
        "attempt" => "final",
        "errors" => repair_errors,
        "rule" => "fix exactly the listed errors; do not change anything else"
      })
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp sha256(rendered), do: :crypto.hash(:sha256, rendered) |> Base.encode16(case: :lower)
end
