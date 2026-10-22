defmodule Shoestring.Harness.OllamaLocal do
  @moduledoc "Optional pinned local one-shot text adapter. Compute, context and user time remain bounded resources."
  @behaviour Shoestring.Harness.Adapter
  alias Shoestring.Harness.{HTTP, Identity, Error}

  def identity,
    do: %Identity{
      adapter_id: "ollama_local",
      provider: "ollama",
      adapter_version: "1.0.0",
      schema_version: 1,
      invocation_mode: :api
    }

  def capabilities, do: MapSet.new([:cancel])
  def start(request, opts), do: HTTP.start("ollama_local", request, opts)
  def stream(identity, _), do: HTTP.stream(identity)
  def status(identity, _), do: HTTP.status(identity)
  def cancel(identity, _), do: HTTP.cancel(identity)
  def release(identity), do: HTTP.release(identity)

  def probe(_),
    do:
      {:error,
       Error.new(
         :unsupported_capability,
         "local_has_no_subscription_capacity",
         "Local compute and context are not subscription quota or free unlimited capacity."
       )}
end
