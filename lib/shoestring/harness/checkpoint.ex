defmodule Shoestring.Harness.Checkpoint do
  @moduledoc "A minimum viable, model-summary-free continuation checkpoint."

  alias Shoestring.Harness.Contract

  @version 1

  @enforce_keys [
    :version,
    :checkpoint_id,
    :goal_id,
    :run_id,
    :acceptance_contract,
    :repository_state,
    :evidence,
    :decisions,
    :unresolved_issues,
    :next_action,
    :provider_session_id,
    :stop_reason,
    :artifact_ids,
    :extensions
  ]
  defstruct [
    :version,
    :checkpoint_id,
    :goal_id,
    :run_id,
    :acceptance_contract,
    :repository_state,
    :evidence,
    :decisions,
    :unresolved_issues,
    :next_action,
    :provider_session_id,
    :stop_reason,
    :artifact_ids,
    :extensions
  ]

  @type t :: %__MODULE__{
          version: 1,
          checkpoint_id: Ecto.UUID.t(),
          goal_id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t(),
          acceptance_contract: %{criteria: [String.t()]},
          repository_state: %{revision: String.t(), dirty: boolean()},
          evidence: [String.t()],
          decisions: [String.t()],
          unresolved_issues: [String.t()],
          next_action: String.t(),
          provider_session_id: String.t() | nil,
          stop_reason: String.t(),
          artifact_ids: [Ecto.UUID.t()],
          extensions: map()
        }

  @spec version() :: 1
  def version, do: @version

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, version} <- Contract.version(attrs, @version),
         {:ok, checkpoint_id} <-
           attrs |> Contract.required(:checkpoint_id) |> then(&uuid_result(&1, :checkpoint_id)),
         {:ok, goal_id} <-
           attrs |> Contract.required(:goal_id) |> then(&uuid_result(&1, :goal_id)),
         {:ok, run_id} <- attrs |> Contract.required(:run_id) |> then(&uuid_result(&1, :run_id)),
         {:ok, acceptance_contract} <-
           attrs |> Contract.required(:acceptance_contract) |> then(&acceptance_contract/1),
         {:ok, repository_state} <-
           attrs |> Contract.required(:repository_state) |> then(&repository_state/1),
         {:ok, evidence} <-
           attrs |> Contract.required(:evidence) |> then(&text_list(&1, :evidence)),
         {:ok, decisions} <-
           attrs |> Contract.required(:decisions) |> then(&text_list(&1, :decisions)),
         {:ok, unresolved_issues} <-
           attrs
           |> Contract.required(:unresolved_issues)
           |> then(&text_list(&1, :unresolved_issues)),
         {:ok, next_action} <-
           attrs
           |> Contract.required(:next_action)
           |> then(&Contract.text(&1, :next_action, max: 2_000)),
         {:ok, provider_session_id} <-
           attrs
           |> Contract.optional(:provider_session_id)
           |> then(&optional_text(&1, :provider_session_id)),
         {:ok, stop_reason} <-
           attrs
           |> Contract.required(:stop_reason)
           |> then(&Contract.text(&1, :stop_reason, max: 300)),
         {:ok, artifact_ids} <-
           attrs |> Contract.optional(:artifact_ids) |> then(&uuid_list(&1, :artifact_ids)),
         {:ok, extensions} <-
           attrs |> Contract.optional(:extensions) |> then(&Contract.extensions/1) do
      {:ok,
       %__MODULE__{
         version: version,
         checkpoint_id: checkpoint_id,
         goal_id: goal_id,
         run_id: run_id,
         acceptance_contract: acceptance_contract,
         repository_state: repository_state,
         evidence: evidence,
         decisions: decisions,
         unresolved_issues: unresolved_issues,
         next_action: next_action,
         provider_session_id: provider_session_id,
         stop_reason: stop_reason,
         artifact_ids: artifact_ids,
         extensions: extensions
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:base, "must be an object")

  defp uuid_result({:ok, value}, field), do: Contract.uuid(value, field)
  defp uuid_result(error, _field), do: error
  defp optional_text(nil, _field), do: {:ok, nil}
  defp optional_text({:ok, value}, field), do: optional_text(value, field)
  defp optional_text(value, field), do: Contract.text(value, field, max: 500)

  defp acceptance_contract(value) when is_map(value) do
    with {:ok, criteria} <-
           value |> Contract.required(:criteria) |> then(&text_list(&1, :acceptance_criteria)),
         true <- criteria != [],
         true <- Enum.all?(Map.keys(value), &(to_string(&1) == "criteria")) do
      {:ok, %{criteria: criteria}}
    else
      false -> Contract.invalid(:acceptance_contract, "must contain only non-empty criteria")
      error -> error
    end
  end

  defp acceptance_contract({:ok, value}), do: acceptance_contract(value)

  defp acceptance_contract(_value),
    do: Contract.invalid(:acceptance_contract, "must be an object")

  defp repository_state(value) when is_map(value) do
    with {:ok, revision} <-
           value
           |> Contract.required(:revision)
           |> then(&Contract.text(&1, :repository_revision, max: 300)),
         {:ok, dirty} <- value |> Contract.required(:dirty) |> then(&repository_dirty/1),
         true <- Enum.all?(Map.keys(value), &(to_string(&1) in ["revision", "dirty"])) do
      {:ok, %{revision: revision, dirty: dirty}}
    else
      false -> Contract.invalid(:repository_state, "contains unsupported fields")
      error -> error
    end
  end

  defp repository_state({:ok, value}), do: repository_state(value)

  defp repository_state(_value), do: Contract.invalid(:repository_state, "must be an object")

  defp repository_dirty({:ok, value}), do: repository_dirty(value)
  defp repository_dirty(value) when is_boolean(value), do: {:ok, value}
  defp repository_dirty(_value), do: Contract.invalid(:repository_dirty, "must be a boolean")

  defp text_list({:ok, value}, field), do: text_list(value, field)

  defp text_list(value, field) do
    with {:ok, values} <- Contract.list(value, field, max: 32) do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case Contract.text(value, field, max: 2_000) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end
    end
  end

  defp uuid_list(nil, _field), do: {:ok, []}
  defp uuid_list({:ok, value}, field), do: uuid_list(value, field)

  defp uuid_list(value, field) do
    with {:ok, values} <- Contract.list(value, field, max: 32) do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case Contract.uuid(value, field) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end
    end
  end
end
