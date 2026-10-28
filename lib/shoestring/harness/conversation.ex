defmodule Shoestring.Harness.Conversation do
  @moduledoc """
  A long-lived coordinator session driven from code (iteration 15, the
  `:converse` capability in `Shoestring.Harnesses`).

  An `Adapter` runs one task to completion; a conversation stays open and
  takes one turn per message. A conversation module is a process started
  with a spec:

    * `:owner` (required) — receives `{:conversation_event, pid, event}`
      for every `Shoestring.Harness.ConversationEvent`, in order.
    * `:workdir` (required) — the repository the coordinator reads.
    * `:model` (required) — never defaulted; a missing or refused model
      fails the start instead of running the harness's own default.
    * `:effort` — the harness's effort level, or nil.
    * `:instructions` — text added to the harness's own system prompt.
    * `:tools` — `%{url: url, token: token}` for Shoestring's MCP tool
      endpoint, or nil for none.
    * `:resume` — a provider session id to continue, or nil.

  Rules every implementation keeps (the conversation contract suite checks
  them against Fake and scripted transports):

    * One turn at a time. `send_turn/3` while a turn runs is refused with
      `turn_in_progress`; nothing is queued here. Phase 0 found the CLIs
      disagree mid-turn (Claude queues, Codex merges and drops the in-flight
      reply, opencode rejects), so the caller holds messages and sends only
      while idle.
    * Every accepted turn ends with exactly one `:turn_completed` event
      (`:completed`, `:interrupted` or `:failed`), unless the session closes
      first: then `:closed` names the turn left open, whose outcome is
      unknown. Nothing retries a turn.
    * `cancel_turn/1` interrupts the running turn and leaves the session
      open; with no turn running it does nothing.
    * `close/1` ends the session and reaps every process it started. It is
      safe to call twice. The last event is always `:closed`.
    * Events carry visible text, tool names and usage only. Hidden reasoning,
      tool inputs and raw provider frames are never forwarded.
  """

  alias Shoestring.Harness.Error

  @type spec :: %{
          required(:owner) => pid(),
          required(:workdir) => Path.t(),
          required(:model) => String.t(),
          optional(:effort) => String.t() | nil,
          optional(:instructions) => String.t() | nil,
          optional(:tools) => %{url: String.t(), token: String.t()} | nil,
          optional(:resume) => String.t() | nil
        }

  @callback start_link(spec(), keyword()) :: GenServer.on_start()
  @callback send_turn(pid(), turn_id :: String.t(), text :: String.t()) ::
              :ok | {:error, Error.t()}
  @callback cancel_turn(pid()) :: :ok
  @callback close(pid()) :: :ok
  @callback status(pid()) :: %{
              required(:state) => :starting | :idle | :in_turn | :closed,
              required(:turn_id) => String.t() | nil,
              required(:provider_session_id) => String.t() | nil
            }

  @doc "The refusal for a turn sent while another runs."
  @spec turn_in_progress(String.t()) :: Error.t()
  def turn_in_progress(running),
    do:
      Error.new(:invalid_transition, "turn_in_progress", "A turn is already running",
        details: %{"shoestring.conversation:turn_id" => running}
      )

  @doc "The refusal for a turn sent after the session closed."
  @spec closed() :: Error.t()
  def closed,
    do: Error.new(:invalid_transition, "conversation_closed", "The conversation is closed")

  @doc "Validates a spec's required keys before anything is started."
  @spec validate(map()) :: :ok | {:error, Error.t()}
  def validate(spec) when is_map(spec) do
    cond do
      not is_pid(Map.get(spec, :owner)) ->
        invalid("owner_required", "A conversation needs an owner process")

      not (is_binary(Map.get(spec, :model)) and Map.get(spec, :model) != "") ->
        invalid("model_required", "A conversation needs an explicit model")

      not (is_binary(Map.get(spec, :workdir)) and File.dir?(Map.get(spec, :workdir))) ->
        invalid("invalid_workdir", "A conversation needs an existing working directory")

      not valid_tools?(Map.get(spec, :tools)) ->
        invalid("invalid_tools", "The tool endpoint needs a loopback http URL and a token")

      true ->
        :ok
    end
  end

  defp valid_tools?(nil), do: true

  defp valid_tools?(%{url: url, token: token}) when is_binary(url) and is_binary(token) do
    token != "" and
      match?(
        %URI{scheme: "http", host: host} when host in ["127.0.0.1", "localhost", "::1"],
        URI.parse(url)
      )
  end

  defp valid_tools?(_), do: false

  defp invalid(code, message), do: {:error, Error.new(:schema_incompatible, code, message)}
end
