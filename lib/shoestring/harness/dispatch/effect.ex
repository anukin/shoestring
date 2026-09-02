defmodule Shoestring.Harness.Dispatch.Effect do
  @moduledoc "Boundary for one harness-start effect after durable dispatch reconciliation."

  alias Shoestring.Harness.{DispatchRecord, RunRecord}

  @callback perform(RunRecord.t(), DispatchRecord.t()) :: :ok | {:ok, term()} | {:error, term()}
end
