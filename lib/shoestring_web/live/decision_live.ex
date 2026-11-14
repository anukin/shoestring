defmodule ShoestringWeb.DecisionLive do
  @moduledoc """
  One decision's pane (`/decisions/:decision_id`): it asks one thing and is
  done. While the decision waits it shows only the question, the candidates
  and their buttons. Once chosen, if the plan's next task waits for the
  person's OK (its provider's usage could not be read) it offers that one
  button (closing the page instead leaves it waiting; the pane offers it
  again when reopened); then it says it is done and offers nothing more. "None of these"
  and a withdrawn decision end it too, pointing at the goal page.

  The first answer wins from any screen: an answer made elsewhere shows
  here at once. Nothing on this page acts on a timer.
  """
  use ShoestringWeb, :live_view

  alias Shoestring.{Attention, Decisions, Trajectory}
  alias Shoestring.Decisions.NextStep
  alias ShoestringWeb.{AttentionComponents, DecisionText, RunPresentation}

  @impl true
  def mount(%{"decision_id" => id}, _session, socket) do
    socket =
      socket
      |> assign_new(:current_scope, fn -> nil end)
      |> assign(reason_for: nil, reason_error: nil, error: nil)

    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        decision = Decisions.get(id)

        if decision && connected?(socket) do
          :ok = Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(decision.goal_id))
        end

        {:ok, socket |> assign(:decision_id, id) |> load(decision)}

      :error ->
        {:ok, socket |> assign(:decision_id, nil) |> load(nil)}
    end
  end

  @impl true
  def handle_event("choose", %{"decision" => id, "choice" => choice}, socket),
    do: {:noreply, answer(socket, id, choice, nil)}

  def handle_event("reason", %{"ask" => id}, socket),
    do: {:noreply, assign(socket, reason_for: id, reason_error: nil)}

  def handle_event("reason_back", _params, socket),
    do: {:noreply, assign(socket, reason_for: nil, reason_error: nil)}

  def handle_event("reject_decision", %{"decision" => id, "note" => note}, socket) do
    if String.trim(to_string(note)) == "" do
      {:noreply, assign(socket, reason_error: "Say why none of these will do.")}
    else
      {:noreply, answer(socket, id, Decisions.reject(), note)}
    end
  end

  def handle_event("start_next", _params, socket) do
    case NextStep.confirm(socket.assigns.decision, Shoestring.CLI.WorkLoop.default_human()) do
      {:ok, _task_id} -> {:noreply, socket |> assign(error: nil) |> reload()}
      {:error, _reason} -> {:noreply, socket |> assign(error: :not_started) |> reload()}
    end
  end

  @impl true
  def handle_info({:trajectory_event_committed, _event}, socket), do: {:noreply, reload(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp answer(socket, id, choice, note) do
    if id == socket.assigns.decision_id do
      case Attention.answer_decision(
             nil,
             id,
             choice,
             Shoestring.CLI.WorkLoop.default_human(),
             note
           ) do
        {:ok, _decision} ->
          socket |> assign(reason_for: nil, reason_error: nil, error: nil) |> reload()

        # Answered elsewhere first, withdrawn, or refused: the page shows
        # what the decision is now, and why this answer did not count.
        {:error, reason} ->
          socket |> assign(reason_for: nil, error: reason) |> reload()
      end
    else
      socket
    end
  end

  defp reload(socket), do: load(socket, Decisions.get(socket.assigns.decision_id))

  defp load(socket, nil), do: assign(socket, decision: nil, step: :done, goal_title: nil)

  defp load(socket, decision) do
    assign(socket,
      decision: decision,
      step: if(decision.state == "answered", do: NextStep.step(decision), else: :done),
      goal_title: goal_title(decision.goal_id)
    )
  end

  defp goal_title(goal_id) do
    case Shoestring.Repo.get(Shoestring.Trajectory.Goal, goal_id) do
      %{title: title} -> title
      nil -> nil
    end
  end

  defp option_label(decision) do
    case Enum.find(decision.options, &(&1["key"] == decision.answer_key)) do
      %{"label" => label} -> RunPresentation.redact_text(label)
      _ -> decision.answer_key
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="decision-pane" class="ss-attention rounded-lg bg-white p-6 shadow-sm">
        <%= cond do %>
          <% is_nil(@decision) -> %>
            <p id="decision-missing" class="ss-attention-subject">No such decision.</p>
          <% @decision.state == "pending" -> %>
            <p :if={@goal_title} id="decision-goal" class="ss-small">{@goal_title}</p>
            <AttentionComponents.card
              item={Attention.decision_item(@decision)}
              reason_for={@reason_for}
              reason_error={@reason_error}
            />
          <% true -> %>
            <div id="decision-outcome" data-state={@decision.state} data-step={step_name(@step)}>
              <p :if={@goal_title} id="decision-goal" class="ss-small">{@goal_title}</p>
              <p :if={@error} id="decision-error" class="ss-notice">{error_text(@error)}</p>
              <%= case @decision.state do %>
                <% "answered" -> %>
                  <h3 id="decision-chosen">You chose {option_label(@decision)}.</h3>
                <% "rejected" -> %>
                  <h3 id="decision-chosen">None of these.</h3>
                  <p>
                    The task waits for you to decide what next:
                    <.link id="decision-goal-link" navigate={~p"/cobbler/goals/#{@decision.goal_id}"}>
                      open the goal
                    </.link>
                  </p>
                <% _withdrawn -> %>
                  <h3 id="decision-chosen">No longer needed: its goal was cancelled.</h3>
              <% end %>
              <%= case {@decision.state, @step} do %>
                <% {"answered", {:confirm, task}} -> %>
                  <p id="decision-next" class="ss-attention-subject">
                    Next: “{task.title}” needs your OK to start.
                  </p>
                  <p :if={task.why}>{task.why}</p>
                  <div class="ss-attention-choices">
                    <button
                      id="decision-start-next"
                      type="button"
                      class="ss-button ss-primary"
                      phx-click="start_next"
                    >
                      Start it
                    </button>
                  </div>
                <% {"answered", :starting} -> %>
                  <p id="decision-starting">Starting the next task…</p>
                <% {"answered", _step} -> %>
                  <p id="decision-done">Done. You can close this page.</p>
                <% _other -> %>
              <% end %>
            </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp step_name({:confirm, _}), do: "confirm"
  defp step_name(:starting), do: "starting"
  defp step_name(_step), do: "done"

  defp error_text(:not_started),
    do: "It could not be started from here: the goal page shows why."

  defp error_text(reason), do: DecisionText.refusal(reason)
end
