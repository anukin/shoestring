defmodule Shoestring.Trajectory.TrustedEventReferences do
  @moduledoc """
  Explicit trusted relationship fields for the trajectory append boundary.

  These fields are supplied by domain code through append options, not by the
  untrusted `AppendInput` attributes. Event identity and sequence remain the
  writer's responsibility.
  """

  @allowed_fields [:task_id, :run_id, :parent_event_id]

  defstruct @allowed_fields

  @doc "Casts the explicitly trusted relationship options without atomizing keys."
  @spec cast(map() | keyword() | nil) ::
          {:ok, t()}
          | {:error, {:invalid_trusted_references, term()}}
          | {:error, {:invalid_trusted_reference, atom()}}
  def cast(nil), do: {:ok, %__MODULE__{}}

  def cast(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      cast(Map.new(attrs))
    else
      {:error, {:invalid_trusted_references, "must be a map or keyword list"}}
    end
  end

  def cast(attrs) when is_map(attrs) do
    unknown_fields = Map.keys(attrs) -- @allowed_fields

    if unknown_fields == [] do
      with {:ok, task_id} <- cast_uuid(Map.get(attrs, :task_id), :task_id),
           {:ok, run_id} <- cast_uuid(Map.get(attrs, :run_id), :run_id),
           {:ok, parent_event_id} <- cast_uuid(Map.get(attrs, :parent_event_id), :parent_event_id) do
        {:ok,
         %__MODULE__{
           task_id: task_id,
           run_id: run_id,
           parent_event_id: parent_event_id
         }}
      end
    else
      {:error, {:invalid_trusted_references, unknown_fields}}
    end
  end

  def cast(_attrs), do: {:error, {:invalid_trusted_references, "must be a map or keyword list"}}

  defp cast_uuid(nil, _field), do: {:ok, nil}

  defp cast_uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_trusted_reference, field}}
    end
  end

  @type t :: %__MODULE__{}
end
