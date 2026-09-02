defmodule Shoestring.Harness.EventPayload do
  @moduledoc "Explicit JSON-safe bridges from normalized contracts to canonical trajectory payloads."

  alias Shoestring.Harness.{
    CapacitySnapshot,
    Checkpoint,
    ExecutionLease,
    HarnessEvent,
    RunRequest
  }

  @spec run_requested(RunRequest.t(), Ecto.UUID.t(), String.t()) :: map()
  def run_requested(request, run_id, provider_id) do
    %{
      "run_id" => run_id,
      "dispatch_id" => request.dispatch_id,
      "provider_id" => provider_id,
      "workspace_ref" => request.workspace_ref,
      "request_version" => request.version,
      "prompt" => request.prompt,
      "continuation" => continuation(request.continuation),
      "policy" => policy(request.policy),
      "requested_capabilities" => %{
        "items" => Enum.map(request.requested_capabilities, &Atom.to_string/1)
      },
      "extensions" => request.extensions
    }
  end

  @spec dispatch_requested(%{
          dispatch_id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t(),
          request_version: pos_integer()
        }) :: map()
  def dispatch_requested(%{dispatch_id: dispatch_id, run_id: run_id, request_version: version}) do
    %{
      "dispatch_id" => dispatch_id,
      "run_id" => run_id,
      "request_version" => version
    }
  end

  @spec capacity_snapshot(CapacitySnapshot.t(), Ecto.UUID.t() | nil) :: map()
  def capacity_snapshot(snapshot, run_id \\ nil) do
    %{
      "snapshot_id" => snapshot.snapshot_id,
      "run_id" => run_id,
      "contract_version" => snapshot.version,
      "capacity_state" => Atom.to_string(snapshot.capacity_state),
      "windows" => %{"items" => Enum.map(snapshot.windows, &window/1)},
      "observed_at" => iso8601(snapshot.observed_at),
      "expires_at" => iso8601(snapshot.expires_at),
      "source" => %{
        "adapter_id" => snapshot.source.adapter_id,
        "method" => snapshot.source.method
      },
      "scope" => snapshot.scope,
      "confidence" => Atom.to_string(snapshot.confidence),
      "support_tier" => Atom.to_string(snapshot.support_tier),
      "compatibility_state" => Atom.to_string(snapshot.compatibility_state),
      "extensions" => snapshot.extensions
    }
    |> drop_nil_values()
  end

  @spec execution_lease(ExecutionLease.t()) :: map()
  def execution_lease(lease) do
    %{
      "grant_id" => lease.grant_id,
      "run_id" => lease.run_id,
      "admitted_snapshot_id" => lease.admitted_snapshot_id,
      "contract_version" => lease.version,
      "reserves" => %{"response" => lease.reserves.response, "tool" => lease.reserves.tool},
      "response_budget" => lease.response_budget,
      "tool_budget" => lease.tool_budget,
      "deadline" => iso8601(lease.deadline),
      "checkpoint_cadence" => lease.checkpoint_cadence,
      "renewal_state" => Atom.to_string(lease.renewal_state),
      "extensions" => lease.extensions
    }
  end

  @spec checkpoint(Checkpoint.t()) :: map()
  def checkpoint(checkpoint) do
    %{
      "checkpoint_id" => checkpoint.checkpoint_id,
      "run_id" => checkpoint.run_id,
      "contract_version" => checkpoint.version,
      "acceptance_contract" => %{"criteria" => checkpoint.acceptance_contract.criteria},
      "repository_state" => %{
        "revision" => checkpoint.repository_state.revision,
        "dirty" => checkpoint.repository_state.dirty
      },
      "evidence" => %{"items" => checkpoint.evidence},
      "decisions" => %{"items" => checkpoint.decisions},
      "unresolved_issues" => %{"items" => checkpoint.unresolved_issues},
      "next_action" => checkpoint.next_action,
      "provider_session_id" => checkpoint.provider_session_id,
      "stop_reason" => checkpoint.stop_reason,
      "artifact_ids" => %{"items" => checkpoint.artifact_ids},
      "extensions" => checkpoint.extensions
    }
    |> drop_nil_values()
  end

  @spec harness_event(HarnessEvent.t()) :: map()
  def harness_event(event) do
    %{
      "run_id" => event.run_id,
      "source_event_id" => event.source_event_id,
      "ordinal" => event.ordinal,
      "occurred_at" => iso8601(event.occurred_at),
      "kind" => Atom.to_string(event.kind),
      "process_id" => event.process_id,
      "provider_session_id" => event.provider_session_id,
      "artifact_id" => event.artifact_id,
      "capacity_snapshot_id" => event.capacity_snapshot_id,
      "error" => error(event.error),
      "result" => result(event.result),
      "extensions" => event.extensions
    }
    |> drop_nil_values()
  end

  defp continuation(nil), do: %{}

  defp continuation(continuation) do
    %{
      "checkpoint_id" => continuation.checkpoint_id,
      "next_action" => continuation.next_action,
      "decision_refs" => continuation.decision_refs
    }
  end

  defp policy(policy) do
    %{
      "mode" => policy.mode,
      "network" => policy.network,
      "write_access" => policy.write_access
    }
  end

  defp window(%{state: :known} = window) do
    %{
      "kind" => window.kind,
      "state" => "known",
      "used_percent" => window.used_percent,
      "reset_at" => iso8601(window.reset_at)
    }
    |> drop_nil_values()
  end

  defp window(%{state: :unknown} = window) do
    %{"kind" => window.kind, "state" => "unknown", "reason" => window.reason}
  end

  defp error(nil), do: nil

  defp error(error) do
    %{
      "category" => Atom.to_string(error.category),
      "code" => error.code,
      "message" => error.message,
      "details" => error.details
    }
  end

  defp result(nil), do: nil

  defp result(result) do
    %{"status" => result.status, "artifact_id" => result.artifact_id}
    |> drop_nil_values()
  end

  defp iso8601(nil), do: nil
  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)
  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
