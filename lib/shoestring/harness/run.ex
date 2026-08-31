defmodule Shoestring.Harness.Run do
  @moduledoc "Normalized run identity and event-stream behavior independent of transport."

  alias Shoestring.Harness.{Error, HarnessEvent, RunIdentity}

  @callback identity(term()) :: RunIdentity.t()
  @callback events(term()) :: {:ok, Enumerable.t(HarnessEvent.t())} | {:error, Error.t()}
  @callback status(term()) :: {:ok, map()} | {:error, Error.t()}
end
