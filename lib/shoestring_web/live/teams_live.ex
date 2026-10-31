defmodule ShoestringWeb.TeamsLive do
  @moduledoc """
  Teams (iteration 16 package T): each saved team (`Shoestring.AgentProfiles`)
  shown as the agents that fill its roles, with each agent's model, effort and
  limit; a team is edited by choosing an agent for each role.
  """
  use ShoestringWeb, :live_view
  alias Shoestring.{Agents, AgentProfiles}
  alias Shoestring.AgentProfiles.{Definition, Role}

  def mount(_, _, socket),
    do: {:ok, assign(socket, current_scope: nil, page_title: "Teams", team: nil)}

  def handle_params(params, _, socket) do
    case socket.assigns.live_action do
      :index ->
        teams = AgentProfiles.list()

        {:noreply,
         socket
         |> assign(empty?: teams == [], agents: Map.new(Agents.list(), &{&1.id, &1}))
         |> stream(:teams, teams, reset: true)}

      :new ->
        {:noreply, configure(socket, new_team(), nil)}

      action ->
        case AgentProfiles.get_by_slug(params["slug"]) do
          nil ->
            {:noreply,
             socket |> put_flash(:error, "Team not found") |> push_navigate(to: ~p"/teams")}

          team when action == :edit ->
            {:noreply, configure(socket, team, team)}

          team ->
            copy = %Definition{
              name: team.name <> " copy",
              slug: team.slug <> "-copy",
              purpose: team.purpose,
              instructions: team.instructions,
              roles: team.roles
            }

            {:noreply, configure(socket, copy, nil)}
        end
    end
  end

  # A new team: the coordinator and implementer, and an explorer and reviewer
  # when there are agents for them; each role starts with its job's first agent.
  defp new_team do
    agents = Agents.list()

    roles =
      for kind <- ~w(coordinator explorer implementer reviewer),
          agent = Enum.find(agents, &(&1.kind == kind)),
          agent != nil or kind in ~w(coordinator implementer) do
        %Role{name: Agents.role_name(kind), agent_id: agent && agent.id}
      end

    %Definition{roles: roles}
  end

  def handle_event("validate", %{"team" => attrs}, socket) do
    changeset = AgentProfiles.change(socket.assigns.draft, attrs) |> Map.put(:action, :validate)
    {:noreply, form(socket, changeset)}
  end

  def handle_event("save", %{"team" => attrs}, socket) do
    result =
      if socket.assigns.team,
        do: AgentProfiles.update(socket.assigns.team, attrs),
        else: AgentProfiles.create(attrs)

    case result do
      {:ok, team} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved #{team.name}, revision #{team.revision}")
         |> push_navigate(to: ~p"/teams")}

      {:error, changeset} ->
        {:noreply, form(socket, changeset)}
    end
  end

  def handle_event("add-role", _, socket) do
    draft = Ecto.Changeset.apply_changes(socket.assigns.form.source)

    if length(draft.roles) < 6 do
      name =
        if Enum.any?(draft.roles, &(&1.name == "Explorer")),
          do: "Role #{length(draft.roles) + 1}",
          else: "Explorer"

      role = %Role{name: name}
      {:noreply, configure(socket, %{draft | roles: draft.roles ++ [role]}, socket.assigns.team)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove-role", %{"index" => index}, socket) do
    draft = Ecto.Changeset.apply_changes(socket.assigns.form.source)

    case Integer.parse(index) do
      {index, ""} when index > 0 and index < length(draft.roles) ->
        {:noreply,
         configure(
           socket,
           %{draft | roles: List.delete_at(draft.roles, index)},
           socket.assigns.team
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reload-team", _, %{assigns: %{team: nil}} = socket), do: {:noreply, socket}

  def handle_event("reload-team", _, socket) do
    team = AgentProfiles.get(socket.assigns.team.id)
    {:noreply, configure(socket, team, team)}
  end

  defp configure(socket, draft, team),
    do: socket |> assign(team: team, draft: draft) |> form(AgentProfiles.change(draft))

  defp form(socket, changeset),
    do:
      assign(socket,
        form: to_form(changeset, as: :team),
        agent_list: Agents.list(),
        form_errors: if(changeset.action, do: changeset.errors, else: []),
        role_count: length(Ecto.Changeset.get_field(changeset, :roles) || [])
      )

  # The agents a role named `name` may take: those of its job.
  defp agent_options(agents, name) do
    kind = Agents.kind_of(name || "")

    for agent <- agents,
        agent.kind == kind,
        do: {"#{agent.name}#{model_suffix(agent, " — ")}", agent.id}
  end

  # The agent's model, unless its name already says it.
  defp model_suffix(agent, separator) do
    model = "#{agent.provider}:#{agent.model}"
    if String.contains?(agent.name, model), do: "", else: separator <> model
  end

  defp role_label("Worker"), do: "Implementer"
  defp role_label(name), do: name

  defp limit(%{kind: "coordinator"}), do: "limit: the grant's turns"
  defp limit(%{max_minutes: nil}), do: "no limit of its own"
  defp limit(%{max_minutes: minutes}), do: "at most #{minutes} min a dispatch"

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} product_page="teams">
      <%= if @live_action == :index do %>
        <div class="ss-heading">
          <div>
            <h1>Teams</h1>
            <p>
              Each team names an agent for every role. Edit an agent once and every team that uses it changes.
            </p>
          </div>
          <.link id="new-team" navigate={~p"/teams/new"} class="ss-button ss-primary">
            Create team
          </.link>
        </div>
        <div :if={@empty?} id="teams-empty" class="ss-empty">
          <h2>Your first team starts here</h2>
          <p>Choose an agent for the coordinator and each role; `shoestring setup` makes one too.</p>
        </div>
        <div id="team-library" class="ss-grid" phx-update="stream">
          <article :for={{id, team} <- @streams.teams} id={id} class="ss-panel">
            <div class="ss-row">
              <h2>{team.name}</h2>
              <span class="ss-small">Revision {team.revision}</span>
            </div>
            <p>{team.purpose}</p>
            <dl class="ss-roles">
              <div
                :for={role <- team.roles}
                id={"team-#{team.slug}-role-#{role.name}"}
                class="ss-row"
              >
                <dt>{role_label(role.name)}</dt>
                <dd>
                  <%= case @agents[role.agent_id] do %>
                    <% nil -> %>
                      {role.provider}:{role.model}
                    <% agent -> %>
                      <.link navigate={~p"/agents/#{agent.slug}"}>{agent.name}</.link>
                      <span class="ss-small">
                        {model_suffix(agent, " · ")}{if(agent.effort,
                          do: " · #{agent.effort} effort"
                        )} · {limit(agent)}
                      </span>
                  <% end %>
                </dd>
              </div>
            </dl>
            <div class="ss-actions">
              <code>{team.slug}</code><.link
                id={"duplicate-#{team.id}"}
                navigate={~p"/teams/#{team.slug}/duplicate"}
              >Duplicate</.link><.link
                id={"edit-#{team.id}"}
                navigate={~p"/teams/#{team.slug}/edit"}
              >Edit</.link>
            </div>
          </article>
        </div>
      <% else %>
        <div class="ss-heading">
          <div>
            <h1>{if @team, do: "Edit team", else: "Create team"}</h1>
            <p>
              Each edit saves a new revision; work already running keeps the one it started with.
            </p>
          </div>
        </div>
        <.form
          for={@form}
          id="team-form"
          method="post"
          class="ss-form"
          phx-change="validate"
          phx-submit="save"
        >
          <div :if={@form_errors != []} id="team-errors" class="ss-error" role="alert">
            <p :for={{field, {message, _}} <- @form_errors}>{field}: {message}</p>
            <button
              :if={@team}
              id="reload-team"
              type="button"
              class="ss-button"
              phx-click="reload-team"
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
          <.input field={@form[:purpose]} label="Purpose" class="ss-input" />
          <.input
            field={@form[:instructions]}
            type="textarea"
            label="Instructions for the coordinator"
            rows="5"
            class="ss-input"
          />
          <h2 class="ss-section">Agents</h2>
          <p>
            The coordinator is required. Each role takes an agent of its job; its model,
            effort and limit come from the agent (<.link navigate={~p"/agents"}>Agents</.link>).
          </p>
          <.inputs_for :let={role} field={@form[:roles]}>
            <div class="ss-team-role">
              <.input field={role[:name]} label="Role" readonly={role.index == 0} class="ss-input" />
              <.input
                field={role[:agent_id]}
                type="select"
                label="Agent"
                prompt="Choose an agent"
                options={agent_options(@agent_list, role[:name].value)}
                class="ss-input"
              />
              <button
                :if={role.index > 0}
                id={"remove-role-#{role.index}"}
                type="button"
                class="ss-button"
                phx-click="remove-role"
                phx-value-index={role.index}
                aria-label={"Remove role #{role.index + 1}"}
              >
                Remove
              </button>
            </div>
          </.inputs_for>
          <button
            id="add-role"
            type="button"
            class="ss-button"
            phx-click="add-role"
            disabled={@role_count >= 6}
          >
            Add role
          </button>
          <p class="ss-footnote">Saving does not start work.</p>
          <div class="ss-form-actions">
            <.link navigate={~p"/teams"}>Cancel</.link><button
              id="save-team"
              class="ss-button ss-primary"
              phx-disable-with="Saving…"
            >Save team</button>
          </div>
        </.form>
      <% end %>
    </Layouts.app>
    """
  end
end
