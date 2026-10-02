defmodule Shoestring.Cobbler.PlannerAdapter do
  @moduledoc """
  Behaviour for bounded planner inference.

  An adapter receives the bounded prompt built by
  `Shoestring.Cobbler.PlannerPrompt` and returns the model's structured
  proposal. The contract is strict on both sides:

  - the prompt is a plain string-keyed map, already bounded and secret-free;
  - success is `{:ok, map()}` with the decoded structured plan object —
    never a raw string, never a transcript;
  - failure is `{:error, reason}` where `reason` is one of:
    - `{:transport, detail}` — the model was never reached or never
      answered (network, timeout, non-2xx, authentication). Terminal: the
      orchestrator never repairs a transport failure.
    - `{:invalid_response, detail}` — the model answered but the payload
      was not a JSON object. Handled like a schema failure: one bounded
      repair, then the manual path.
    - `{:refused, detail}` — the model declined to plan. Accounted like a
      transport failure: terminal, with the refusal recorded.

  `detail` must be a small string-keyed map with bounded, redacted values;
  adapters never return raw provider payloads, credentials, or absolute
  machine paths. Adapters perform no persistence, no admission, and no
  approval: the orchestrator admits every invocation before calling, and
  validates every output before persisting anything.

  `identity/0` reports `%{identity: ..., version: ..., model: ...}`. The
  orchestrator requires a proposed plan's planner block to echo exactly
  this attribution, so a stored revision always says which planner produced
  it.
  """

  @type prompt :: map()
  @type plan :: map()
  @type detail :: map()

  @doc "Static attribution for this adapter."
  @callback identity() :: %{identity: String.t(), version: String.t(), model: String.t()}

  @doc "Runs one bounded planning inference against the prompt."
  @callback plan(prompt(), keyword()) ::
              {:ok, plan()} | {:error, {:transport | :invalid_response | :refused, detail()}}
end
