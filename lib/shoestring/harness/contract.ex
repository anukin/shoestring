defmodule Shoestring.Harness.Contract do
  @moduledoc false

  import Ecto.Changeset

  alias Shoestring.Harness.Security

  @type result(value) :: {:ok, value} | {:error, Ecto.Changeset.t()}

  def fetch(attrs, key) when is_map(attrs) and is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  def fetch(attrs, key) when is_map(attrs) and is_binary(key),
    do: Map.fetch(attrs, key)

  def fetch(_attrs, _key), do: :error

  def required(attrs, key) do
    case fetch(attrs, key) do
      {:ok, nil} -> invalid(key, "can't be blank")
      {:ok, ""} -> invalid(key, "can't be blank")
      {:ok, value} -> {:ok, value}
      :error -> invalid(key, "can't be blank")
    end
  end

  def optional(attrs, key) do
    case fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, nil}
    end
  end

  def version(attrs, expected) do
    case required(attrs, :version) do
      {:ok, ^expected} -> {:ok, expected}
      {:ok, _value} -> invalid(:version, "must equal #{expected}")
      error -> error
    end
  end

  def uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> invalid(field, "must be a UUID")
    end
  end

  def text(value, field, opts \\ [])

  def text({:ok, value}, field, opts), do: text(value, field, opts)

  def text(value, field, opts) when is_binary(value) do
    min = Keyword.get(opts, :min, 1)
    max = Keyword.get(opts, :max, 2_000)

    cond do
      String.length(String.trim(value)) < min -> invalid(field, "is too short")
      String.length(value) > max -> invalid(field, "is too long")
      secret?(value) -> invalid(field, "must not contain secrets")
      true -> {:ok, value}
    end
  end

  def text(_value, field, _opts), do: invalid(field, "must be a string")

  def enum({:ok, value}, field, allowed), do: enum(value, field, allowed)

  def enum(value, field, allowed) do
    if value in allowed do
      {:ok, value}
    else
      invalid(field, "must be one of #{Enum.map_join(allowed, ", ", &to_string/1)}")
    end
  end

  def positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  def positive_integer({:ok, value}, field), do: positive_integer(value, field)
  def positive_integer(_value, field), do: invalid(field, "must be a positive integer")

  def nonnegative_integer(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}
  def nonnegative_integer({:ok, value}, field), do: nonnegative_integer(value, field)
  def nonnegative_integer(_value, field), do: invalid(field, "must be a non-negative integer")

  def percentage(value, _field) when is_number(value) and value >= 0 and value <= 100,
    do: {:ok, value}

  def percentage({:ok, value}, field), do: percentage(value, field)

  def percentage(_value, field), do: invalid(field, "must be between 0 and 100")

  def datetime(%DateTime{} = value, _field), do: {:ok, DateTime.truncate(value, :microsecond)}
  def datetime({:ok, value}, field), do: datetime(value, field)

  def datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _error -> invalid(field, "must be an ISO8601 datetime")
    end
  end

  def datetime(_value, field), do: invalid(field, "must be a datetime")

  def list(value, field, opts \\ [])

  def list({:ok, value}, field, opts), do: list(value, field, opts)

  def list(value, field, opts) when is_list(value) do
    max = Keyword.get(opts, :max, 32)

    if length(value) <= max do
      {:ok, value}
    else
      invalid(field, "contains too many entries")
    end
  end

  def list(_value, field, _opts), do: invalid(field, "must be a list")

  def map(value, field, opts \\ [])

  def map({:ok, value}, field, opts), do: map(value, field, opts)

  def map(value, field, opts) when is_map(value) do
    max = Keyword.get(opts, :max, 16)

    cond do
      map_size(value) > max -> invalid(field, "contains too many fields")
      not safe_term?(value) -> invalid(field, "must not contain secrets or raw transcripts")
      true -> {:ok, value}
    end
  end

  def map(_value, field, _opts), do: invalid(field, "must be an object")

  @forbidden_content_keys ~w(
    transcript raw_transcript raw_output stdout stderr prompt_messages messages
    model_response response_text completion_text
  )

  @doc "Provider extensions are bounded, namespaced, JSON-safe, and secret-free."
  def extensions(nil), do: {:ok, %{}}
  def extensions({:ok, value}), do: extensions(value)

  def extensions(value) when is_map(value) do
    cond do
      map_size(value) > 16 ->
        invalid(:extensions, "contains too many entries")

      Enum.any?(value, fn {key, _value} -> not namespaced_extension_key?(key) end) ->
        invalid(:extensions, "keys must be namespaced")

      Enum.any?(value, fn {key, _value} ->
        extension_content_key(key) in @forbidden_content_keys
      end) ->
        invalid(:extensions, "must not contain secrets or raw transcripts")

      not safe_term?(value) ->
        invalid(:extensions, "must not contain secrets or raw transcripts")

      true ->
        {:ok, value}
    end
  end

  def extensions(_value), do: invalid(:extensions, "must be an object")

  def safe_term?(term), do: safe_term?(term, 0)

  def invalid(field, message) do
    {:error, change({%{}, %{}}) |> add_error(field, message)}
  end

  def invalid(changeset, field, message) do
    {:error, add_error(changeset, field, message)}
  end

  defp safe_term?(_term, depth) when depth > 4, do: false

  defp safe_term?(%DateTime{}, _depth), do: true

  defp safe_term?(value, _depth) when is_nil(value) or is_boolean(value) or is_number(value),
    do: true

  defp safe_term?(value, _depth) when is_binary(value), do: not secret?(value)

  defp safe_term?(value, depth) when is_list(value),
    do: length(value) <= 64 and Enum.all?(value, &safe_term?(&1, depth + 1))

  defp safe_term?(value, depth) when is_map(value) do
    map_size(value) <= 32 and
      Enum.all?(value, fn {key, nested_value} ->
        key_string = safe_key_string(key)

        is_binary(key_string) and key_string not in @forbidden_content_keys and
          safe_term?(nested_value, depth + 1)
      end)
  end

  defp safe_term?(_value, _depth), do: false

  defp namespaced_extension_key?(key) when is_binary(key),
    do: key =~ ~r/\A[a-z0-9][a-z0-9.-]{0,62}:[A-Za-z0-9_.-]{1,63}\z/

  defp namespaced_extension_key?(_key), do: false

  defp extension_content_key(key) when is_binary(key) do
    key |> String.split(":", parts: 2) |> List.last()
  end

  defp extension_content_key(_key), do: nil

  defp safe_key_string(key) when is_binary(key), do: key
  defp safe_key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp safe_key_string(_key), do: nil

  defp secret?(value), do: Security.secret_value?(value)
end
