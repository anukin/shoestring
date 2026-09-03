defmodule Shoestring.Harness.Capacity.Codex.Transport do
  @moduledoc """
  Transport boundary behaviour for communicating with `codex app-server --stdio`
  via JSON-RPC frames.
  """

  @type frame :: map() | binary()

  @callback start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  @callback send_frame(pid(), frame()) :: :ok | {:error, term()}
  @callback close(pid()) :: :ok
end
