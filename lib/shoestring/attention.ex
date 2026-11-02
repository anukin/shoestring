defmodule Shoestring.Attention do
  @moduledoc """
  What needs the person now, built in one place for every screen that shows
  it (iteration 17, phase 2): the Sessions page, the nav's count and the
  chat screen's asks.

  Two kinds today:

    * an ask a worker is waiting on (`Shoestring.PermissionAsks`), answered
      with `answer/5`;
    * a held dispatch, one whose provider's remaining usage could not be
      confirmed (`Shoestring.Dispatches.confirm_hold/3`), started with
      `start_held/3`.

  Each item carries the words the chat screen's popups use and the choices
  that answer it. Nothing here decides anything by itself: an item stays
  until the person answers it or its work ends.

  Anything that changes the list broadcasts `{:attention_changed,
  session_id}` on `topic/0`: an ask recorded or settled, and a held dispatch
  started. A hold itself appears when an admission is decided, which nothing
  broadcasts, so a screen that shows the count also re-reads it on a timer.
  """

  alias Shoestring.{AgentProfiles, Dispatches, PermissionAsks, Sessions}
  alias Shoestring.PermissionAsks.Ask

  @topic "attention"
  @max_note 500

  def topic, do: @topic

  @doc "Tells every screen showing attention that `session_id`'s list may have changed."
  def changed(session_id),
    do: Phoenix.PubSub.broadcast(Shoestring.PubSub, @topic, {:attention_changed, session_id})

  @doc """
  Everything in `session_id` that needs the person: its asks, oldest first,
  then its holds. `states` (dispatch id to `Shoestring.Dispatches.state/2`)
  spares re-deriving states a caller already has.
  """
  def items(session_id, states \\ %{}), do: asks(session_id) ++ held(session_id, states)

  @doc "The asks `session_id`'s workers are waiting on, as items."
  def asks(session_id), do: Enum.map(PermissionAsks.pending(session_id), &ask_item/1)

  @doc "`session_id`'s held dispatches, as items."
  def held(session_id, states \\ %{}) do
    for dispatch <- Dispatches.list(session_id),
        dispatch.state == "started",
        (states[dispatch.id] || Dispatches.state(dispatch)) == "held",
        do: held_item(dispatch)
  end

  @doc """
  How many things need the person: every ask a worker is waiting on, and the
  held dispatches of the sessions the Sessions page lists (`session_days`).
  """
  def count do
    asks = PermissionAsks.pending()

    sessions =
      Sessions.recent(AgentProfiles.settings().session_days, DateTime.utc_now(), counts: false).sessions

    length(asks) + Enum.sum_by(sessions, &length(held(&1.session_id)))
  end

  # -- Answering -----------------------------------------------------------------

  @doc """
  The person's answer to an ask of `session_id`: `"allow"`, `"allow_agent"`
  or `"deny"`, with an optional `note` that tells the worker why it was
  denied. The first answer wins, from whichever screen: a later one is
  `{:error, :not_pending}`. `{:error, :ask_not_found}` for an ask of
  another session, and `:not_ruleable` for "allow for this agent" on an ask
  a rule cannot cover (a network ask, a file change or a compound command).
  """
  def answer(session_id, ask_id, decision, by, note \\ nil)

  def answer(session_id, ask_id, decision, by, note) when is_binary(ask_id) do
    case Shoestring.Repo.get(Ask, ask_id) do
      %Ask{session_id: ^session_id} = ask when is_binary(session_id) ->
        if decision == "allow_agent" and not for_agent?(ask) do
          {:error, :not_ruleable}
        else
          PermissionAsks.decide(ask.id, decision, by, clip(note))
        end

      _ ->
        {:error, :ask_not_found}
    end
  end

  def answer(_session_id, _ask_id, _decision, _by, _note), do: {:error, :ask_not_found}

  @doc """
  The person starts a held dispatch of `session_id`: their confirmation,
  spending none of the grant's pre-approvals. `:confirmed`, `:none` (it is
  not held any more) or `{:error, reason}`.
  """
  def start_held(session_id, dispatch_id, by) do
    case Dispatches.get(dispatch_id) do
      %{session_id: ^session_id} = dispatch when is_binary(session_id) ->
        result = Dispatches.confirm_hold(dispatch, by)
        if result == :confirmed, do: changed(session_id)
        result

      _ ->
        {:error, :dispatch_not_found}
    end
  end

  # -- Items -----------------------------------------------------------------------

  @doc "Whether \"allow for this agent\" is offered: one plain command an agent's rule may cover."
  def for_agent?(%Ask{kind: "network"}), do: false
  def for_agent?(%Ask{rule_key: key, agent: agent}), do: is_binary(key) and is_binary(agent)

  defp ask_item(%Ask{} = ask) do
    network? = ask.kind == "network"

    %{
      id: "ask-" <> ask.id,
      kind: :ask,
      ask: ask,
      dispatch_id: ask.dispatch_id,
      agent: ask.agent,
      at: ask.inserted_at,
      title:
        if(network?,
          do: "A worker asks to reach a host not on its list",
          else: "A worker asks to run a command outside its sandbox"
        ),
      summary:
        if(network?,
          do: ask.command,
          else: "Run outside its sandbox: " <> ask.command
        ),
      subject: if(ask.kind == "command", do: "$ " <> ask.command, else: ask.command),
      why: ask.reason,
      note: ask_note(ask),
      choices: ask_choices(ask)
    }
  end

  defp ask_note(%Ask{kind: "network"}),
    do:
      "Allowing lets its commands reach this host for the rest of this run. To allow it for " <>
        "every run, add it to the agent's hosts. It waits for you: nothing decides this on a timer."

  defp ask_note(%Ask{kind: "file_change"}),
    do:
      "Allowing lets it make this change outside its sandbox. It waits for you: nothing " <>
        "decides this on a timer."

  defp ask_note(%Ask{provider: provider}),
    do:
      "Allowing runs this one command with full access to your files, anywhere you can write; " <>
        if(provider == "codex",
          do: "its network stays as the agent's settings allow.",
          else: "it runs with no sandbox, network included."
        ) <> " It waits for you: nothing decides this on a timer."

  defp ask_choices(%Ask{kind: "network"}),
    do: [{"allow", "Allow for this run"}, {"deny", "Deny"}]

  defp ask_choices(ask) do
    [{"allow", "Allow once"}] ++
      if(for_agent?(ask), do: [{"allow_agent", "Allow for this agent"}], else: []) ++
      [{"deny", "Deny"}, {"deny_reason", "Deny with a reason"}]
  end

  defp held_item(dispatch) do
    %{
      id: "held-" <> dispatch.id,
      kind: :held,
      dispatch: dispatch,
      dispatch_id: dispatch.id,
      agent: dispatch.agent,
      at: dispatch.inserted_at,
      title: "Start this held dispatch?",
      summary: "Start held dispatch: " <> dispatch.title,
      subject: dispatch.title,
      why: nil,
      note:
        "Its provider's remaining usage could not be confirmed. Starting it is your " <>
          "confirmation; none of the grant's pre-approvals is spent.",
      choices: [{"start", "Start it"}]
    }
  end

  defp clip(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      text -> String.slice(text, 0, @max_note)
    end
  end

  defp clip(_note), do: nil
end
