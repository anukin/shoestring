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

  # Sentinel for a genuine tool start that carries no usable identity: it
  # blocks the boundary like any open tool but matches no completion, so
  # only a turn outcome (`:result` / `:error`) clears it. A string id can
  # never collide with it.
  @unidentified_start :lease_open_unidentified_tool

  # Item types that are model or user content, never mutating tools. Used
  # to recognize unknown normalizer-fallback shapes as potential tools.
  @non_tool_item_types ["reasoning", "thought", "thinking", "agentMessage", "userMessage"]

  @doc """
  Shared tool-identity resolver over string-keyed maps (raw provider items
  and normalized extensions alike).
  Returns the first present provider-native identity —
  `claude-headless:tool_use_id`, `codex-app-server:item_id`, `item_id`, or
  raw `id` — skipping blank values consistently, or `nil` when no usable
  identity exists. Opening and closing use this same resolver, so a blank
  id can neither open a phantom entry nor close a real one.
  """
  @spec tool_identity(map()) :: String.t() | nil
  def tool_identity(map) when is_map(map) do
    [
      map["claude-headless:tool_use_id"],
      map["codex-app-server:item_id"],
      map["item_id"],
      map["id"]
    ]
    |> Enum.find(&present?/1)
  end

  def tool_identity(_other), do: nil

  @doc """
  Folds one normalized event into an identity-keyed open set of
  still-running tool items.

  Opening and closing follow the EXPLICIT lifecycle boundary recorded by
  the normalizer (`codex-app-server:boundary`, `claude-headless:boundary`,
  or generic `boundary`, each start/end) — never inferred from status
  spelling:

  - `:command` / `:tool` with a start marker opens by identity; a genuine
    start without a usable identity opens the unidentified-start sentinel
    instead, which fails closed until the natural terminal clears it.
  - `:command` / `:tool` with an end marker closes by identity,
    independent of status spelling.
  - `:lifecycle` carrying an unknown-tool start/end marker (Codex
    normalizer fallback for shapes like `mcpToolCall`/`webSearch`, or any
    future mutating shape) tracks exactly like a tool; reasoned content,
    messages, and user input never carry such markers.
  - Marker-less `:command` / `:tool` / `:lifecycle` shapes are synthetic
    or degraded evidence, not observed lifecycle: they neither open nor
    close (spend counting keeps its own status-spelling rules, unchanged).
  - `:result` / `:error` are turn outcomes: they clear the whole set,
    including the sentinel, so dropped or late completions can never wedge
    a later turn.

  Pure and idempotent: an unknown id closes nothing, duplicate starts open
  once. The Elf folds both the live buffer and the durable rebuild through
  this function so the two views can never disagree.
  """
  @spec track_open_tools(MapSet.t(), HarnessEvent.t()) :: MapSet.t()
  def track_open_tools(_open, %HarnessEvent{kind: kind})
      when kind in [:result, :error] do
    MapSet.new()
  end

  def track_open_tools(open, %HarnessEvent{kind: kind} = event)
      when kind in [:command, :tool] do
    case explicit_boundary(event) do
      :start ->
        case tool_identity(event.extensions) do
          nil -> MapSet.put(open, @unidentified_start)
          id -> MapSet.put(open, id)
        end

      :end ->
        case tool_identity(event.extensions) do
          nil -> open
          id -> MapSet.delete(open, id)
        end

      nil ->
        open
    end
  end

  def track_open_tools(open, %HarnessEvent{kind: :lifecycle} = event) do
    case explicit_boundary(event) do
      :start ->
        if unknown_tool_shape?(event) do
          case tool_identity(event.extensions) do
            nil -> MapSet.put(open, @unidentified_start)
            id -> MapSet.put(open, id)
          end
        else
          open
        end

      :end ->
        if unknown_tool_shape?(event) do
          case tool_identity(event.extensions) do
            nil -> open
            id -> MapSet.delete(open, id)
          end
        else
          open
        end

      nil ->
        open
    end
  end

  def track_open_tools(open, _event), do: open

  @doc """
  Folds one normalized event into model-control evidence
  `{tools_seen?, model_control?}` for the safe-renewal boundary:

  - A marked tool start/end (`:command`, `:tool`, or unknown-tool
    `:lifecycle`) records genuine tool activity and invalidates control:
    `{true, false}`. Marker-less shapes are synthetic evidence and leave
    both flags untouched.
  - An `:output` delta proves the model is generating text: `{seen, true}`.
  - An `:output` completion (message text with no delta) establishes
    control on a turn with no tool activity yet, and otherwise preserves
    whatever control holds. Preservation is safe: any intervening genuine
    tool lifecycle resets control first, so `true` always means no tool
    activity since the last fresh evidence. A completion that immediately
    precedes the next tool call (committed trace: commentary 139 →
    command 140) therefore cannot re-arm the boundary on its own.
  - An `:output` start (commentary with no text yet) invalidates:
    `{seen, false}` — narration routinely precedes the next tool call.
  - `:result` / `:error` outcomes reset control to false.
  - Everything else leaves both flags untouched.

  Pure; the Elf folds live and durable events through it exactly like the
  open set.
  """
  @spec track_control({boolean(), boolean()}, HarnessEvent.t()) :: {boolean(), boolean()}
  def track_control({_seen, _control} = state, %HarnessEvent{kind: kind})
      when kind in [:result, :error] do
    {elem(state, 0), false}
  end

  def track_control({seen, control}, %HarnessEvent{kind: :output} = event) do
    cond do
      delta?(event.extensions) ->
        {seen, true}

      message_completion?(event.extensions) ->
        # Establish control on a pristine turn; otherwise preserve it.
        # Preservation is safe because any intervening genuine tool
        # lifecycle resets control first, so `true` here always means no
        # tool activity since the last fresh evidence.
        {seen, control or not seen}

      true ->
        {seen, false}
    end
  end

  def track_control({seen, control}, %HarnessEvent{kind: kind} = event)
      when kind in [:command, :tool] do
    if explicit_boundary(event) == nil do
      {seen, control}
    else
      {true, false}
    end
  end

  def track_control(state, %HarnessEvent{kind: :lifecycle} = event) do
    if explicit_boundary(event) != nil and unknown_tool_shape?(event) do
      {true, false}
    else
      state
    end
  end

  def track_control(state, _event), do: state

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

  # The explicit lifecycle marker recorded by the normalizer from the raw
  # RPC method — never inferred from status spelling. Reads the Codex
  # namespaced marker first, then the Claude and generic conventions.
  defp explicit_boundary(%HarnessEvent{extensions: extensions}) do
    case extensions["codex-app-server:boundary"] || extensions["claude-headless:boundary"] ||
           extensions["boundary"] do
      "start" -> :start
      "end" -> :end
      _other -> nil
    end
  end

  # An unknown Codex item shape (normalizer `:lifecycle` fallback) is
  # treated as a potentially mutating tool unless its recorded type is a
  # known non-tool. Shapes without any recorded type are provider
  # bookkeeping, not tool lifecycle.
  defp unknown_tool_shape?(%HarnessEvent{extensions: extensions}) do
    case extensions["codex-app-server:item_type"] || extensions["item_type"] do
      nil -> false
      type -> type not in @non_tool_item_types
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
