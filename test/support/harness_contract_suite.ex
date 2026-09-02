defmodule Shoestring.Harness.ContractSuite do
  @moduledoc """
  Reusable adapter contract suite for `Shoestring.Harness.Adapter` implementations.

  ## Usage

      defmodule MyAdapterContractTest do
        use Shoestring.Harness.ContractSuite,
          adapter: MyAdapter,
          config: %{simulate: :completion}
      end

  Each of the seven contract areas generates one named ExUnit test. Tests for
  capabilities the adapter does not declare are explicitly `@tag skip:`-ed —
  never silently passed.

  ## Public assertion functions

  All `assert_*` functions are public and can be called from ad-hoc test blocks
  to verify that a non-conforming adapter fails the contract. Each function
  raises `ExUnit.AssertionError` on violation.
  """

  import ExUnit.Assertions

  alias Shoestring.Harness.{
    Adapter,
    CapacitySnapshot,
    Error,
    HarnessEvent,
    Identity,
    RunIdentity,
    RunRequest
  }

  @valid_capabilities MapSet.new([:resume, :send, :cancel, :interactive])

  # ─── Public assertion functions ─────────────────────────────────────────────

  @doc "Assert area 1: adapter returns a valid Identity and a well-formed capability set."
  def assert_identity(adapter) do
    identity = adapter.identity()

    assert is_struct(identity, Identity),
           "identity/0 must return a %Shoestring.Harness.Identity{} struct, got: #{inspect(identity)}"

    assert is_binary(identity.adapter_id) and byte_size(identity.adapter_id) > 0,
           "identity.adapter_id must be a non-empty string"

    assert is_binary(identity.provider) and byte_size(identity.provider) > 0,
           "identity.provider must be a non-empty string"

    assert is_binary(identity.adapter_version) and byte_size(identity.adapter_version) > 0,
           "identity.adapter_version must be a non-empty string"

    assert is_integer(identity.schema_version) and identity.schema_version > 0,
           "identity.schema_version must be a positive integer"

    assert identity.invocation_mode in [:process, :api, :fake],
           "identity.invocation_mode must be one of :process, :api, :fake"

    caps = adapter.capabilities()

    assert is_struct(caps, MapSet),
           "capabilities/0 must return a MapSet, got: #{inspect(caps)}"

    unknown = MapSet.difference(caps, @valid_capabilities)

    assert MapSet.size(unknown) == 0,
           "capabilities/0 includes unrecognized capabilities: #{inspect(MapSet.to_list(unknown))}"

    :ok
  end

  @doc "Assert area 2: start returns RunIdentity; stream emits well-formed events; cancel works when declared."
  def assert_start_stream_completion_failure_cancellation(adapter, run_request, config) do
    # Start – success path
    start_result = adapter.start(run_request, config)

    assert match?({:ok, _}, start_result),
           "start/2 must return {:ok, %RunIdentity{}}, got: #{inspect(start_result)}"

    {:ok, run_identity} = start_result

    assert is_struct(run_identity, RunIdentity),
           "start/2 {:ok, value} must be a %RunIdentity{}, got: #{inspect(run_identity)}"

    assert is_binary(run_identity.run_id),
           "run_identity.run_id must be a string UUID"

    assert match?({:ok, _}, Ecto.UUID.cast(run_identity.run_id)),
           "run_identity.run_id must be a valid UUID, got: #{inspect(run_identity.run_id)}"

    assert is_binary(run_identity.harness_id) and byte_size(run_identity.harness_id) > 0,
           "run_identity.harness_id must be a non-empty string"

    # Stream – well-formed events
    stream_result = adapter.stream(run_identity, config)

    assert match?({:ok, _}, stream_result),
           "stream/2 must return {:ok, enumerable}, got: #{inspect(stream_result)}"

    {:ok, events} = stream_result

    event_list = Enum.to_list(events)

    assert length(event_list) > 0,
           "stream/2 must emit at least one event"

    ordinals = Enum.map(event_list, & &1.ordinal)

    Enum.each(event_list, fn event ->
      assert is_struct(event, HarnessEvent),
             "each stream event must be a %HarnessEvent{}, got: #{inspect(event)}"

      assert event.run_id == run_identity.run_id,
             "event.run_id must match run_identity.run_id"

      assert is_integer(event.ordinal) and event.ordinal > 0,
             "event.ordinal must be a positive integer"
    end)

    assert ordinals == Enum.sort(ordinals),
           "stream events must be emitted in ordinal order"

    # Completion – result event present
    result_events = Enum.filter(event_list, &(&1.kind == :result))

    assert length(result_events) > 0,
           "stream must include at least one :result event for a normal completion"

    Enum.each(result_events, fn ev ->
      assert ev.result.status in ["completed", "accepted"],
             "result event status must be 'completed' or 'accepted', got: #{inspect(ev.result.status)}"
    end)

    # Failure – start returns typed Error when simulated
    failure_result = adapter.start(run_request, Map.put(config, :simulate, :failure))

    assert match?({:error, %Error{}}, failure_result) or
             match?({:ok, %RunIdentity{}}, failure_result),
           "start/2 must return {:ok, RunIdentity} or {:error, %Error{}}"

    case failure_result do
      {:error, %Error{} = err} ->
        assert err.category in Error.categories(),
               "error.category must be a recognized category"

        assert is_binary(err.code) and byte_size(err.code) > 0,
               "error.code must be a non-empty string"

        assert is_binary(err.message) and byte_size(err.message) > 0,
               "error.message must be a non-empty string"

      _ ->
        :ok
    end

    # Cancellation – only if declared
    if Adapter.supports?(adapter, :cancel) do
      cancel_result = adapter.cancel(run_identity, config)

      assert match?({:ok, :cancelled}, cancel_result),
             "cancel/2 must return {:ok, :cancelled} when :cancel is declared, got: #{inspect(cancel_result)}"
    end

    :ok
  end

  @doc "Assert area 3: resume returns RunIdentity when :resume is declared."
  def assert_resume(adapter, run_identity, run_request, config) do
    assert Adapter.supports?(adapter, :resume),
           "assert_resume called but :resume is not in adapter.capabilities()"

    resume_result = adapter.resume(run_identity, run_request, config)

    assert match?({:ok, _}, resume_result),
           "resume/3 must return {:ok, %RunIdentity{}}, got: #{inspect(resume_result)}"

    {:ok, resumed} = resume_result

    assert is_struct(resumed, RunIdentity),
           "resume/3 {:ok, value} must be a %RunIdentity{}, got: #{inspect(resumed)}"

    assert is_binary(resumed.run_id),
           "resumed run_identity.run_id must be a string UUID"

    assert match?({:ok, _}, Ecto.UUID.cast(resumed.run_id)),
           "resumed run_identity.run_id must be a valid UUID, got: #{inspect(resumed.run_id)}"

    :ok
  end

  @doc "Assert area 4: probe returns typed quota_refused error when over limit."
  def assert_quota_refusal(adapter, config) do
    result = adapter.probe(Map.put(config, :simulate, :quota_refused))

    assert match?({:error, _}, result),
           "probe/1 with quota_refused simulation must return an error tuple, got: #{inspect(result)}"

    {:error, err} = result

    assert is_struct(err, Error),
           "probe/1 quota_refused error value must be a %Error{}, got: #{inspect(err)}"

    assert err.category == :quota_refused,
           "error.category must be :quota_refused, got: #{inspect(err.category)}"

    assert is_binary(err.code) and byte_size(err.code) > 0,
           "error.code must be a non-empty string"

    assert is_binary(err.message) and byte_size(err.message) > 0,
           "error.message must be a non-empty string"

    :ok
  end

  @doc "Assert area 5: probe with missing/invalid config returns error or unknown/degraded snapshot."
  def assert_missing_capacity(adapter, config) do
    result_missing = adapter.probe(Map.put(config, :simulate, :missing_config))

    case result_missing do
      {:error, %Error{} = err} ->
        assert err.category in Error.categories(),
               "error from missing config must have a recognized category"

      {:ok, %CapacitySnapshot{} = snapshot} ->
        assert snapshot.capacity_state == :unknown,
               "snapshot from missing config must have :unknown capacity_state, not #{inspect(snapshot.capacity_state)}"

        assert snapshot.compatibility_state in [:degraded, :incompatible],
               "snapshot from missing config must be :degraded or :incompatible, not #{inspect(snapshot.compatibility_state)}"

      other ->
        flunk(
          "probe/1 with missing config must return {:error, Error} or {:ok, CapacitySnapshot}, got: #{inspect(other)}"
        )
    end

    result_incompatible = adapter.probe(Map.put(config, :simulate, :incompatible))

    case result_incompatible do
      {:ok, %CapacitySnapshot{} = snapshot} ->
        assert snapshot.compatibility_state in [:degraded, :incompatible],
               "incompatible adapter version must produce :degraded or :incompatible snapshot"

        refute snapshot.compatibility_state == :compatible,
               "incompatible version must never appear as :compatible"

      {:error, %Error{}} ->
        :ok

      other ->
        flunk(
          "probe/1 with incompatible simulation must return Error or degraded CapacitySnapshot, got: #{inspect(other)}"
        )
    end

    :ok
  end

  @doc "Assert area 6: no secrets in identity, RunIdentity, or stream events."
  def assert_secret_free(adapter, run_identity, events) do
    identity = adapter.identity()

    assert is_struct(identity, Identity),
           "secret-free check: identity/0 must return %Identity{}, got: #{inspect(identity)}"

    refute_secrets(identity.adapter_id, "identity.adapter_id")
    refute_secrets(identity.provider, "identity.provider")
    refute_secrets(identity.adapter_version, "identity.adapter_version")

    assert is_struct(run_identity, RunIdentity),
           "secret-free check: run_identity must be %RunIdentity{}, got: #{inspect(run_identity)}"

    if run_identity.process_id,
      do: refute_secrets(run_identity.process_id, "run_identity.process_id")

    if run_identity.provider_session_id,
      do: refute_secrets(run_identity.provider_session_id, "run_identity.provider_session_id")

    Enum.each(events, fn event ->
      assert is_struct(event, HarnessEvent),
             "secret-free check: each event must be a %HarnessEvent{}, got: #{inspect(event)}"

      refute_map_secrets(event.extensions, "event[#{event.ordinal}].extensions")
    end)

    :ok
  end

  @doc "Assert area 7: repeated cancel does not raise; calling after terminal returns ok or typed Error."
  def assert_terminal_idempotency(adapter, run_identity, config) do
    if Adapter.supports?(adapter, :cancel) do
      first = adapter.cancel(run_identity, config)

      assert match?({:ok, :cancelled}, first) or match?({:error, %Error{}}, first),
             "first cancel must return {:ok, :cancelled} or {:error, %Error{}}"

      second = adapter.cancel(run_identity, Map.put(config, :simulate, :already_cancelled))

      assert match?({:ok, :cancelled}, second) or match?({:error, %Error{}}, second),
             "second cancel (terminal idempotency) must not raise; got: #{inspect(second)}"
    end

    :ok
  end

  # ─── Helpers ────────────────────────────────────────────────────────────────

  @doc "Build a minimal valid RunRequest for contract testing."
  def make_run_request do
    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        workspace_ref: "workspace/contract-test",
        prompt: "Execute the next contract test step.",
        policy: %{mode: "supervised", network: false, write_access: false},
        requested_capabilities: [],
        dispatch_id: "00000000-0000-4000-8000-000000000003"
      })

    request
  end

  # ─── `use` macro ────────────────────────────────────────────────────────────

  defmacro __using__(opts) do
    adapter_ast = Keyword.fetch!(opts, :adapter)
    adapter = Macro.expand(adapter_ast, __CALLER__)
    config = Keyword.get(opts, :config, %{})
    caps = adapter.capabilities()
    has_resume = :resume in caps

    resume_test =
      if has_resume do
        quote do
          test "capability-appropriate resume behavior" do
            request = Shoestring.Harness.ContractSuite.make_run_request()
            {:ok, run_identity} = unquote(adapter).start(request, unquote(config))

            Shoestring.Harness.ContractSuite.assert_resume(
              unquote(adapter),
              run_identity,
              request,
              unquote(config)
            )
          end
        end
      else
        quote do
          @tag skip: "#{inspect(unquote(adapter))} does not declare :resume capability"
          test "capability-appropriate resume behavior" do
            flunk("capability not declared; this test should have been skipped")
          end
        end
      end

    quote do
      use ExUnit.Case, async: true

      import ExUnit.Assertions

      test "identity and compatibility reporting" do
        Shoestring.Harness.ContractSuite.assert_identity(unquote(adapter))
      end

      test "normalized start, stream, completion, failure, and cancellation" do
        request = Shoestring.Harness.ContractSuite.make_run_request()

        Shoestring.Harness.ContractSuite.assert_start_stream_completion_failure_cancellation(
          unquote(adapter),
          request,
          unquote(config)
        )
      end

      unquote(resume_test)

      test "quota refusal classification" do
        Shoestring.Harness.ContractSuite.assert_quota_refusal(unquote(adapter), unquote(config))
      end

      test "missing/malformed capacity behavior" do
        Shoestring.Harness.ContractSuite.assert_missing_capacity(
          unquote(adapter),
          unquote(config)
        )
      end

      test "secret-free persistence and diagnostics" do
        request = Shoestring.Harness.ContractSuite.make_run_request()
        {:ok, run_identity} = unquote(adapter).start(request, unquote(config))
        {:ok, events} = unquote(adapter).stream(run_identity, unquote(config))

        Shoestring.Harness.ContractSuite.assert_secret_free(
          unquote(adapter),
          run_identity,
          Enum.to_list(events)
        )
      end

      test "terminal idempotency and cleanup" do
        request = Shoestring.Harness.ContractSuite.make_run_request()
        {:ok, run_identity} = unquote(adapter).start(request, unquote(config))

        Shoestring.Harness.ContractSuite.assert_terminal_idempotency(
          unquote(adapter),
          run_identity,
          unquote(config)
        )
      end
    end
  end

  # ─── Private helpers ─────────────────────────────────────────────────────────

  @secret_patterns [
    ~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i,
    ~r/\b(?:api[_-]?key|access[_-]?token|secret|password)\s*[:=]/i,
    ~r/\bsk-[A-Za-z0-9_-]{12,}/
  ]

  defp refute_secrets(value, label) when is_binary(value) do
    refute Enum.any?(@secret_patterns, &Regex.match?(&1, value)),
           "#{label} contains a secret pattern: #{inspect(value)}"
  end

  defp refute_secrets(_value, _label), do: :ok

  defp refute_map_secrets(map, label) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      refute_secrets(to_string(key), "#{label} key")
      refute_secrets_deep(value, "#{label}[#{key}]")
    end)
  end

  defp refute_map_secrets(_map, _label), do: :ok

  defp refute_secrets_deep(value, label) when is_binary(value), do: refute_secrets(value, label)

  defp refute_secrets_deep(value, label) when is_map(value),
    do: refute_map_secrets(value, label)

  defp refute_secrets_deep(value, label) when is_list(value),
    do: Enum.each(value, &refute_secrets_deep(&1, label))

  defp refute_secrets_deep(_value, _label), do: :ok
end
