defmodule Shoestring.Dispatches.Explore.Adapter do
  @moduledoc """
  One read-only EXPLORE call. `input` carries `"prompt"`, `"schema"`,
  `"model"`, `"effort"` (or nil), `"workdir"` (a private copy of the
  repository), `"max_output_tokens"` and `"timeout_ms"`. The explorer may read
  and search the copy; it can neither write nor reach the network.
  """

  @callback explore(input :: map(), opts :: keyword()) ::
              {:ok, %{json: String.t(), output_tokens: non_neg_integer()}} | {:error, atom()}
end
