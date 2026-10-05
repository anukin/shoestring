defmodule Shoestring.Cobbler.Planner.Adapter do
  @moduledoc """
  Tool-free, single-call structured inference boundary. No adapter receives a
  repo, socket, worktree or lifecycle API. Output is untrusted until validated.
  Output tokens are measured when available; the full allowance is charged
  before invocation even on an error or lost result.
  """
  @callback generate(map(), keyword()) ::
              {:ok, %{json: binary(), output_tokens: non_neg_integer()}}
              | {:error, atom()}
end
