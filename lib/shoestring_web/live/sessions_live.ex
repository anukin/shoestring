defmodule ShoestringWeb.SessionsLive do
  @moduledoc """
  Sessions: every coordinator session of the last few days
  (`session_days` in Settings), and one session's page. A session page lists
  its agents. Picking one shows its dispatches, and an open dispatch shows a
  feed of what its worker ran, changed and wrote, with Shoestring's own steps.
  The coordinator's panel has the same shape: its turns, the tools it used
  and both sides' messages.

  What needs the person (`Shoestring.Attention`) is listed at the top, and
  answered on the dispatch it belongs to with the chat screen's choices: an
  ask is allowed once, allowed for its agent, denied, or denied with a
  reason; a held dispatch is started. The first answer wins, from whichever
  screen. A stopped dispatch (a merge stopped, a review blocked, a lost
  worker) says what happened and gives the commands that decide it in a
  terminal. Nothing else on the page acts.

  An agent whose dispatch finished while the page was open shows a green dot
  until it is opened: news, not something that needs the person.

  It updates as the work moves: an ask or an event committed for the open
  dispatch refreshes it at once, and a two-second tick covers what
  Shoestring does not broadcast (EXPLORE and REVIEW progress, dispatch
  states, a dispatch becoming held).
  """
  use ShoestringWeb, :live_view
  on_mount ShoestringWeb.NeedsYou

  alias Phoenix.LiveView.JS

  alias Shoestring.{
    AgentProfiles,
    Agents,
    Attention,
    Conversations,
    Harnesses,
    PermissionAsks,
    Sessions,
    Trajectory
  }

  alias Shoestring.CLI.WorkLoop
  alias ShoestringWeb.{AttentionComponents, ChatDispatches, SessionActivity}

  @tick_ms 2_000
  @refresh_ms 200
  @filters [
    {"all", "All"},
    {"command", "Commands"},
    {"file", "Files"},
    {"message", "Messages"},
    {"step", "Shoestring"}
  ]
  @coordinator_filters [
    {"all", "All"},
    {"tool", "Tools"},
    {"message", "Messages"},
    {"step", "Shoestring"}
  ]

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, current_scope: nil, page_title: "Sessions")

    case socket.assigns.live_action do
      :index ->
        {:ok, load_index(socket)}

      :show ->
        id = params["session_id"]

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Shoestring.PubSub, PermissionAsks.topic(id))
          Process.send_after(self(), :tick, @tick_ms)
        end

        {:ok,
         socket
         |> assign(
           session_id: id,
           page_title: "Session #{id}",
           filter: "all",
           cache: %{},
           topics: MapSet.new(),
           refresh_pending: false,
           fingerprint: nil,
           agent_key: nil,
           open_id: nil,
           items: [],
           changes: nil,
           seen: nil,
           reason_for: nil,
           reason_error: nil
         )
         |> stream_configure(:feed, dom_id: &"feed-#{&1.id}")
         |> stream(:feed, [])}
    end
  end

  # -- The list ------------------------------------------------------------------

  defp load_index(socket) do
    settings = AgentProfiles.settings()
    recent = Sessions.recent(settings.session_days)

    assign(socket,
      settings: settings,
      days: settings.session_days,
      days_error: nil,
      sessions: recent.sessions,
      hidden: recent.hidden,
      now: DateTime.utc_now()
    )
  end

  @impl true
  def handle_event("days", %{"days" => value}, socket) do
    case Integer.parse(to_string(value)) do
      {days, ""} ->
        case AgentProfiles.save_settings(socket.assigns.settings, %{"session_days" => days}) do
          {:ok, _} ->
            {:noreply, load_index(socket)}

          {:error, changeset} ->
            {:noreply, assign(socket, days: value, days_error: days_error(changeset))}
        end

      _ ->
        {:noreply,
         assign(socket, days: value, days_error: "Enter a whole number of days from 1 to 365.")}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    if filter in Enum.map(@filters ++ @coordinator_filters, &elem(&1, 0)) do
      {:noreply, socket |> assign(filter: filter, fingerprint: nil) |> load_feed()}
    else
      {:noreply, socket}
    end
  end

  # -- Answering what needs you --------------------------------------------------

  def handle_event("answer", %{"ask" => id, "decision" => decision}, socket)
      when decision in ["allow", "allow_agent", "deny"] do
    {:noreply, answered(socket, id, decision, nil)}
  end

  def handle_event("reason", %{"ask" => id}, socket),
    do: {:noreply, assign(socket, reason_for: id, reason_error: nil)}

  def handle_event("reason_back", _params, socket),
    do: {:noreply, assign(socket, reason_for: nil, reason_error: nil)}

  def handle_event("deny_reason", %{"ask" => id, "note" => note}, socket) do
    if String.trim(to_string(note)) == "" do
      {:noreply,
       assign(socket, reason_error: "Write the reason the worker is told, or choose Deny.")}
    else
      {:noreply, answered(socket, id, "deny", note)}
    end
  end

  # A decision a plan waits on (iteration 19): choose a candidate, or
  # "none of these" with the note it needs. The first answer wins.
  def handle_event("choose", %{"decision" => id, "choice" => choice}, socket),
    do: {:noreply, decided(socket, id, choice, nil)}

  def handle_event("reject_decision", %{"decision" => id, "note" => note}, socket) do
    if String.trim(to_string(note)) == "" do
      {:noreply, assign(socket, reason_error: "Say why none of these will do.")}
    else
      {:noreply, decided(socket, id, "reject", note)}
    end
  end

  def handle_event("start_held", %{"dispatch" => id}, socket) do
    socket =
      case Attention.start_held(socket.assigns.session_id, id, WorkLoop.default_human()) do
        :confirmed ->
          put_flash(socket, :info, "Started: it runs as soon as its provider admits it.")

        :none ->
          put_flash(socket, :error, "It is not held any more.")

        {:error, reason} ->
          put_flash(socket, :error, refusal(reason))
      end

    {:noreply, refresh(socket)}
  end

  defp answered(socket, id, decision, note) do
    session = socket.assigns.session_id

    socket =
      case Attention.answer(session, id, decision, WorkLoop.default_human(), note) do
        {:ok, ask} -> put_flash(socket, :info, answer_text(ask, decision, note))
        {:error, reason} -> put_flash(socket, :error, refusal(reason))
      end

    socket |> assign(reason_for: nil, reason_error: nil) |> refresh()
  end

  defp decided(socket, id, choice, note) do
    socket =
      case Attention.answer_decision(
             socket.assigns.session_id,
             id,
             choice,
             WorkLoop.default_human(),
             note
           ) do
        {:ok, %{state: "rejected"}} ->
          put_flash(socket, :info, "None of these: the task waits for you to decide what next.")

        {:ok, _decision} ->
          put_flash(socket, :info, "Chosen. The next tasks start with it.")

        {:error, reason} ->
          put_flash(socket, :error, ShoestringWeb.DecisionText.refusal(reason))
      end

    socket |> assign(reason_for: nil, reason_error: nil) |> refresh()
  end

  defp answer_text(%{kind: "network"}, "allow", _note), do: "Allowed for the rest of this run."
  defp answer_text(_ask, "allow", _note), do: "Allowed once."

  defp answer_text(ask, "allow_agent", _note),
    do: "Allowed for #{ask.agent} from now on: it is in the agent's allowed commands."

  defp answer_text(_ask, "deny", nil), do: "Denied."
  defp answer_text(_ask, "deny", _note), do: "Denied. The worker is told your reason."

  defp refusal(:not_pending), do: "That was already answered, perhaps in the chat screen."
  defp refusal(:ask_gone), do: "Its worker stopped waiting, so it can no longer be answered."
  defp refusal(:ask_not_found), do: "This session has no such ask."
  defp refusal(:dispatch_not_found), do: "This session has no such dispatch."
  defp refusal(:not_ruleable), do: "A rule can't cover this one. Allow it once instead."
  defp refusal(:agent_gone), do: "Its agent no longer exists. Allow it once instead."

  defp refusal(:too_many_rules),
    do:
      "Its agent has as many allowed commands as it may. Remove one on its page, or allow this once."

  defp refusal(:agent_changed), do: "Its agent changed while you answered. Try again."
  defp refusal(reason), do: "It could not be done (#{reason})."

  defp days_error(changeset) do
    case Keyword.get(changeset.errors, :lock_version) do
      nil -> "Enter a whole number of days from 1 to 365."
      _ -> "Settings changed elsewhere. Reload the page, then try again."
    end
  end

  # -- One session ---------------------------------------------------------------

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: :show}} = socket) do
    case Sessions.get(socket.assigns.session_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "No session has that id.")
         |> push_navigate(to: ~p"/sessions")}

      session ->
        socket = assign(socket, session: session, fingerprint: nil) |> load_status()
        groups = socket.assigns.groups
        agent = Enum.find(groups, &(&1.key == params["agent"])) || default_agent(socket)
        open = open_id(agent, params["dispatch"], socket)

        filter =
          if agent && agent.key != socket.assigns.agent_key,
            do: "all",
            else: socket.assigns.filter

        {:noreply,
         socket
         |> assign(agent_key: agent && agent.key, open_id: open, filter: filter)
         |> mark_seen()
         |> follow()
         |> load_feed()}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh_pending: false) |> refresh()}

  # An ask changed, or the open dispatch's goal committed an event: refresh
  # soon, once for a burst of events.
  def handle_info({:permission_ask, _id}, socket), do: {:noreply, soon(socket)}
  def handle_info({:trajectory_event_committed, _event}, socket), do: {:noreply, soon(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp soon(%{assigns: %{refresh_pending: true}} = socket), do: socket

  defp soon(socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    assign(socket, refresh_pending: true)
  end

  defp refresh(socket) do
    case Sessions.get(socket.assigns.session_id) do
      nil ->
        socket

      session ->
        socket
        |> assign(session: session)
        |> load_status()
        |> mark_seen()
        |> follow()
        |> load_feed()
    end
  end

  # Status lines, chips and the agent list, from the same rows the chat
  # screen's Dispatches pane shows.
  defp load_status(socket) do
    session = socket.assigns.session
    now = DateTime.utc_now()
    {rows, cache} = ChatDispatches.rows(session.session_id, socket.assigns.cache, now)
    states = Map.new(rows, &{&1["dispatch_id"], &1["state"]})
    items = Attention.items(session.session_id, states)

    assign(socket,
      groups: Sessions.agents(session),
      status: Map.new(rows, &{&1["dispatch_id"], &1}),
      cache: cache,
      items: items,
      asks: items |> Enum.filter(&(&1.kind == :ask)) |> Enum.frequencies_by(& &1.dispatch_id),
      coordinator_status: coordinator_status(session),
      now: now
    )
  end

  defp default_agent(socket) do
    groups = socket.assigns.groups

    # A worker that needs you, then one still working, then the coordinator.
    Enum.find(groups, &(needs(&1, socket.assigns) > 0)) ||
      Enum.find(groups, &(&1.kind != "coordinator" and working(&1, socket.assigns) > 0)) ||
      List.first(groups)
  end

  defp open_id(nil, _wanted, _socket), do: nil
  defp open_id(%{kind: "coordinator"}, _wanted, _socket), do: "coordinator"

  defp open_id(agent, wanted, socket) do
    ids = Enum.map(agent.dispatches, & &1.id)

    cond do
      wanted in ids ->
        wanted

      wanted == "none" ->
        nil

      true ->
        newest = Enum.reverse(agent.dispatches)

        case Enum.find(newest, &(not final?(&1, socket.assigns))) || List.first(newest) do
          nil -> nil
          dispatch -> dispatch.id
        end
    end
  end

  # Subscribes to the goals whose committed events move the open feed.
  defp follow(socket) do
    wanted =
      case {current_agent(socket.assigns), socket.assigns.open_id} do
        {%{kind: "coordinator"}, _} ->
          MapSet.new(socket.assigns.session.conversations, &Trajectory.topic(&1.id))

        _ ->
          case open_dispatch(socket.assigns) do
            %{goal_id: goal} when is_binary(goal) -> MapSet.new([Trajectory.topic(goal)])
            _ -> MapSet.new()
          end
      end

    if connected?(socket) do
      for topic <- MapSet.difference(socket.assigns.topics, wanted),
          do: Phoenix.PubSub.unsubscribe(Shoestring.PubSub, topic)

      for topic <- MapSet.difference(wanted, socket.assigns.topics),
          do: Phoenix.PubSub.subscribe(Shoestring.PubSub, topic)

      assign(socket, topics: wanted)
    else
      socket
    end
  end

  defp load_feed(socket) do
    assigns = socket.assigns

    feed =
      case {current_agent(assigns), open_dispatch(assigns)} do
        {%{kind: "coordinator"}, _} ->
          SessionActivity.coordinator(assigns.session.conversations)

        {_agent, nil} ->
          %{rows: [], omitted: 0}

        {_agent, dispatch} ->
          SessionActivity.dispatch(dispatch, final?(dispatch, assigns))
      end

    rows = Enum.filter(feed.rows, &shown?(&1, assigns.filter))
    print = :erlang.phash2({rows, feed.omitted})

    if print == assigns.fingerprint do
      socket
    else
      socket
      |> assign(fingerprint: print, feed_omitted: feed.omitted, changes: changes(assigns))
      |> stream(:feed, rows, reset: true)
    end
  end

  # The open dispatch's worktree: its branch and what changed from its base,
  # uncommitted changes included. Read with a private index copy, so a
  # worker writing the worktree is never disturbed; redacted like the feed.
  defp changes(assigns) do
    with %{id: id} <- open_dispatch(assigns),
         run_id when is_binary(run_id) <- get_in(assigns.status, [id, "run_id"]),
         {:ok, worktree} <- Shoestring.Worktrees.get(run_id) do
      stat =
        case Shoestring.Worktrees.Git.observe(worktree.path, [
               "diff",
               "--stat",
               worktree.base_commit
             ]) do
          {out, 0} -> out |> String.trim_trailing() |> ShoestringWeb.RunPresentation.redact_text()
          _ -> nil
        end

      %{branch: worktree.branch, stat: stat}
    else
      _ -> nil
    end
  end

  defp shown?(_row, "all"), do: true
  defp shown?(%{kind: :ask}, "step"), do: true
  defp shown?(%{kind: :you}, "message"), do: true
  defp shown?(%{kind: kind}, filter), do: Atom.to_string(kind) == filter

  defp coordinator_status(%{conversations: []}), do: nil

  defp coordinator_status(session) do
    current = List.last(session.conversations)
    grant = session.grant

    turns =
      if grant && grant.max_turns > 0,
        do: "#{grant.turns_used} of #{grant.max_turns} turns",
        else: nil

    now =
      case Conversations.history(current) do
        {:ok, %{open_turn: turn}} when not is_nil(turn) -> "A turn is running"
        {:ok, %{hold: %{reason: reason}}} -> "Held before its next turn: #{reason}"
        {:ok, _} -> "Waiting for you or its workers"
        _ -> nil
      end

    Enum.reject([now, turns], &is_nil/1) |> Enum.join(" · ")
  end

  # -- What the page reads -------------------------------------------------------

  defp current_agent(assigns), do: Enum.find(assigns.groups, &(&1.key == assigns.agent_key))

  defp open_dispatch(assigns) do
    with %{dispatches: dispatches} <- current_agent(assigns),
         id when is_binary(id) <- assigns.open_id do
      Enum.find(dispatches, &(&1.id == id))
    else
      _ -> nil
    end
  end

  defp state(dispatch, assigns) do
    if Map.get(assigns.asks, dispatch.id, 0) > 0,
      do: "needs_you",
      else: get_in(assigns.status, [dispatch.id, "state"]) || dispatch.state
  end

  defp final?(dispatch, assigns), do: state(dispatch, assigns) in Sessions.final_states()

  # News: a dispatch that finished while the page was open, until its agent
  # is opened. What had finished when the page opened is not news, and
  # nothing is stored: the dots last as long as the page.
  defp mark_seen(socket) do
    assigns = socket.assigns

    finished =
      for d <- assigns.session.dispatches, final?(d, assigns), into: MapSet.new(), do: d.id

    seen =
      case {assigns.seen, current_agent(assigns)} do
        {nil, _} ->
          finished

        {seen, nil} ->
          seen

        # Only what has finished: one still running is news when it ends,
        # even if its agent was opened before.
        {seen, agent} ->
          MapSet.union(seen, MapSet.intersection(MapSet.new(agent.dispatches, & &1.id), finished))
      end

    assign(socket, seen: seen)
  end

  defp news?(agent, assigns),
    do:
      is_struct(assigns.seen, MapSet) and
        Enum.any?(
          agent.dispatches,
          &(final?(&1, assigns) and not MapSet.member?(assigns.seen, &1.id))
        )

  defp needs(%{kind: "coordinator"}, _assigns), do: 0

  defp needs(agent, assigns),
    do: Enum.count(agent.dispatches, &(state(&1, assigns) in ~w(needs_you held)))

  defp working(%{kind: "coordinator"}, assigns),
    do: if(assigns.coordinator_status, do: 1, else: 0)

  defp working(agent, assigns) do
    Enum.count(
      agent.dispatches,
      &(state(&1, assigns) not in ["needs_you", "held" | Sessions.final_states()])
    )
  end

  defp agent_chip(agent, assigns) do
    cond do
      (n = needs(agent, assigns)) > 0 -> {"ss-chip ss-chip-ask", "#{n} needs you"}
      agent.kind == "coordinator" -> {"ss-chip", "coordinator"}
      (n = working(agent, assigns)) > 0 -> {"ss-chip", "#{n} working"}
      agent.dispatches == [] -> {"ss-chip ss-chip-done", "no dispatches"}
      true -> {"ss-chip ss-chip-done", "#{length(agent.dispatches)} done"}
    end
  end

  defp agent_now(%{kind: "coordinator"}, assigns), do: assigns.coordinator_status

  defp agent_now(agent, assigns) do
    case List.last(agent.dispatches) do
      nil -> nil
      dispatch -> get_in(assigns.status, [dispatch.id, "latest_step"]) || dispatch.title
    end
  end

  defp state_chip("needs_you"), do: {"ss-chip ss-chip-ask", "needs you"}
  defp state_chip("held"), do: {"ss-chip ss-chip-ask", "held"}
  defp state_chip(s) when s in ~w(failed failed_to_start), do: {"ss-chip ss-chip-fail", label(s)}
  defp state_chip(s) when s in ~w(completed cancelled), do: {"ss-chip ss-chip-done", label(s)}
  defp state_chip(s), do: {"ss-chip", label(s)}

  defp label(state), do: String.replace(to_string(state), "_", " ")

  defp elapsed(dispatch, assigns) do
    seconds = get_in(assigns.status, [dispatch.id, "elapsed_seconds"])

    limit =
      if dispatch.max_duration_seconds,
        do: " of #{minutes(dispatch.max_duration_seconds)}",
        else: ""

    case seconds do
      nil -> "time unknown"
      s -> minutes(s) <> limit
    end
  end

  defp minutes(seconds) when seconds < 120, do: "#{seconds}s"
  defp minutes(seconds), do: "#{div(seconds, 60)} min"

  defp agent_via(agent) do
    [Harnesses.name(agent.provider), agent.model]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp kind_label(nil), do: "Worker"

  defp kind_label(kind) do
    Agents.label(kind)
  rescue
    KeyError -> "Worker"
  end

  defp agent_link(session_id, key), do: ~p"/sessions/#{session_id}?#{[agent: key]}"

  # The needs-you strip opens the item's dispatch under the agent it is grouped with.
  defp item_link(session_id, groups, item) do
    case Enum.find(groups, fn g -> Enum.any?(g.dispatches, &(&1.id == item.dispatch_id)) end) do
      nil -> ~p"/sessions/#{session_id}"
      group -> dispatch_link(session_id, group.key, item.dispatch_id)
    end
  end

  defp dispatch_link(session_id, key, id),
    do: ~p"/sessions/#{session_id}?#{[agent: key, dispatch: id]}"

  defp repository(nil), do: "no repository recorded"
  defp repository(root), do: Path.basename(root)

  defp coordinator_name(nil), do: "no coordinator"

  defp coordinator_name(c),
    do: "#{Harnesses.name(c.provider)}#{if c.model, do: " · #{c.model}"}"

  defp ago(at, now), do: ShoestringWeb.TimeDisplay.humanize(at, now).text

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M:%S")
  defp clock(_at), do: ""

  defp kind_text(:command), do: "command"
  defp kind_text(:file), do: "file"
  defp kind_text(:message), do: "message"
  defp kind_text(:you), do: "you"
  defp kind_text(:tool), do: "tool"
  defp kind_text(:ask), do: "asks you"
  defp kind_text(:step), do: "shoestring"

  defp outcome(%{running: true}), do: {"ss-small", "running"}
  defp outcome(%{exit: 0}), do: {"ss-ok", "exit 0"}
  defp outcome(%{exit: code}) when is_integer(code), do: {"ss-bad", "exit #{code}"}
  defp outcome(%{failed: true}), do: {"ss-bad", "failed"}
  defp outcome(_row), do: nil

  defp took(%{seconds: s}) when is_number(s) and s < 60,
    do: :erlang.float_to_binary(s / 1, decimals: 1) <> "s"

  defp took(%{seconds: s}) when is_number(s), do: "#{round(s / 60)} min"
  defp took(_row), do: nil

  defp toggle_message(id),
    do:
      JS.toggle_class("ss-clip", to: "#msg-#{id}")
      |> JS.toggle(to: "#more-#{id} .ss-more-show")
      |> JS.toggle(to: "#more-#{id} .ss-more-hide")

  # -- Rendering -----------------------------------------------------------------

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      product_page="sessions"
      needs_you={@needs_you}
    >
      <div class="ss-heading">
        <div>
          <h1>Sessions</h1>
          <p>Coordinator sessions and what their agents are doing.</p>
        </div>
      </div>
      <form id="sessions-days-form" class="ss-days" phx-change="days" phx-submit="days">
        <label for="session-days">Show sessions from the last</label>
        <input
          id="session-days"
          name="days"
          type="number"
          min="1"
          max="365"
          value={@days}
          class="ss-input"
          phx-debounce="400"
        />
        <span>days</span>
        <span :if={@days_error} id="session-days-error" class="ss-notice" role="alert">
          {@days_error}
        </span>
      </form>
      <ul :if={@sessions != []} id="sessions-list" class="ss-sessions">
        <li :for={s <- @sessions} id={"session-#{s.session_id}"}>
          <.link navigate={~p"/sessions/#{s.session_id}"} class="ss-session-name">
            {repository(s.repository_root)}
          </.link>
          <span class="ss-small">{ago(s.last_at, @now)}</span>
          <span class="ss-session-meta">
            <code>{s.session_id}</code>
            · {coordinator_name(s.coordinator)} · {s.dispatches} {if s.dispatches == 1,
              do: "dispatch",
              else: "dispatches"}
            <span :if={s.working > 0}>· {s.working} working</span>
            <span :if={s.failed > 0}>· {s.failed} failed</span>
            <span :if={s.held + s.stopped + s.asks > 0} class="ss-chip ss-chip-ask">
              {s.held + s.stopped + s.asks} needs you
            </span>
          </span>
        </li>
      </ul>
      <p :if={@sessions == []} id="sessions-empty" class="ss-empty">
        No sessions in the last {@days} {if @days == 1, do: "day", else: "days"}.
      </p>
      <p :if={@hidden > 0} id="sessions-hidden" class="ss-small">
        {@hidden} older {if @hidden == 1, do: "session is", else: "sessions are"} hidden. Raise the number of days to see {if @hidden ==
                                                                                                                                1,
                                                                                                                              do:
                                                                                                                                "it",
                                                                                                                              else:
                                                                                                                                "them"}.
      </p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        agent: current_agent(assigns),
        filters:
          if(current_agent(assigns) && current_agent(assigns).kind == "coordinator",
            do: @coordinator_filters,
            else: @filters
          )
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      product_page="sessions"
      needs_you={@needs_you}
    >
      <section id="session-page">
        <.link id="session-back" navigate={~p"/sessions"} class="ss-small">All sessions</.link>
        <div id="session-head" class="ss-heading">
          <div>
            <h1>{repository(@session.repository_root)}</h1>
            <p>
              <code>{@session.session_id}</code>
              · {length(@session.dispatches)} {if length(@session.dispatches) == 1,
                do: "dispatch",
                else: "dispatches"}
              <span :if={@session.grant}>
                · grant allows {@session.grant.max_dispatches}
              </span>
            </p>
          </div>
        </div>
        <div :if={@items != []} id="needs-you" class="ss-needs" aria-live="polite">
          <p class="ss-needs-head">
            <strong>Needs you</strong>
            · {length(@items)} in this session. Also shown in the chat screen; the first answer wins.
          </p>
          <ul>
            <li :for={item <- @items} id={"needs-#{item.id}"}>
              <.link patch={item_link(@session.session_id, @groups, item)}>
                <span class="ss-needs-what">
                  {ShoestringWeb.RunPresentation.redact_text(item.summary)}
                </span>
                <span class="ss-small">
                  {item.agent || "no agent"} · {String.slice(item.dispatch_id || "", 0, 8)}
                </span>
              </.link>
            </li>
          </ul>
        </div>
        <div class="ss-session">
          <nav id="session-agents" class="ss-agents" aria-label="Agents in this session">
            <.link
              :for={a <- @groups}
              id={"agent-#{a.key}"}
              patch={agent_link(@session.session_id, a.key)}
              class="ss-agent"
              aria-current={if a.key == @agent_key, do: "true"}
            >
              <span class="ss-row">
                <strong>
                  {a.name}
                  <span
                    :if={news?(a, assigns)}
                    id={"agent-#{a.key}-news"}
                    class="ss-news"
                    title="Finished while this page was open"
                  >
                    <span class="ss-sr">new: finished while this page was open</span>
                  </span>
                </strong>
                <span class={elem(agent_chip(a, assigns), 0)}>{elem(agent_chip(a, assigns), 1)}</span>
              </span>
              <span class="ss-small">{kind_label(a.kind)} · {agent_via(a)}</span>
              <span :if={agent_now(a, assigns)} class="ss-agent-now">{agent_now(a, assigns)}</span>
            </.link>
            <p :if={@groups == []} id="session-no-agents" class="ss-small">
              This session has no conversation or dispatches yet.
            </p>
          </nav>
          <div :if={@agent} id="agent-panel" class="ss-panel ss-agent-panel">
            <div class="ss-row">
              <div>
                <h2>{@agent.name}</h2>
                <p class="ss-small">{kind_label(@agent.kind)} · {agent_via(@agent)}</p>
              </div>
              <.link
                :if={@agent.kind != "coordinator" and not String.starts_with?(@agent.key, "worker-")}
                navigate={~p"/agents/#{@agent.key}"}
                class="ss-small"
              >
                Agent settings
              </.link>
            </div>

            <%= if @agent.kind == "coordinator" do %>
              <div id="dispatch-coordinator" class="ss-dispatch ss-open">
                <div class="ss-dispatch-head">
                  <span class="ss-row">
                    <strong>Its conversation</strong>
                    <span class="ss-chip">coordinator</span>
                  </span>
                  <span class="ss-small">{@coordinator_status}</span>
                </div>
                <.feed
                  streams={@streams}
                  filters={@filters}
                  filter={@filter}
                  omitted={@feed_omitted}
                  live?={true}
                />
              </div>
            <% else %>
              <p :if={@agent.dispatches == []} id="agent-no-dispatches" class="ss-small">
                No dispatches for this agent in this session yet.
              </p>
              <div
                :for={d <- Enum.reverse(@agent.dispatches)}
                id={"dispatch-#{d.id}"}
                class={["ss-dispatch", d.id == @open_id && "ss-open"]}
              >
                <.link
                  patch={
                    dispatch_link(
                      @session.session_id,
                      @agent.key,
                      if(d.id == @open_id, do: "none", else: d.id)
                    )
                  }
                  class="ss-dispatch-head"
                  aria-expanded={to_string(d.id == @open_id)}
                >
                  <span class="ss-row">
                    <strong>{d.title}</strong>
                    <span class={elem(state_chip(state(d, assigns)), 0)}>
                      {elem(state_chip(state(d, assigns)), 1)}
                    </span>
                  </span>
                  <span class="ss-small ss-mono">
                    {String.slice(d.id, 0, 8)} · {String.upcase(d.purpose)} · {elapsed(d, assigns)}
                  </span>
                  <span :if={d.id != @open_id} class="ss-small">
                    {get_in(@status, [d.id, "latest_step"])}
                  </span>
                </.link>
                <%= if d.id == @open_id do %>
                  <AttentionComponents.card
                    :for={item <- Enum.filter(@items, &(&1.dispatch_id == d.id))}
                    item={item}
                    reason_for={@reason_for}
                    reason_error={@reason_error}
                  />
                  <p
                    :if={
                      get_in(@status, [d.id, "next"]) &&
                        not Enum.any?(@items, &(&1.dispatch_id == d.id))
                    }
                    id={"dispatch-#{d.id}-next"}
                    class="ss-small ss-next"
                  >
                    {get_in(@status, [d.id, "next"])}
                  </p>
                  <.feed
                    streams={@streams}
                    filters={@filters}
                    filter={@filter}
                    omitted={@feed_omitted}
                    live?={not final?(d, assigns)}
                  />
                  <div :if={@changes} id={"dispatch-#{d.id}-changes"} class="ss-changes">
                    <p class="ss-small">
                      Its worktree, branch <code>{@changes.branch}</code>{if @changes.stat == "",
                        do: ": nothing changed yet.",
                        else: ":"}
                    </p>
                    <pre :if={@changes.stat not in [nil, ""]} phx-no-format>{@changes.stat}</pre>
                  </div>
                  <div class="ss-links">
                    <.link
                      :if={get_in(@status, [d.id, "run_id"])}
                      id={"dispatch-#{d.id}-run"}
                      navigate={~p"/runs/#{get_in(@status, [d.id, "run_id"])}"}
                    >
                      Raw events
                    </.link>
                    <.link
                      :if={get_in(@status, [d.id, "terminal"])}
                      id={"dispatch-#{d.id}-terminal"}
                      navigate={get_in(@status, [d.id, "terminal"])}
                    >
                      Open terminal
                    </.link>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :streams, :any, required: true
  attr :filters, :list, required: true
  attr :filter, :string, required: true
  attr :omitted, :integer, required: true
  attr :live?, :boolean, required: true

  defp feed(assigns) do
    ~H"""
    <div class="ss-feed-bar">
      <div class="ss-filters" role="group" aria-label="Show">
        <button
          :for={{key, text} <- @filters}
          id={"feed-filter-#{key}"}
          type="button"
          phx-click="filter"
          phx-value-filter={key}
          aria-pressed={to_string(key == @filter)}
        >
          {text}
        </button>
      </div>
      <span :if={@live?} id="feed-live" class="ss-live">live</span>
      <span :if={!@live?} class="ss-small">finished</span>
    </div>
    <p :if={@omitted > 0} id="feed-omitted" class="ss-small">
      {@omitted} earlier {if @omitted == 1, do: "row is", else: "rows are"} not shown.
    </p>
    <ol id="feed" class="ss-feed" phx-update="stream">
      <li :for={{dom_id, row} <- @streams.feed} id={dom_id} class={"ss-feed-#{row.kind}"}>
        <time
          class="ss-feed-at"
          datetime={DateTime.to_iso8601(row.at)}
          title={DateTime.to_iso8601(row.at)}
        >
          {clock(row.at)}
        </time>
        <span class="ss-feed-kind">{kind_text(row.kind)}</span>
        <span class="ss-feed-body">
          <%= case row.kind do %>
            <% :command -> %>
              <code>$ {row.text}</code>
              <span :if={outcome(row)} class={elem(outcome(row), 0)}>{elem(outcome(row), 1)}</span>
              <span :if={took(row)} class="ss-small">{took(row)}</span>
            <% kind when kind in [:file, :tool] -> %>
              <code>{row.text}</code>
              <span :if={outcome(row)} class={elem(outcome(row), 0)}>{elem(outcome(row), 1)}</span>
            <% kind when kind in [:message, :you] -> %>
              <span :if={row.final} class="ss-final">final</span>
              <span :if={row.writing} class="ss-small">writing…</span>
              <span
                id={"msg-#{row.id}"}
                class={["ss-msg", SessionActivity.long?(row) && "ss-clip"]}
                phx-no-format
              >{row.text}</span>
              <button
                :if={SessionActivity.long?(row)}
                id={"more-#{row.id}"}
                type="button"
                class="ss-more"
                phx-click={toggle_message(row.id)}
              >
                <span class="ss-more-show">Show all</span>
                <span class="ss-more-hide" style="display:none">Show less</span>
              </button>
            <% :ask -> %>
              {row.text}
              <span :if={row.waiting} class="ss-chip ss-chip-ask">waiting for you</span>
            <% _ -> %>
              {row.text}
          <% end %>
        </span>
      </li>
      <li id="feed-empty" class="ss-feed-empty">Nothing of this kind yet.</li>
    </ol>
    <p class="ss-small">Times are UTC.</p>
    """
  end
end
