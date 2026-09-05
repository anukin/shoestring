defmodule Shoestring.Harness.CodexAppServerContractTest do
  @moduledoc """
  Verifies that Shoestring.Harness.CodexAppServer satisfies all 7 areas of
  the shared Shoestring.Harness.ContractSuite:
  1. Identity and capabilities.
  2. Normalized start, stream, completion, failure, cancellation.
  3. Resume capability (verified live and implemented).
  4. Quota refusal classification.
  5. Missing / malformed capacity behavior.
  6. Secret-free persistence.
  7. Terminal cancellation idempotency.
  """
  use Shoestring.Harness.ContractSuite,
    adapter: Shoestring.Harness.CodexAppServer,
    config: %{}
end
