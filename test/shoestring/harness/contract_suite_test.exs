defmodule Shoestring.Harness.ContractSuiteTest do
  use Shoestring.Harness.ContractSuite,
    adapter: Shoestring.Test.CapabilityAdapter,
    config: %{}
end

defmodule Shoestring.Harness.ContractSuiteRejectionTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.ContractSuite
  alias Shoestring.Test.NonConformingAdapter

  @moduledoc """
  Proves that ContractSuite FAILS a non-conforming adapter.
  Each test wraps an assertion function in assert_raise to verify the suite
  catches specific contract violations.
  """

  test "non-conforming adapter: identity contract fails for plain map return" do
    assert_raise ExUnit.AssertionError, fn ->
      ContractSuite.assert_identity(NonConformingAdapter)
    end
  end

  test "non-conforming adapter: start contract fails for bad tuple format" do
    assert_raise ExUnit.AssertionError, fn ->
      request = ContractSuite.make_run_request()

      ContractSuite.assert_start_stream_completion_failure_cancellation(
        NonConformingAdapter,
        request,
        %{}
      )
    end
  end

  test "non-conforming adapter: stream events fail secret-free contract" do
    # NonConformingAdapter.stream returns maps (not HarnessEvent structs) with secrets.
    # assert_secret_free detects the wrong struct type or secret content.
    {:ok, raw_events} = NonConformingAdapter.stream(nil, %{})

    assert_raise ExUnit.AssertionError, fn ->
      run_id = "00000000-0000-4000-8000-000000000099"

      fake_run_identity = %Shoestring.Harness.RunIdentity{
        run_id: run_id,
        harness_id: "non.conforming",
        process_id: nil,
        provider_session_id: nil
      }

      ContractSuite.assert_secret_free(NonConformingAdapter, fake_run_identity, raw_events)
    end
  end

  test "non-conforming adapter: capabilities contract fails for list return" do
    assert_raise ExUnit.AssertionError, fn ->
      ContractSuite.assert_identity(NonConformingAdapter)
    end
  end

  test "non-conforming adapter: quota refusal contract fails for wrong return type" do
    # probe returns a map instead of {:error, %Error{category: :quota_refused}}
    assert_raise ExUnit.AssertionError, fn ->
      ContractSuite.assert_quota_refusal(NonConformingAdapter, %{})
    end
  end
end
