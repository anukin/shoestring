defmodule Shoestring.Harness.Error do
  @moduledoc "Typed, normalized failures at the harness boundary."

  # `:transport` covers failures at the adapter boundary, including a local
  # provider process exit; it intentionally does not describe task failure.
  @categories [
    :transport,
    :schema_incompatible,
    :authentication_required,
    :quota_refused,
    :cancelled,
    :task_failed,
    :invalid_transition,
    :unsupported_capability
  ]

  @enforce_keys [:category, :code, :message]
  defstruct [:category, :code, :message, :retryable, details: %{}]

  @type category ::
          :transport
          | :schema_incompatible
          | :authentication_required
          | :quota_refused
          | :cancelled
          | :task_failed
          | :invalid_transition
          | :unsupported_capability

  @type t :: %__MODULE__{
          category: category(),
          code: String.t(),
          message: String.t(),
          retryable: boolean() | nil,
          details: map()
        }

  @spec categories() :: [category()]
  def categories, do: @categories

  @spec new(category(), String.t(), String.t(), keyword()) :: t()
  def new(category, code, message, opts \\ []) when category in @categories do
    %__MODULE__{
      category: category,
      code: code,
      message: message,
      retryable: Keyword.get(opts, :retryable, false),
      details: Keyword.get(opts, :details, %{})
    }
  end
end
