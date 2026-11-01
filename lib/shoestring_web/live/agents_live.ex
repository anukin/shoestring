defmodule ShoestringWeb.AgentsLive do
  @moduledoc """
  Agents (iteration 16 package T): every reusable agent with what it does,
  its model, effort and limit, what its sandbox lets it do, which teams use
  it and its recent dispatches. Editing one saves a new revision of each team
  that uses it.
  """
  use ShoestringWeb, :live_view
  alias Shoestring.{Agents, AgentProfiles, Dispatches, Harnesses}
  alias Shoestring.Agents.Agent

  @kinds ~w(coordinator explorer implementer reviewer)

  def mount(_, _, socket),
    do: {:ok, assign(socket, current_scope: nil, page_title: "Agents", agent: nil)}

  def handle_params(params, _, socket) do
    case socket.assigns.live_action do
      :index ->
        agents = Agents.list()

        {:noreply,
         assign(socket,
           groups:
             for(
               kind <- @kinds,
               members = Enum.filter(agents, &(&1.kind == kind)),
               members != [],
               do: {kind, Enum.map(members, &card/1)}
             ),
           empty?: agents == []
         )}

      :new ->
        kind = if params["kind"] in @kinds, do: params["kind"], else: "explorer"
        provider = if kind == "coordinator", do: "claude", else: "codex"
        model = List.first(AgentProfiles.catalog()[provider] || [])
        draft = %Agent{kind: kind, provider: provider, model: model}
        {:noreply, configure(socket, draft, nil)}

      action ->
        case Agents.get_by_slug(params["slug"]) do
          nil ->
            {:noreply,
             socket |> put_flash(:error, "Agent not found") |> push_navigate(to: ~p"/agents")}

          agent when action == :edit ->
            {:noreply, configure(socket, agent, agent)}

          agent ->
            {:noreply,
             assign(socket, agent: agent, card: card(agent, 20), page_title: agent.name)}
        end
    end
  end

  # What a person sees of an agent: itself, its sandbox, its teams and work.
  defp card(agent, recent \\ 5) do
    work = Agents.recent_work(agent, recent)

    %{
      agent: agent,
      abilities: Agents.abilities(agent),
      teams: Agents.used_by(agent),
      total: work.total,
      recent: Enum.map(work.recent, &work_row/1)
    }
  end

  defp work_row(dispatch) do
    call = Dispatches.Calls.get(dispatch.id)

    %{
      id: dispatch.id,
      title: dispatch.title,
      purpose: dispatch.purpose,
      state: Dispatches.state(dispatch),
      at: dispatch.inserted_at,
      seconds: Dispatches.took(dispatch),
      tokens: call && call.output_tokens
    }
  end

  def handle_event("validate", %{"agent" => attrs} = params, socket) do
    attrs = reset_model(attrs, params["_target"])
    changeset = Agents.change(socket.assigns.draft, attrs) |> Map.put(:action, :validate)
    {:noreply, form(socket, changeset)}
  end

  def handle_event("save", %{"agent" => attrs}, socket) do
    result =
      if socket.assigns.agent,
        do: Agents.update(socket.assigns.agent, Map.delete(attrs, "kind")),
        else: Agents.create(attrs)

    case result do
      {:ok, agent} ->
        teams = Agents.used_by(agent)

        note =
          case {socket.assigns.agent, teams} do
            {nil, _} -> ""
            {_, []} -> ""
            {_, teams} -> "; new revision of " <> Enum.map_join(teams, ", ", & &1.name)
          end

        {:noreply,
         socket
         |> put_flash(:info, "Saved #{agent.name}#{note}")
         |> push_navigate(to: ~p"/agents/#{agent.slug}")}

      {:error, {:team, slug, _changeset}} ->
        {:noreply,
         put_flash(socket, :error, "Not saved: team #{slug} would not accept the change")}

      {:error, changeset} ->
        {:noreply, form(socket, changeset)}
    end
  end

  def handle_event("reload-agent", _, %{assigns: %{agent: nil}} = socket), do: {:noreply, socket}

  def handle_event("reload-agent", _, socket) do
    agent = Agents.get(socket.assigns.agent.id)
    {:noreply, configure(socket, agent, agent)}
  end

  defp configure(socket, draft, agent),
    do: socket |> assign(agent: agent, draft: draft) |> form(Agents.change(draft))

  defp form(socket, changeset),
    do:
      assign(socket,
        form: to_form(changeset, as: :agent),
        catalog: AgentProfiles.catalog(),
        form_errors: if(changeset.action, do: changeset.errors, else: [])
      )

  defp reset_model(attrs, ["agent", "provider"]) do
    model = List.first(Map.get(AgentProfiles.catalog(), attrs["provider"], [])) || ""
    attrs |> Map.put("model", model) |> Map.put("effort", "")
  end

  defp reset_model(attrs, _), do: attrs

  defp lines(value) when is_list(value), do: Enum.join(value, "\n")
  defp lines(value) when is_binary(value), do: value
  defp lines(_value), do: ""

  defp providers, do: Enum.map(Harnesses.ids(), &{Harnesses.name(&1), &1})
  defp kind_options, do: Enum.map(@kinds, &{Agents.label(&1), &1})

  defp limit(%{kind: "coordinator"}), do: "Its limit is the session grant's turns."

  defp limit(%{max_minutes: nil}),
    do: "No limit of its own; the grant's per-dispatch limit applies."

  defp limit(%{max_minutes: minutes}),
    do: "At most #{minutes} minutes a dispatch; the coordinator sizes each one within it."

  defp duration(nil), do: nil
  defp duration(seconds) when seconds < 120, do: "#{seconds}s"
  defp duration(seconds), do: "#{div(seconds, 60)} min"

  attr :card, :map, required: true
  attr :full, :boolean, default: false

  defp agent_card(assigns) do
    ~H"""
    <article id={"agent-#{@card.agent.slug}"} class="ss-panel">
      <div class="ss-row">
        <h2>
          <.link :if={!@full} navigate={~p"/agents/#{@card.agent.slug}"}>{@card.agent.name}</.link>
          <span :if={@full}>{@card.agent.name}</span>
        </h2>
        <span class="ss-small">{Agents.label(@card.agent.kind)}</span>
      </div>
      <p>
        {Harnesses.name(@card.agent.provider)} · {@card.agent.model}{if(@card.agent.effort,
          do: " · #{@card.agent.effort} effort"
        )}
      </p>
      <p id={"agent-#{@card.agent.slug}-limit"} class="ss-small">{limit(@card.agent)}</p>
      <p :if={@card.agent.notes} class="ss-small">{@card.agent.notes}</p>
      <div class="ss-abilities">
        <div>
          <h3>Can</h3>
          <ul id={"agent-#{@card.agent.slug}-can"}>
            <li :for={line <- @card.abilities.can}>{line}</li>
          </ul>
        </div>
        <div>
          <h3>Cannot</h3>
          <ul id={"agent-#{@card.agent.slug}-cannot"}>
            <li :for={line <- @card.abilities.cannot}>{line}</li>
          </ul>
        </div>
      </div>
      <dl class="ss-roles">
        <div class="ss-row">
          <dt>Teams</dt>
          <dd id={"agent-#{@card.agent.slug}-teams"}>
            <%= if @card.teams == [] do %>
              none yet
            <% else %>
              <.link
                :for={team <- @card.teams}
                navigate={~p"/teams/#{team.slug}/edit"}
                class="ss-team-link"
              >
                {team.name}
              </.link>
            <% end %>
          </dd>
        </div>
        <div class="ss-row">
          <dt>Dispatches</dt>
          <dd id={"agent-#{@card.agent.slug}-total"}>{@card.total}</dd>
        </div>
      </dl>
      <ul :if={@card.recent != []} id={"agent-#{@card.agent.slug}-work"} class="ss-work">
        <li :for={row <- @card.recent} id={"work-#{row.id}"}>
          <span class="ss-work-title">{row.title}</span>
          <span class="ss-small">
            {row.state}{if(duration(row.seconds), do: " · #{duration(row.seconds)}")}{if(row.tokens,
              do: " · #{row.tokens} output tokens"
            )}
          </span>
        </li>
      </ul>
      <div class="ss-actions">
        <code>{@card.agent.slug}</code>
        <.link id={"edit-#{@card.agent.slug}"} navigate={~p"/agents/#{@card.agent.slug}/edit"}>
          Edit
        </.link>
      </div>
    </article>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} product_page="agents">
      <%= case @live_action do %>
        <% :index -> %>
          <div class="ss-heading">
            <div>
              <h1>Agents</h1>
              <p>
                The pieces teams are made of: what each one does, on which model, for how long,
                and what its sandbox lets it do.
              </p>
            </div>
            <.link id="new-agent" navigate={~p"/agents/new"} class="ss-button ss-primary">
              Create agent
            </.link>
          </div>
          <div :if={@empty?} id="agents-empty" class="ss-empty">
            <h2>No agents yet</h2>
            <p>Saving a team, or running `shoestring setup`, makes one for each of its roles.</p>
          </div>
          <section :for={{kind, cards} <- @groups} id={"agents-#{kind}"} class="ss-kind">
            <h2 class="ss-section">{Agents.label(kind)}s</h2>
            <div class="ss-grid">
              <.agent_card :for={card <- cards} card={card} />
            </div>
          </section>
        <% :show -> %>
          <div class="ss-heading">
            <div>
              <h1>{@agent.name}</h1>
              <p><.link navigate={~p"/agents"}>All agents</.link></p>
            </div>
          </div>
          <.agent_card card={@card} full={true} />
        <% _form -> %>
          <div class="ss-heading">
            <div>
              <h1>{if @agent, do: "Edit agent", else: "Create agent"}</h1>
              <p>
                Saving an agent saves a new revision of every team that uses it; work already
                running keeps the one it started with.
              </p>
            </div>
          </div>
          <.form
            for={@form}
            id="agent-form"
            method="post"
            class="ss-form"
            phx-change="validate"
            phx-submit="save"
          >
            <div :if={@form_errors != []} id="agent-errors" class="ss-error" role="alert">
              <p :for={{field, {message, _}} <- @form_errors}>{field}: {message}</p>
              <button
                :if={@agent}
                id="reload-agent"
                type="button"
                class="ss-button"
                phx-click="reload-agent"
              >
                Reload saved version
              </button>
            </div>
            <div class="ss-fields">
              <.input field={@form[:name]} label="Name" class="ss-input" /><.input
                field={@form[:slug]}
                label="CLI name"
                class="ss-input"
              />
            </div>
            <div class="ss-fields">
              <.input
                field={@form[:kind]}
                type="select"
                label="Job"
                options={kind_options()}
                disabled={@agent != nil}
                class="ss-input"
              /><.input
                field={@form[:max_minutes]}
                type="number"
                label="Most minutes a dispatch (empty: no limit)"
                min="1"
                max="240"
                disabled={@form[:kind].value == "coordinator"}
                class="ss-input"
              />
            </div>
            <div class="ss-fields">
              <.input
                field={@form[:provider]}
                type="select"
                label="Provider"
                options={providers()}
                class="ss-input"
              /><.input
                field={@form[:model]}
                type="select"
                label="Model"
                options={Map.get(@catalog, @form[:provider].value, [])}
                class="ss-input"
              />
            </div>
            <.input
              field={@form[:effort]}
              type="select"
              label="Effort"
              prompt="Provider default"
              options={AgentProfiles.efforts(@form[:provider].value, @form[:model].value)}
              class="ss-input"
            />
            <.input
              field={@form[:may_propose_lessons]}
              type="checkbox"
              label="May propose lessons for the repositories it works in"
            />
            <fieldset
              :if={@form[:kind].value == "implementer"}
              id="agent-permissions"
              class="ss-fieldset"
            >
              <legend>Permissions beyond its sandbox</legend>
              <p class="ss-footnote">
                Empty is nothing beyond the sandbox. One full path or host per line. Never your
                home folder itself or Shoestring's own state. Sessions already running keep the
                permissions they started with.
              </p>
              <.input
                field={@form[:may_ask]}
                type="checkbox"
                label="May ask you, while it works, to run one command outside its sandbox (Codex and Claude; you decide each time)"
              />
              <.input
                field={@form[:read_paths]}
                type="textarea"
                label="Folders it may also read"
                value={lines(@form[:read_paths].value)}
                rows="2"
                class="ss-input"
              />
              <.input
                field={@form[:write_paths]}
                type="textarea"
                label="Folders it may also read and write"
                value={lines(@form[:write_paths].value)}
                rows="2"
                class="ss-input"
              />
              <.input
                field={@form[:network_hosts]}
                type="textarea"
                label={
                  case @form[:provider].value do
                    "codex" -> "Network: * for every host (Codex cannot limit hosts)"
                    "opencode" -> "Hosts (opencode's sandbox is fixed: leave every box empty)"
                    _ -> "Hosts its commands may reach (github.com, *.npmjs.org)"
                  end
                }
                value={lines(@form[:network_hosts].value)}
                rows="2"
                class="ss-input"
              />
            </fieldset>
            <.input
              field={@form[:notes]}
              type="textarea"
              label="Notes (for you; the agent never sees them)"
              rows="3"
              class="ss-input"
            />
            <p class="ss-footnote">Model choices come from Settings. Saving does not start work.</p>
            <div class="ss-form-actions">
              <.link navigate={~p"/agents"}>Cancel</.link><button
                id="save-agent"
                class="ss-button ss-primary"
                phx-disable-with="Saving…"
              >Save agent</button>
            </div>
          </.form>
      <% end %>
    </Layouts.app>
    """
  end
end
