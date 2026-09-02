defmodule Shoestring.Harness.Fake.Scenario do
  @moduledoc """
  A scripted harness scenario for deterministic, offline testing.

  Each scenario pre-defines what the fake adapter returns for probe, start,
  resume, cancel, and stream. The event sequence is resolved against an
  injected clock when stream/2 is called.

  Use the named constructors (normal_completion/0 etc.) for the required
  standard scenarios, or build a custom one with new/1.
  """

  alias Shoestring.Harness.{CapacitySnapshot, Error}

  @type event_kind ::
          :lifecycle | :output | :tool | :command | :artifact | :capacity | :error | :result

  @type event_spec :: %{
          kind: event_kind(),
          offset_ms: non_neg_integer(),
          source_event_id: String.t() | nil,
          error: Error.t() | nil,
          result: %{status: String.t(), artifact_id: String.t() | nil} | nil,
          capacity_snapshot: CapacitySnapshot.t() | nil,
          extensions: map()
        }

  @type delivery_modifier :: :none | :duplicate | :out_of_order | :delayed

  @enforce_keys [:name]
  defstruct [
    :name,
    :capacity,
    :start_error,
    :resume_error,
    :provider_session_id,
    events: [],
    delivery_modifier: :none
  ]

  @type t :: %__MODULE__{
          name: atom(),
          capacity: CapacitySnapshot.t() | nil,
          start_error: Error.t() | nil,
          resume_error: Error.t() | nil,
          provider_session_id: String.t() | nil,
          events: [event_spec()],
          delivery_modifier: delivery_modifier()
        }

  @adapter_id "shoestring.harness.fake"

  # -- Named constructors for required scenarios --

  @doc "Healthy capacity, clean run, normal completion."
  @spec normal_completion(keyword()) :: t()
  def normal_completion(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff01")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :normal_completion,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-normal",
      events: [
        lifecycle_event(offset_ms: 0),
        output_event("output line 1", offset_ms: 100),
        output_event("output line 2", offset_ms: 200),
        result_event("completed", offset_ms: 300)
      ]
    }
  end

  @doc "Capacity approaches reserve across response boundaries."
  @spec approaching_reserve(keyword()) :: t()
  def approaching_reserve(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff02")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])
    snapshot2_id = Keyword.get(opts, :snapshot2_id, "00000000-0000-4000-8000-f0000000ff03")

    %__MODULE__{
      name: :approaching_reserve,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-approaching",
      events: [
        lifecycle_event(offset_ms: 0),
        output_event("response 1", offset_ms: 100),
        capacity_event(snapshot2_id, 65.0, now, offset_ms: 200),
        output_event("response 2", offset_ms: 300),
        result_event("completed", offset_ms: 400)
      ]
    }
  end

  @doc "Sudden quota refusal with no final response — checkpoint must be possible without a model call."
  @spec sudden_quota_refusal(keyword()) :: t()
  def sudden_quota_refusal(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff04")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :sudden_quota_refusal,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-quota",
      events: [
        lifecycle_event(offset_ms: 0),
        output_event("partial work", offset_ms: 100),
        error_event(
          Error.new(:quota_refused, "rate_limit_exceeded", "subscription limit reached"),
          offset_ms: 200
        )
      ]
    }
  end

  @doc "Capacity snapshot that is already stale at probe time."
  @spec stale_capacity(keyword()) :: t()
  def stale_capacity(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff05")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])
    stale_at = DateTime.add(now, -1, :hour)

    %__MODULE__{
      name: :stale_capacity,
      capacity: stale_snapshot(snapshot_id, stale_at),
      provider_session_id: "fake-session-stale",
      events: [lifecycle_event(offset_ms: 0), result_event("completed", offset_ms: 100)]
    }
  end

  @doc "Capacity observation is entirely absent (unknown state)."
  @spec missing_capacity(keyword()) :: t()
  def missing_capacity(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff06")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :missing_capacity,
      capacity: unknown_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-unknown",
      events: [lifecycle_event(offset_ms: 0), result_event("completed", offset_ms: 100)]
    }
  end

  @doc "Emits a malformed/unknown event — must be surfaced as a degraded/unknown observation."
  @spec malformed_event(keyword()) :: t()
  def malformed_event(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff07")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :malformed_event,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-malformed",
      events: [
        lifecycle_event(offset_ms: 0),
        # A malformed event is represented as an error event with schema_incompatible category
        error_event(
          Error.new(
            :schema_incompatible,
            "unknown_vendor_event",
            "received event of unrecognized shape; treating as degraded observation",
            details: %{"shoestring.harness:raw_type" => "VENDOR_UNKNOWN_EVENT_TYPE"}
          ),
          offset_ms: 100
        ),
        result_event("completed", offset_ms: 200)
      ]
    }
  end

  @doc "Start fails immediately — no run starts."
  @spec start_failure(keyword()) :: t()
  def start_failure(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff08")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :start_failure,
      capacity: healthy_snapshot(snapshot_id, now),
      start_error:
        Error.new(:transport, "process_launch_failed", "fake adapter refused to start"),
      events: []
    }
  end

  @doc "Starts OK then crashes mid-run via a transport error event."
  @spec mid_run_crash(keyword()) :: t()
  def mid_run_crash(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff09")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :mid_run_crash,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-crash",
      events: [
        lifecycle_event(offset_ms: 0),
        output_event("working...", offset_ms: 100),
        error_event(
          Error.new(:transport, "process_exited", "harness process terminated unexpectedly",
            retryable: false
          ),
          offset_ms: 200
        )
      ]
    }
  end

  @doc "Cancelled before the first external-effect event."
  @spec cancel_before_effect(keyword()) :: t()
  def cancel_before_effect(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff0a")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :cancel_before_effect,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-cancel-before",
      events: [lifecycle_event(offset_ms: 0)]
    }
  end

  @doc "Cancelled after an external-effect event has already occurred."
  @spec cancel_after_effect(keyword()) :: t()
  def cancel_after_effect(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff0b")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :cancel_after_effect,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-cancel-after",
      events: [
        lifecycle_event(offset_ms: 0),
        output_event("effect applied", offset_ms: 100)
      ]
    }
  end

  @doc "Lease expires but work pauses only at a safe boundary (after the current response completes)."
  @spec lease_expiry_at_safe_boundary(keyword()) :: t()
  def lease_expiry_at_safe_boundary(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff0c")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :lease_expiry_at_safe_boundary,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-lease-expiry",
      events: [
        lifecycle_event(offset_ms: 0),
        output_event("response at boundary", offset_ms: 100),
        result_event("completed", offset_ms: 200)
      ]
    }
  end

  @doc "Same-session resume continues from a prior session ID."
  @spec same_session_resume(keyword()) :: t()
  def same_session_resume(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff0d")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :same_session_resume,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-resume",
      events: [
        lifecycle_event(offset_ms: 0),
        output_event("resumed output", offset_ms: 100),
        result_event("completed", offset_ms: 200)
      ]
    }
  end

  @doc "Cross-harness handoff target: a second fake identity receives a continuation."
  @spec handoff_target(keyword()) :: t()
  def handoff_target(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff0e")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :handoff_target,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-handoff-b",
      events: [
        lifecycle_event(offset_ms: 0),
        output_event("continued from checkpoint", offset_ms: 100),
        result_event("completed", offset_ms: 200)
      ]
    }
  end

  @doc "Events arrive with artificial delay (tests delivery ordering tolerance)."
  @spec delayed_delivery(keyword()) :: t()
  def delayed_delivery(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff0f")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :delayed_delivery,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-delayed",
      delivery_modifier: :delayed,
      events: [
        lifecycle_event(offset_ms: 0),
        output_event("delayed output", offset_ms: 500),
        result_event("completed", offset_ms: 1000)
      ]
    }
  end

  @doc "One event is delivered twice (duplicate transport delivery)."
  @spec duplicated_delivery(keyword()) :: t()
  def duplicated_delivery(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff10")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :duplicated_delivery,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-duplicated",
      delivery_modifier: :duplicate,
      events: [
        lifecycle_event(offset_ms: 0),
        output_event("output", offset_ms: 100),
        result_event("completed", offset_ms: 200)
      ]
    }
  end

  @doc "Events arrive out of order — consumer must handle reordering."
  @spec out_of_order_delivery(keyword()) :: t()
  def out_of_order_delivery(opts \\ []) do
    snapshot_id = Keyword.get(opts, :snapshot_id, "00000000-0000-4000-8000-f0000000ff11")
    now = Keyword.get(opts, :now, ~U[2026-09-01 10:00:00.000000Z])

    %__MODULE__{
      name: :out_of_order_delivery,
      capacity: healthy_snapshot(snapshot_id, now),
      provider_session_id: "fake-session-ooo",
      delivery_modifier: :out_of_order,
      events: [
        lifecycle_event(offset_ms: 0, source_event_id: "evt-001"),
        output_event("event 2", offset_ms: 100, source_event_id: "evt-002"),
        output_event("event 3", offset_ms: 200, source_event_id: "evt-003"),
        result_event("completed", offset_ms: 300, source_event_id: "evt-004")
      ]
    }
  end

  # -- Event spec builders --

  @spec lifecycle_event(keyword()) :: event_spec()
  def lifecycle_event(opts \\ []) do
    %{
      kind: :lifecycle,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.get(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{"shoestring.fake:detail" => "running"}
    }
  end

  @spec output_event(String.t(), keyword()) :: event_spec()
  def output_event(text, opts \\ []) do
    %{
      kind: :output,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.get(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{"shoestring.fake:text" => text}
    }
  end

  @spec error_event(Error.t(), keyword()) :: event_spec()
  def error_event(error, opts \\ []) do
    %{
      kind: :error,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.get(opts, :source_event_id),
      error: error,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{}
    }
  end

  @spec result_event(String.t(), keyword()) :: event_spec()
  def result_event(status, opts \\ []) do
    %{
      kind: :result,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.get(opts, :source_event_id),
      error: nil,
      result: %{status: status, artifact_id: nil},
      capacity_snapshot: nil,
      extensions: %{}
    }
  end

  @spec capacity_event(String.t(), float(), DateTime.t(), keyword()) :: event_spec()
  def capacity_event(snapshot_id, used_percent, observed_at, opts \\ []) do
    now = observed_at
    event_observed_at = DateTime.add(now, Keyword.get(opts, :offset_ms, 0), :millisecond)

    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: used_percent, reset_at: nil}
          ],
          observed_at: event_observed_at,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @adapter_id,
            provider_id: "fake",
            invocation_mode: "fake",
            event: :explicit_read
          },
          scope: "subscription",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: event_observed_at
      )

    %{
      kind: :capacity,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.get(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: snapshot,
      extensions: %{}
    }
  end

  # -- Capacity snapshot builders --

  @spec healthy_snapshot(String.t(), DateTime.t()) :: CapacitySnapshot.t()
  def healthy_snapshot(snapshot_id, now) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: 20.0, reset_at: nil}
          ],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @adapter_id,
            provider_id: "fake",
            invocation_mode: "fake",
            event: :explicit_read
          },
          scope: "subscription",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  @spec stale_snapshot(String.t(), DateTime.t()) :: CapacitySnapshot.t()
  def stale_snapshot(snapshot_id, observed_at) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: 50.0, reset_at: nil}
          ],
          observed_at: observed_at,
          freshness: %{max_age_seconds: 60},
          source: %{
            adapter_id: @adapter_id,
            provider_id: "fake",
            invocation_mode: "fake",
            event: :explicit_read
          },
          scope: "subscription",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: observed_at
      )

    snapshot
  end

  @spec unknown_snapshot(String.t(), DateTime.t()) :: CapacitySnapshot.t()
  def unknown_snapshot(snapshot_id, now) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :unknown,
          windows: [],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @adapter_id,
            provider_id: "fake",
            invocation_mode: "fake",
            event: :explicit_read
          },
          scope: "subscription",
          confidence: :none,
          support_tier: :unsupported,
          compatibility_state: :compatible,
          reason: "probe_unconfigured",
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  @spec degraded_snapshot(String.t(), DateTime.t()) :: CapacitySnapshot.t()
  def degraded_snapshot(snapshot_id, now) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :unknown,
          windows: [],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: @adapter_id,
            provider_id: "fake",
            invocation_mode: "fake",
            event: :explicit_read
          },
          scope: "subscription",
          confidence: :none,
          support_tier: :unsupported,
          compatibility_state: :degraded,
          reason: "required_field_removed",
          extensions: %{"shoestring.fake:degraded_reason" => "required_field_removed"}
        },
        now: now
      )

    snapshot
  end
end
