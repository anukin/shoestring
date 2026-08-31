defmodule Shoestring.Harness.RunRequest do
  @moduledoc "Versioned, vendor-neutral intent to execute one goal-scoped task."

  alias Shoestring.Harness.Contract

  @version 1
  @capabilities [:resume, :send, :cancel, :interactive]

  @enforce_keys [
    :version,
    :goal_id,
    :task_id,
    :workspace_ref,
    :prompt,
    :continuation,
    :policy,
    :requested_capabilities,
    :dispatch_id,
    :extensions
  ]
  defstruct [
    :version,
    :goal_id,
    :task_id,
    :workspace_ref,
    :prompt,
    :continuation,
    :policy,
    :requested_capabilities,
    :dispatch_id,
    :extensions
  ]

  @type continuation ::
          nil
          | %{
              checkpoint_id: Ecto.UUID.t(),
              next_action: String.t(),
              decision_refs: [Ecto.UUID.t()]
            }

  @type t :: %__MODULE__{
          version: 1,
          goal_id: Ecto.UUID.t(),
          task_id: Ecto.UUID.t(),
          workspace_ref: String.t(),
          prompt: String.t(),
          continuation: continuation(),
          policy: map(),
          requested_capabilities: [atom()],
          dispatch_id: Ecto.UUID.t(),
          extensions: map()
        }

  @spec version() :: 1
  def version, do: @version

  @spec capabilities() :: [atom()]
  def capabilities, do: @capabilities

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, version} <- Contract.version(attrs, @version),
         {:ok, goal_id} <- attrs |> Contract.required(:goal_id) |> then(&cast_uuid(&1, :goal_id)),
         {:ok, task_id} <- attrs |> Contract.required(:task_id) |> then(&cast_uuid(&1, :task_id)),
         {:ok, workspace_ref} <-
           attrs |> Contract.required(:workspace_ref) |> then(&workspace_ref/1),
         {:ok, prompt} <-
           attrs |> Contract.required(:prompt) |> then(&Contract.text(&1, :prompt, max: 12_000)),
         {:ok, continuation} <- attrs |> Contract.optional(:continuation) |> then(&continuation/1),
         {:ok, policy} <- attrs |> Contract.required(:policy) |> then(&policy/1),
         {:ok, requested_capabilities} <-
           attrs |> Contract.required(:requested_capabilities) |> then(&requested_capabilities/1),
         {:ok, dispatch_id} <-
           attrs |> Contract.required(:dispatch_id) |> then(&cast_uuid(&1, :dispatch_id)),
         {:ok, extensions} <-
           attrs |> Contract.optional(:extensions) |> then(&Contract.extensions/1) do
      {:ok,
       %__MODULE__{
         version: version,
         goal_id: goal_id,
         task_id: task_id,
         workspace_ref: workspace_ref,
         prompt: prompt,
         continuation: continuation,
         policy: policy,
         requested_capabilities: requested_capabilities,
         dispatch_id: dispatch_id,
         extensions: extensions
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:base, "must be an object")

  @spec continuation_projection(t()) :: map() | nil
  def continuation_projection(%__MODULE__{continuation: continuation}), do: continuation

  defp cast_uuid({:ok, value}, field), do: Contract.uuid(value, field)
  defp cast_uuid(error, _field), do: error

  defp workspace_ref({:ok, value}) do
    with {:ok, value} <- Contract.text(value, :workspace_ref, max: 500),
         true <- Path.type(value) != :absolute and ".." not in Path.split(value) do
      {:ok, value}
    else
      false -> Contract.invalid(:workspace_ref, "must be a safe relative reference")
      error -> error
    end
  end

  defp workspace_ref(error), do: error

  defp continuation(nil), do: {:ok, nil}
  defp continuation({:ok, value}), do: continuation(value)

  defp continuation(value) when is_map(value) do
    allowed = ["checkpoint_id", "next_action", "decision_refs"]

    with true <- Enum.all?(Map.keys(value), &(to_string(&1) in allowed)),
         {:ok, checkpoint_id} <-
           value |> Contract.required(:checkpoint_id) |> then(&cast_uuid(&1, :checkpoint_id)),
         {:ok, next_action} <-
           value
           |> Contract.required(:next_action)
           |> then(&Contract.text(&1, :next_action, max: 2_000)),
         {:ok, decision_refs} <-
           value |> Contract.optional(:decision_refs) |> then(&decision_refs/1) do
      {:ok,
       %{checkpoint_id: checkpoint_id, next_action: next_action, decision_refs: decision_refs}}
    else
      false -> Contract.invalid(:continuation, "contains unsupported fields")
      error -> error
    end
  end

  defp continuation(_value), do: Contract.invalid(:continuation, "must be an object or nil")

  defp decision_refs(nil), do: {:ok, []}
  defp decision_refs({:ok, value}), do: decision_refs(value)

  defp decision_refs(value) do
    with {:ok, values} <- Contract.list(value, :decision_refs, max: 32) do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case Contract.uuid(value, :decision_refs) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, refs} -> {:ok, Enum.reverse(refs)}
        error -> error
      end
    end
  end

  defp policy(value) when is_map(value) do
    allowed = ["mode", "network", "write_access"]

    with true <- Enum.all?(Map.keys(value), &(to_string(&1) in allowed)),
         {:ok, mode} <-
           value
           |> Contract.required(:mode)
           |> then(&Contract.enum(&1, :policy_mode, ["supervised", "autonomous"])),
         {:ok, network} <-
           value |> Contract.optional(:network) |> then(&policy_boolean(&1, :network, false)),
         {:ok, write_access} <-
           value
           |> Contract.optional(:write_access)
           |> then(&policy_boolean(&1, :write_access, false)) do
      {:ok, %{mode: mode, network: network, write_access: write_access}}
    else
      false -> Contract.invalid(:policy, "contains unsupported fields")
      error -> error
    end
  end

  defp policy({:ok, value}), do: policy(value)

  defp policy(_value), do: Contract.invalid(:policy, "must be an object")

  defp policy_boolean(nil, _field, default), do: {:ok, default}
  defp policy_boolean({:ok, value}, field, default), do: policy_boolean(value, field, default)
  defp policy_boolean(value, _field, _default) when is_boolean(value), do: {:ok, value}
  defp policy_boolean(_value, field, _default), do: Contract.invalid(field, "must be a boolean")

  defp requested_capabilities({:ok, value}), do: requested_capabilities(value)

  defp requested_capabilities(value) do
    with {:ok, values} <- Contract.list(value, :requested_capabilities, max: 8),
         true <- Enum.all?(values, &(&1 in @capabilities)) do
      {:ok, Enum.uniq(values)}
    else
      false -> Contract.invalid(:requested_capabilities, "contains an unsupported capability")
      error -> error
    end
  end
end
