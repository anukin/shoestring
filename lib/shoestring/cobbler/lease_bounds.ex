defmodule Shoestring.Cobbler.LeaseBounds do
  @moduledoc """
  Pure execution-lease bound advancement over normalized harness events
  (Milestone 05, work package C).

  Bound counting (D4):

  - 1 response per `:output` message completion. Delta frames (Codex
    `item/agentMessage/delta`, or any extension key ending in `:delta`) never
    count.
  - 1 tool per `:tool` event, or per `:command` START→END completion.
    A START alone never counts; an END completion counts once per correlated
    item (START observed or not — the END is the spend boundary, and duplicate
    ENDs do not double-spend).
  - `:lifecycle`, `:artifact`, `:capacity`, `:error`, and `:result` events
    never spend. In particular a Codex `:quota_refused` error emits the
    `:quota_refused` fast-path marker with zero spend, and a Claude
    `:task_failed` error spends nothing (by design, Claude errors never map
    to quota).

  Renewal-due (D7) fires one reserve early: `responses >= response_budget -
  response_reserve` OR `tools >= tool_budget - tool_reserve` OR the checkpoint
  cadence reached (`responses >= checkpoint_cadence`). The `:renewal_due`
  marker is edge-triggered: it is emitted once, on the transition into due.

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
    responses: 0,
    tools: 0,
    due: false,
    quota_refused: false,
    pending_starts: MapSet.new(),
    counted_commands: MapSet.new(),
    seen: MapSet.new()
  ]

  @type effect :: :renewal_due | :quota_refused

  @type t :: %__MODULE__{
          grant_id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t(),
          response_budget: pos_integer(),
          tool_budget: pos_integer(),
          response_reserve: non_neg_integer(),
          tool_reserve: non_neg_integer(),
          checkpoint_cadence: pos_integer(),
          responses: non_neg_integer(),
          tools: non_neg_integer(),
          due: boolean(),
          quota_refused: boolean(),
          pending_starts: MapSet.t(),
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

  @doc "True once spend has reached one reserve before a budget (D7)."
  @spec due?(t()) :: boolean()
  def due?(%__MODULE__{} = state) do
    state.responses >= state.response_budget - state.response_reserve or
      state.tools >= state.tool_budget - state.tool_reserve or
      state.responses >= state.checkpoint_cadence
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

  # ----------------------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------------------

  defp quota_refused?(%HarnessEvent{kind: :error, error: %Error{category: :quota_refused}}),
    do: true

  defp quota_refused?(_event), do: false

  defp mark_seen(state, event) do
    %{state | seen: MapSet.put(state.seen, event.source_event_id)}
  end

  defp spend(state, %HarnessEvent{kind: :output, extensions: extensions}) do
    if message_completion?(extensions), do: %{state | responses: state.responses + 1}, else: state
  end

  defp spend(state, %HarnessEvent{kind: :tool}) do
    %{state | tools: state.tools + 1}
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
      %{state | pending_starts: MapSet.put(state.pending_starts, item_id)}
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
