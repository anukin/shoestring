defmodule Shoestring.Cobbler.LeaseGrant do
  @moduledoc """
  Pure admission-to-lease grant gate (Milestone 05, work package C).

  A grant is issued only for an `admission.decided` v1 outcome of `:admit`.
  `:defer_until`, `:require_confirmation`, and `:reject` outcomes are refused
  with the decision's own reason code — the gate never upgrades a non-admit
  into execution budget. Admission reference equivalence is delegated to
  `Shoestring.Cobbler.Commands.validate_admission_reference/3` (same goal,
  `admission.decided` v1, intent/scope/candidate match), never reimplemented.

  Fail-closed rules:

  - A missing `admitted_snapshot_id` (nil observation snapshot, including
    `confirmed_*` admits) refuses the grant: a fresh snapshot is required.
  - Malformed `proposed_bounds` (unparseable deadline, non-positive budgets)
    return `{:error, {:lease_invalid, _}}` rather than a synthesized lease.
  - `grant_id` is a fresh UUID per call; replay protection (returning an
    existing grant for the same `(goal_id, admission decision_id)`) lives in
    `Shoestring.Cobbler.Leases.grant/3`, which runs before any row is created
    by the caller (`Shoestring.Cobbler.Leases.issue_for_claim/6` checks replay
    before creating the run row, so replays create zero rows).

  `proposed_bounds` mapping: `response_budget` / `tool_budget` /
  `checkpoint_cadence` pass through, `deadline` (ISO8601) is parsed to a
  `DateTime`, `reserves` splits into `%{response, tool}`, `contract_version`
  is `1`, and `renewal_state` starts at `:none`. Decision references travel in
  namespaced extensions (`cobbler.lease:*`) per the extension contract.
  """

  alias Shoestring.Cobbler.{AdmissionDecision, Command, Commands}
  alias Shoestring.Harness.ExecutionLease
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  @contract_version 1
  @initial_renewal_state :none

  @type refusal :: {:lease_refused, map()}
  @type invalid :: {:lease_invalid, term()}

  @doc """
  Builds an `ExecutionLease` from an admitted decision event.

  Returns `{:ok, lease}`, `{:error, {:lease_refused, detail}}` for
  decision-driven refusals, or `{:error, {:lease_invalid, reason}}` for
  malformed bounds/contracts. Never touches the database except through
  `Commands.validate_admission_reference/3` (read-only).

  Options: `:repo` (default `Shoestring.Repo`), `:grant_id` (default fresh
  UUID).
  """
  @spec build(Ecto.UUID.t(), Ecto.UUID.t(), TrajectoryEvent.t(), Command.t(), keyword()) ::
          {:ok, ExecutionLease.t()} | {:error, refusal() | invalid()}
  def build(goal_id, run_id, %TrajectoryEvent{} = event, %Command{} = command, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    grant_id = Keyword.get(opts, :grant_id, Ecto.UUID.generate())

    with {:ok, decision} <- decision(event),
         :ok <- admit_only(decision, event),
         :ok <- reference(repo, goal_id, command, decision, event),
         {:ok, snapshot_id} <- admitted_snapshot(decision, event),
         {:ok, lease} <- assemble(decision, event, run_id, grant_id, snapshot_id) do
      {:ok, lease}
    end
  end

  defp decision(%TrajectoryEvent{payload: payload, id: event_id}) do
    case AdmissionDecision.from_payload(payload) do
      {:ok, decision} ->
        {:ok, decision}

      {:error, _changeset} ->
        {:error,
         {:lease_refused,
          %{
            reason: "admission_decision_invalid",
            admission_event_id: event_id
          }}}
    end
  end

  defp admit_only(%AdmissionDecision{result: :admit}, _event), do: :ok

  defp admit_only(%AdmissionDecision{} = decision, event) do
    {:error,
     {:lease_refused,
      %{
        reason: decision.reason_code,
        result: Atom.to_string(decision.result),
        decision_id: decision.decision_id,
        admission_event_id: event.id
      }}}
  end

  defp reference(repo, goal_id, command, decision, event) do
    case Commands.validate_admission_reference(repo, goal_id, command) do
      {:ok, _reference} ->
        :ok

      {:rejected, reason} ->
        {:error,
         {:lease_refused,
          %{
            reason: reason,
            decision_id: decision.decision_id,
            admission_event_id: event.id
          }}}
    end
  end

  defp admitted_snapshot(%AdmissionDecision{observation: observation} = decision, event) do
    case observation["snapshot_id"] do
      snapshot_id when is_binary(snapshot_id) and snapshot_id != "" ->
        {:ok, snapshot_id}

      _missing ->
        {:error,
         {:lease_refused,
          %{
            reason: "admitted_snapshot_missing",
            result: Atom.to_string(decision.result),
            reason_code: decision.reason_code,
            decision_id: decision.decision_id,
            admission_event_id: event.id
          }}}
    end
  end

  defp assemble(decision, event, run_id, grant_id, snapshot_id) do
    bounds = decision.proposed_bounds || %{}

    with {:ok, deadline} <- deadline(bounds["deadline"]),
         {:ok, reserves} <- reserves(bounds["reserves"]) do
      attrs = %{
        version: @contract_version,
        grant_id: grant_id,
        run_id: run_id,
        admitted_snapshot_id: snapshot_id,
        reserves: reserves,
        response_budget: bounds["response_budget"],
        tool_budget: bounds["tool_budget"],
        deadline: deadline,
        checkpoint_cadence: bounds["checkpoint_cadence"],
        renewal_state: @initial_renewal_state,
        extensions: extensions(decision, event)
      }

      case ExecutionLease.new(attrs) do
        {:ok, lease} -> {:ok, lease}
        {:error, changeset} -> {:error, {:lease_invalid, changeset}}
      end
    else
      {:error, reason} -> {:error, {:lease_invalid, reason}}
    end
  end

  defp deadline(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, deadline, _offset} -> {:ok, DateTime.truncate(deadline, :microsecond)}
      _error -> {:error, {:deadline, value}}
    end
  end

  defp deadline(value), do: {:error, {:deadline, value}}

  defp reserves(%{"response" => response, "tool" => tool})
       when is_integer(response) and is_integer(tool) do
    {:ok, %{response: response, tool: tool}}
  end

  defp reserves(%{response: response, tool: tool})
       when is_integer(response) and is_integer(tool) do
    {:ok, %{response: response, tool: tool}}
  end

  defp reserves(value), do: {:error, {:reserves, value}}

  defp extensions(decision, event) do
    %{
      "cobbler.lease:admission_decision_id" => decision.decision_id,
      "cobbler.lease:admission_event_id" => event.id,
      "cobbler.lease:candidate" =>
        "#{decision.candidate.provider_id}/#{decision.candidate.adapter_id}",
      "cobbler.lease:scope" => decision.scope
    }
  end
end
