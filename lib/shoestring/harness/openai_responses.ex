defmodule Shoestring.Harness.OpenAIResponses do
  @moduledoc "Optional capped one-shot text Responses adapter. No tools, resume or interactive channel."
  @behaviour Shoestring.Harness.Adapter
  alias Shoestring.Harness.{HTTP, Identity, Error}

  def identity,
    do: %Identity{
      adapter_id: "openai_responses",
      provider: "openai",
      adapter_version: "1.0.0",
      schema_version: 1,
      invocation_mode: :api
    }

  def capabilities, do: MapSet.new([:cancel])
  def start(request, opts), do: HTTP.start("openai_responses", request, opts)
  def stream(identity, _), do: HTTP.stream(identity)
  def status(identity, _), do: HTTP.status(identity)
  def cancel(identity, _), do: HTTP.cancel(identity)
  def release(identity), do: HTTP.release(identity)

  def probe(_) do
    {:error,
     Error.new(
       :quota_refused,
       "api_requires_spend_authorization",
       "Dispatch requires a fresh deterministic spend reservation; no subscription percentage is inferred."
     )}
  end
end
