defmodule Shoestring.Cobbler.LeaseBounds do
  @moduledoc """
  Pure execution-lease bound advancement over normalized harness events
  (Milestone 05, work package C).

  Bound counting (D4):

  - 1 response per `:output` message completion. Delta frames (Codex
    `item/agentMessage/delta`, or any extension key ending in `:delta`) never
    count.
  - 1 tool per completed `:tool` event, or per `:command` START→END
    completion. A START alone never counts — for `:tool` that is an event
    whose status is in progress (Codex `fileChange` arrives as an
    `inProgress` START and a separate completion) or whose boundary is
    `start`; a `:tool` event with no status is single-shot and counts. An END
    completion counts once per correlated item (START observed or not — the
    END is the spend boundary, and duplicate ENDs do not double-spend).
  - `:lifecycle`, `:artifact`, `:capacity`, `:error`, and `:result` events
    never spend. In particular a Codex `:quota_refused` error emits the
    `:quota_refused` fast-path marker with zero spend, and a Claude
    `:task_failed` error spends nothing (by design, Claude errors never map
    to quota).

  Renewal-due (D7) fires one reserve early: `responses >= response_budget -
  response_reserve` OR `tools >= tool_budget - tool_reserve` OR the checkpoint
  cadence reached (`responses >= checkpoint_cadence`). The `:renewal_due`
  marker is edge-triggered: it is emitted once, on the transition into due.

  Multi-epoch renewals (Elf lease re-loop): after a `:renewed` outcome the
  Elf starts a new spend epoch from the renewed grant via `new_epoch/1`.
  Counters and the due latch reset while budgets, identity, and the
  already-seen set are kept, so a later exhaustion re-fires the full
  due → stop → re-evaluate sequence against fresh observations without ever
  double-spending an already-counted event. The grant deadline is unchanged,
  so deadlines still bound total renewals (expiry wins eventually).

  Wiring: `drain/3` folds the live normalized-event buffer for one `run_id`
  (events for other runs are ignored). Only normalized `HarnessEvent`
  structs are consumed — never raw provider output. Redelivered events (same
  `source_event_id`) are idempotent and never double-spend.
  """

  alias Shoestring.Harness.{Error, ExecutionLease, HarnessEvent}

  @enforce_keys [
    :grant_id,
    :run_id,
    :response_budget,
    :tool_budget,
    :response_reserve,
    :tool_reserve,
    :checkpoint_cadence
  ]
  defstruct [
    :grant_id,
    :run_id,
    :response_budget,
    :tool_budget,
    :response_reserve,
    :tool_reserve,
    :checkpoint_cadence,
    epoch: 0,
    responses: 0,
    tools: 0,
    due: false,
    quota_refused: false,
    counted_commands: MapSet.new(),
    seen: MapSet.new()
  ]

  @type effect :: :renewal_due | :quota_refused

  @type boundary :: %{
          bound: :checkpoint_cadence | :response_budget | :tool_budget,
          unit: :responses | :tools,
          remaining: non_neg_integer(),
          reached?: boolean()
        }

  @type t :: %__MODULE__{
          grant_id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t(),
          response_budget: pos_integer(),
          tool_budget: pos_integer(),
          response_reserve: non_neg_integer(),
          tool_reserve: non_neg_integer(),
          checkpoint_cadence: pos_integer(),
          epoch: non_neg_integer(),
          responses: non_neg_integer(),
          tools: non_neg_integer(),
          due: boolean(),
          quota_refused: boolean(),
          counted_commands: MapSet.t(),
          seen: MapSet.t()
        }

  @doc "Builds bound state from a granted lease (struct or atom-keyed map)."
  @spec new(ExecutionLease.t() | map()) :: t()
  def new(%ExecutionLease{} = lease) do
    %__MODULE__{
      grant_id: lease.grant_id,
      run_id: lease.run_id,
      response_budget: lease.response_budget,
      tool_budget: lease.tool_budget,
      response_reserve: lease.reserves.response,
      tool_reserve: lease.reserves.tool,
      checkpoint_cadence: lease.checkpoint_cadence
    }
  end

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      grant_id: Map.fetch!(attrs, :grant_id),
      run_id: Map.fetch!(attrs, :run_id),
      response_budget: Map.fetch!(attrs, :response_budget),
      tool_budget: Map.fetch!(attrs, :tool_budget),
      response_reserve: Map.fetch!(attrs, :response_reserve),
      tool_reserve: Map.fetch!(attrs, :tool_reserve),
      checkpoint_cadence: Map.fetch!(attrs, :checkpoint_cadence)
    }
  end

  @doc """
  Starts a new spend epoch from a renewed grant (Elf lease re-loop).

  Resets the spend counters and the due latch so a later exhaustion
  re-fires the edge-triggered `:renewal_due` effect and the full
  due → stop → re-evaluate sequence. Budgets, grant/run identity, and the
  already-seen set are kept: events counted in an earlier epoch are never
  double-spent, and command correlation (`counted_commands`) carries over because item ids are unique per call.
  """
  @spec new_epoch(t()) :: t()
  def new_epoch(%__MODULE__{} = state) do
    %{
      state
      | epoch: state.epoch + 1,
        responses: 0,
        tools: 0,
        due: false,
        quota_refused: false
    }
  end

  @doc "True once spend has reached one reserve before a budget (D7)."
  @spec due?(t()) :: boolean()
  def due?(%__MODULE__{} = state) do
    state.responses >= state.response_budget - state.response_reserve or
      state.tools >= state.tool_budget - state.tool_reserve or
      state.responses >= state.checkpoint_cadence
  end

  @doc """
  The nearest renewal boundary and how far away it is (a D7 projection).

  Reports which of the three `due?/1` conditions is closest and how much
  spend remains before it fires: the checkpoint cadence, and each budget
  taken one reserve early. Ties resolve in that order
  (`Enum.min_by/2` returns the first minimum). `remaining` is clamped at
  zero and `reached?` is exactly `due?/1`, so a read model built on this
  can never disagree with the latch that fires renewal.

  Pure and clock-free: a projection of state the lease already holds, not
  a new bound.
  """
  @spec next_boundary(t()) :: boundary()
  def next_boundary(%__MODULE__{} = state) do
    {bound, unit, remaining} =
      [
        {:checkpoint_cadence, :responses, state.checkpoint_cadence - state.responses},
        {:response_budget, :responses,
         state.response_budget - state.response_reserve - state.responses},
        {:tool_budget, :tools, state.tool_budget - state.tool_reserve - state.tools}
      ]
      |> Enum.min_by(fn {_bound, _unit, remaining} -> remaining end)

    %{bound: bound, unit: unit, remaining: max(remaining, 0), reached?: due?(state)}
  end

  @doc """
  Folds one normalized event into bound state, returning `{state, effects}`.

  Effects are `:renewal_due` (edge-triggered) and `:quota_refused`
  (Codex quota fast path, zero spend). Events for another run must be
  filtered by the caller (`drain/3` does this).
  """
  @spec advance(t(), HarnessEvent.t()) :: {t(), [effect()]}
  def advance(%__MODULE__{} = state, %HarnessEvent{} = event) do
    cond do
      quota_refused?(event) ->
        {%{state | quota_refused: true}, [:quota_refused]}

      MapSet.member?(state.seen, event.source_event_id) ->
        {state, []}

      true ->
        state
        |> mark_seen(event)
        |> spend(event)
        |> emit_due(state)
    end
  end

  @doc """
  Folds the live normalized-event buffer for one `run_id`.

  Events carrying another `run_id` are ignored; effects accumulate in order.
  """
  @spec drain(t(), Ecto.UUID.t(), Enumerable.t()) :: {t(), [effect()]}
  def drain(%__MODULE__{} = state, run_id, events) do
    Enum.reduce(events, {state, []}, fn event, {state, effects} ->
      if event.run_id == run_id do
        {state, new_effects} = advance(state, event)
        {state, effects ++ new_effects}
      else
        {state, effects}
      end
    end)
  end

  @doc """
  Folds durable `harness.event_recorded` payloads for one `run_id`.

  The read-model twin of `drain/3`, for callers that rebuild spend from
  the trajectory log instead of the live buffer. Each payload map is
  rehydrated into the fields the D4 counting rules read — `kind`,
  `source_event_id`, `extensions`, and the `:quota_refused` error
  category — and folded through the same `advance/2`, so the projection
  counts exactly like the live fold. Payloads that cannot be rehydrated
  are skipped rather than miscounted.

  The rehydration matches the Elf's own (`Shoestring.Elves.Elf` requires
  `extensions` to be a map and drops the event otherwise), so the page can
  never show a boundary nearer than the Elf believes. `occurred_at` is
  carried through when the payload parses, else a fixed sentinel: no
  counting rule reads it.
  """
  @spec drain_persisted(t(), Ecto.UUID.t(), Enumerable.t()) :: {t(), [effect()]}
  def drain_persisted(%__MODULE__{} = state, run_id, payloads) do
    drain(state, run_id, Enum.flat_map(payloads, &persisted_event(&1, run_id)))
  end

  # ----------------------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------------------

  @sentinel_time ~U[1970-01-01 00:00:00.000000Z]

  defp persisted_event(payload, run_id) when is_map(payload) do
    with kind when not is_nil(kind) <- persisted_kind(payload),
         source when is_binary(source) <- payload["source_event_id"],
         extensions when is_map(extensions) <- payload["extensions"] do
      [
        %HarnessEvent{
          version: 1,
          run_id: payload["run_id"] || run_id,
          source_event_id: source,
          ordinal: payload["ordinal"] || 1,
          occurred_at: persisted_time(payload),
          kind: kind,
          process_id: nil,
          provider_session_id: nil,
          artifact_id: nil,
          capacity_snapshot_id: nil,
          error: persisted_error(payload),
          result: nil,
          extensions: extensions
        }
      ]
    else
      _other -> []
    end
  end

  defp persisted_event(_payload, _run_id), do: []

  defp persisted_kind(payload) do
    case payload["kind"] do
      kind when is_binary(kind) ->
        atom = String.to_existing_atom(kind)
        if atom in HarnessEvent.kinds(), do: atom, else: nil

      _other ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp persisted_time(payload) do
    case payload["occurred_at"] do
      at when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, time, _offset} -> time
          _error -> @sentinel_time
        end

      %DateTime{} = at ->
        at

      _other ->
        @sentinel_time
    end
  end

  defp persisted_error(%{"kind" => "error", "error" => %{"category" => "quota_refused"} = error}) do
    Error.new(
      :quota_refused,
      error["code"] || "quota_refused",
      error["message"] || "quota refused",
      details: %{}
    )
  end

  defp persisted_error(_payload), do: nil

  defp quota_refused?(%HarnessEvent{kind: :error, error: %Error{category: :quota_refused}}),
    do: true

  defp quota_refused?(_event), do: false

  defp mark_seen(state, event) do
    %{state | seen: MapSet.put(state.seen, event.source_event_id)}
  end

  defp spend(state, %HarnessEvent{kind: :output, extensions: extensions}) do
    if message_completion?(extensions), do: %{state | responses: state.responses + 1}, else: state
  end

  # A tool START is not a spend and therefore not a boundary: counting it
  # let a passed deadline decline the lease — checkpoint, suspend, stop — at
  # the START of a Codex `fileChange`, with the file write still in flight
  # (live, final-acceptance.md §5.2).
  defp spend(state, %HarnessEvent{kind: :tool} = event) do
    if tool_start?(event.extensions), do: state, else: %{state | tools: state.tools + 1}
  end

  defp spend(state, %HarnessEvent{kind: :command} = event) do
    item_id = correlation_id(event)

    if command_completion?(event) do
      if MapSet.member?(state.counted_commands, item_id) do
        state
      else
        %{
          state
          | tools: state.tools + 1,
            counted_commands: MapSet.put(state.counted_commands, item_id)
        }
      end
    else
      state
    end
  end

  defp spend(state, _event), do: state

  defp emit_due(state, previous) do
    if due?(state) and not previous.due do
      {%{state | due: true}, [:renewal_due]}
    else
      {%{state | due: due?(state)}, []}
    end
  end

  # An `:output` message completion carries message text. Codex
  # `item/started` agentMessages are kind `:output` without text (START
  # markers) and never count, exactly like delta frames.
  defp message_completion?(extensions) when is_map(extensions) do
    not delta?(extensions) and has_text?(extensions)
  end

  defp message_completion?(_extensions), do: false

  defp has_text?(extensions) do
    Enum.any?(extensions, fn {key, _value} ->
      key_string = to_string(key)

      key_string == "text" or String.ends_with?(key_string, ":text") or
        String.ends_with?(key_string, ":output_text")
    end)
  end

  defp delta?(extensions) when is_map(extensions) do
    Enum.any?(extensions, fn {key, _value} ->
      key == "delta" or String.ends_with?(to_string(key), ":delta")
    end) or method(extensions) == "item/agentMessage/delta"
  end

  defp delta?(_extensions), do: false

  defp method(extensions) do
    extensions["codex-app-server:method"] || extensions["method"]
  end

  @start_statuses ["inProgress", "in_progress", "started", "pending", "running"]

  defp tool_start?(extensions) when is_map(extensions) do
    status =
      extensions["claude-headless:status"] || extensions["codex-app-server:status"] ||
        extensions["status"]

    boundary(extensions) == "start" or status in @start_statuses
  end

  defp tool_start?(_extensions), do: false

  defp command_completion?(%HarnessEvent{extensions: extensions}) do
    boundary(extensions) == "end" or completion_status?(extensions) or exit_code?(extensions)
  end

  defp boundary(extensions) do
    extensions["claude-headless:boundary"] || extensions["boundary"]
  end

  defp completion_status?(extensions) do
    status =
      extensions["claude-headless:status"] || extensions["codex-app-server:status"] ||
        extensions["status"]

    status in ["completed", "complete", "success", "failed", "error"]
  end

  defp exit_code?(extensions) do
    Enum.any?(extensions, fn {key, value} ->
      (key == "exit_code" or String.ends_with?(to_string(key), ":exit_code")) and
        not is_nil(value)
    end)
  end

  defp correlation_id(%HarnessEvent{extensions: extensions, source_event_id: source_id}) do
    extensions["claude-headless:tool_use_id"] || extensions["codex-app-server:item_id"] ||
      extensions["item_id"] || source_id
  end
end
