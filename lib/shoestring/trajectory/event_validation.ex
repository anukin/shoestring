defmodule Shoestring.Trajectory.EventValidation do
  @moduledoc "Shared validation callbacks for JSON payloads and idempotency keys."

  def validate_json_payload(:payload, payload) do
    if json_object?(payload) do
      []
    else
      [payload: "must be a JSON-compatible object"]
    end
  end

  def validate_idempotency_key(:idempotency_key, key) do
    if String.trim(key) == "" do
      [idempotency_key: "can't be blank when present"]
    else
      []
    end
  end

  defp json_object?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested_value} -> is_binary(key) and json_value?(nested_value) end)
  end

  defp json_object?(_value), do: false

  defp json_value?(nil), do: true
  defp json_value?(value) when is_boolean(value), do: true
  defp json_value?(value) when is_number(value), do: true
  defp json_value?(value) when is_binary(value), do: true
  defp json_value?(value) when is_list(value), do: json_list?(value)
  defp json_value?(value) when is_map(value), do: json_object?(value)
  defp json_value?(_value), do: false

  defp json_list?([]), do: true
  defp json_list?([head | tail]), do: json_value?(head) and json_list?(tail)
  defp json_list?(_value), do: false
end
