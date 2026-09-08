defmodule Shoestring.Harness.CheckpointFallback do
  @moduledoc """
  Deterministic no-model checkpoint template (Milestone 05, work package D).

  When a sleeping goal must record checkpoint contents without invoking a
  model (deferral at the safe boundary, wake-time expiry), this pure template
  builds a `Shoestring.Harness.Checkpoint` from durable-state inputs only.
  It never calls an adapter, never reads the network, and never interpolates
  provider output: there is no transcript/raw-output input field, and the
  only synthesized text is the deterministic `next_action` template below.

  Truncation budgets with hard-fail on overflow: every budget mirrors the
  `Checkpoint` contract limits. An input over budget returns
  `{:error, {:checkpoint_overflow, %{field: field, limit: limit, actual: actual}}}`
  and nothing is truncated silently.

  Provenance: caller extensions are validated through
  `Shoestring.Harness.Contract.extensions/1` and then merged with the forced
  provenance entry `"shoestring:synthesized_without_model" =>
  "checkpoint-fallback-v1"`. A caller-supplied value under that key is
  overwritten, never honored.
  """

  alias Shoestring.Harness.{Checkpoint, Contract}

  @provenance_key "shoestring:synthesized_without_model"
  @provenance_value "checkpoint-fallback-v1"

  @list_budget 32
  @text_budget 2_000
  @stop_reason_budget 300
  @revision_budget 300
  @session_budget 500
  @artifact_budget 32

  @doc "The provenance extensions key marking a fallback-synthesized checkpoint."
  @spec provenance_key() :: String.t()
  def provenance_key, do: @provenance_key

  @doc "The provenance extensions value for fallback-synthesized checkpoints."
  @spec provenance_value() :: String.t()
  def provenance_value, do: @provenance_value

  @doc """
  Builds a `Checkpoint` from durable-state inputs (pure, zero adapter calls).

  Required inputs: `:checkpoint_id`, `:goal_id`, `:run_id`,
  `:acceptance_criteria` (non-empty list of strings),
  `:repository_revision` (string).

  Optional inputs: `:repository_dirty` (default `false`),
  `:evidence` / `:decisions` / `:unresolved_issues` (default `[]`),
  `:next_action` (default: the deterministic resume template),
  `:stop_reason` (default `"deferred"`), `:provider_session_id` (default
  `nil`), `:artifact_ids` (default `[]`), `:extensions` (default `%{}`).

  Returns `{:ok, Checkpoint.t()}`, `{:error, Ecto.Changeset.t()}` for
  contract violations, or `{:error, {:checkpoint_overflow, detail}}` when an
  input exceeds its truncation budget.
  """
  @spec build(map()) :: {:ok, Checkpoint.t()} | {:error, term()}
  def build(inputs) when is_map(inputs) do
    with {:ok, checkpoint_id} <- uuid(inputs, :checkpoint_id),
         {:ok, goal_id} <- uuid(inputs, :goal_id),
         {:ok, run_id} <- uuid(inputs, :run_id),
         {:ok, criteria} <- text_list(inputs, :acceptance_criteria, nonempty: true),
         {:ok, revision} <- bounded_text(inputs, :repository_revision, @revision_budget),
         {:ok, dirty} <- dirty(inputs),
         {:ok, evidence} <- text_list(inputs, :evidence),
         {:ok, decisions} <- text_list(inputs, :decisions),
         {:ok, unresolved} <- text_list(inputs, :unresolved_issues),
         {:ok, stop_reason} <- stop_reason(inputs),
         {:ok, next_action} <-
           next_action(inputs, run_id, goal_id, checkpoint_id, stop_reason, revision),
         {:ok, session_id} <- session_id(inputs),
         {:ok, artifact_ids} <- artifact_ids(inputs),
         {:ok, extensions} <- extensions(inputs) do
      Checkpoint.new(%{
        version: Checkpoint.version(),
        checkpoint_id: checkpoint_id,
        goal_id: goal_id,
        run_id: run_id,
        acceptance_contract: %{criteria: criteria},
        repository_state: %{revision: revision, dirty: dirty},
        evidence: evidence,
        decisions: decisions,
        unresolved_issues: unresolved,
        next_action: next_action,
        provider_session_id: session_id,
        stop_reason: stop_reason,
        artifact_ids: artifact_ids,
        extensions: extensions
      })
    end
  end

  def build(_inputs), do: Contract.invalid(:base, "must be an object")

  defp uuid(inputs, field) do
    case Contract.fetch(inputs, field) do
      {:ok, value} -> Contract.uuid(value, field)
      :error -> Contract.invalid(field, "can't be blank")
    end
  end

  defp bounded_text(inputs, field, max) do
    case Contract.fetch(inputs, field) do
      {:ok, value} when is_binary(value) ->
        if String.length(value) <= max do
          Contract.text(value, field, max: max)
        else
          overflow(field, max, String.length(value))
        end

      {:ok, _other} ->
        Contract.invalid(field, "must be a string")

      :error ->
        Contract.invalid(field, "can't be blank")
    end
  end

  defp text_list(inputs, field, opts \\ []) do
    case Contract.fetch(inputs, field) do
      :error when opts == [] ->
        {:ok, []}

      :error ->
        Contract.invalid(field, "can't be blank")

      {:ok, value} when is_list(value) ->
        cond do
          opts[:nonempty] == true and value == [] ->
            Contract.invalid(field, "must contain at least one criterion")

          length(value) > @list_budget ->
            overflow(field, @list_budget, length(value))

          true ->
            bounded_texts(value, field)
        end

      {:ok, _other} ->
        Contract.invalid(field, "must be a list")
    end
  end

  defp bounded_texts(values, field) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      cond do
        not is_binary(value) ->
          {:halt, Contract.invalid(field, "must be a list of strings")}

        String.length(value) > @text_budget ->
          {:halt, overflow(field, @text_budget, String.length(value))}

        true ->
          case Contract.text(value, field, max: @text_budget) do
            {:ok, text} -> {:cont, {:ok, [text | acc]}}
            error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp dirty(inputs) do
    case Contract.fetch(inputs, :repository_dirty) do
      :error -> {:ok, false}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _other} -> Contract.invalid(:repository_dirty, "must be a boolean")
    end
  end

  defp stop_reason(inputs) do
    case Contract.fetch(inputs, :stop_reason) do
      :error ->
        {:ok, "deferred"}

      {:ok, value} when is_binary(value) ->
        if String.length(value) <= @stop_reason_budget do
          Contract.text(value, :stop_reason, max: @stop_reason_budget)
        else
          overflow(:stop_reason, @stop_reason_budget, String.length(value))
        end

      {:ok, _other} ->
        Contract.invalid(:stop_reason, "must be a string")
    end
  end

  defp next_action(inputs, run_id, goal_id, checkpoint_id, stop_reason, revision) do
    case Contract.fetch(inputs, :next_action) do
      :error ->
        {:ok,
         "Resume run #{run_id} for goal #{goal_id} after #{stop_reason}: " <>
           "re-observe capacity, re-evaluate admission, then continue from " <>
           "revision #{revision} (checkpoint #{checkpoint_id})."}

      {:ok, value} when is_binary(value) ->
        if String.length(value) <= @text_budget do
          Contract.text(value, :next_action, max: @text_budget)
        else
          overflow(:next_action, @text_budget, String.length(value))
        end

      {:ok, _other} ->
        Contract.invalid(:next_action, "must be a string")
    end
  end

  defp session_id(inputs) do
    case Contract.fetch(inputs, :provider_session_id) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        if String.length(value) <= @session_budget do
          Contract.text(value, :provider_session_id, max: @session_budget)
        else
          overflow(:provider_session_id, @session_budget, String.length(value))
        end

      {:ok, _other} ->
        Contract.invalid(:provider_session_id, "must be a string")
    end
  end

  defp artifact_ids(inputs) do
    case Contract.fetch(inputs, :artifact_ids) do
      :error ->
        {:ok, []}

      {:ok, value} when is_list(value) ->
        if length(value) > @artifact_budget do
          overflow(:artifact_ids, @artifact_budget, length(value))
        else
          Enum.reduce_while(value, {:ok, []}, fn id, {:ok, acc} ->
            case Contract.uuid(id, :artifact_ids) do
              {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
              error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, ids} -> {:ok, Enum.reverse(ids)}
            error -> error
          end
        end

      {:ok, _other} ->
        Contract.invalid(:artifact_ids, "must be a list")
    end
  end

  defp extensions(inputs) do
    case Contract.fetch(inputs, :extensions) do
      :error -> {:ok, %{}}
      {:ok, nil} -> {:ok, %{}}
      {:ok, value} when is_map(value) -> Contract.extensions(value)
      {:ok, _other} -> Contract.invalid(:extensions, "must be an object")
    end
    |> case do
      {:ok, validated} -> {:ok, Map.put(validated, @provenance_key, @provenance_value)}
      error -> error
    end
  end

  defp overflow(field, limit, actual) do
    {:error, {:checkpoint_overflow, %{field: field, limit: limit, actual: actual}}}
  end
end
