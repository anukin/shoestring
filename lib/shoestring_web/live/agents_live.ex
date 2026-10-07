defmodule ShoestringWeb.AgentsLive do
  use ShoestringWeb, :live_view
  alias Shoestring.AgentProfiles
  alias Shoestring.AgentProfiles.{Definition, Role}

  def mount(_, _, socket),
    do: {:ok, assign(socket, current_scope: nil, page_title: "Agents", agent: nil)}

  def handle_params(params, _, socket) do
    case socket.assigns.live_action do
      :index ->
        agents = AgentProfiles.list()
        {:noreply, socket |> assign(empty?: agents == []) |> stream(:agents, agents, reset: true)}

      :new ->
        {:noreply, configure(socket, AgentProfiles.template(), nil)}

      action ->
        case AgentProfiles.get_by_slug(params["slug"]) do
          nil ->
            {:noreply,
             socket |> put_flash(:error, "Agent not found") |> push_navigate(to: ~p"/agents")}

          agent when action == :edit ->
            {:noreply, configure(socket, agent, agent)}

          agent ->
            copy = %Definition{
              name: agent.name <> " copy",
              slug: agent.slug <> "-copy",
              purpose: agent.purpose,
              instructions: agent.instructions,
              roles: agent.roles
            }

            {:noreply, configure(socket, copy, nil)}
        end
    end
  end

  def handle_event("validate", %{"agent" => attrs} = params, socket) do
    attrs = reset_model(attrs, params["_target"])
    changeset = AgentProfiles.change(socket.assigns.draft, attrs) |> Map.put(:action, :validate)
    {:noreply, form(socket, changeset)}
  end

  def handle_event("save", %{"agent" => attrs}, socket) do
    result =
      if socket.assigns.agent,
        do: AgentProfiles.update(socket.assigns.agent, attrs),
        else: AgentProfiles.create(attrs)

    case result do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved #{agent.name}, revision #{agent.revision}")
         |> push_navigate(to: ~p"/agents")}

      {:error, changeset} ->
        {:noreply, form(socket, changeset)}
    end
  end

  def handle_event("add-role", _, socket) do
    draft = Ecto.Changeset.apply_changes(socket.assigns.form.source)

    if length(draft.roles) < 6 do
      catalog = AgentProfiles.catalog()

      role = %Role{
        name: "Role #{length(draft.roles) + 1}",
        provider: "codex",
        model: hd(catalog["codex"])
      }

      {:noreply, configure(socket, %{draft | roles: draft.roles ++ [role]}, socket.assigns.agent)}
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
           socket.assigns.agent
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reload-agent", _, %{assigns: %{agent: nil}} = socket), do: {:noreply, socket}

  def handle_event("reload-agent", _, socket) do
    agent = AgentProfiles.get(socket.assigns.agent.id)
    {:noreply, configure(socket, agent, agent)}
  end

  defp configure(socket, draft, agent),
    do: socket |> assign(agent: agent, draft: draft) |> form(AgentProfiles.change(draft))

  defp form(socket, changeset),
    do:
      assign(socket,
        form: to_form(changeset, as: :agent),
        catalog: AgentProfiles.catalog(),
        form_errors: if(changeset.action, do: changeset.errors, else: []),
        role_count: length(Ecto.Changeset.get_field(changeset, :roles) || [])
      )

  defp reset_model(attrs, ["agent", "roles", index, "provider"]) do
    case get_in(attrs, ["roles", index]) do
      %{"provider" => provider} = role ->
        put_in(
          attrs,
          ["roles", index],
          Map.put(role, "model", List.first(Map.get(AgentProfiles.catalog(), provider, [])) || "")
        )

      _ ->
        attrs
    end
  end

  defp reset_model(attrs, _), do: attrs
  defp providers, do: [{"Claude Code", "claude"}, {"Codex", "codex"}]
  defp provider("claude"), do: "Claude Code"
  defp provider("codex"), do: "Codex"

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} product_page="agents">
      <%= if @live_action == :index do %>
        <div class="ss-heading">
          <div>
            <h1>Agents</h1>
            <p>Named orchestrators for your CLI workflow.</p>
          </div>
          <.link id="new-agent" navigate={~p"/agents/new"} class="ss-button ss-primary">
            Create agent
          </.link>
        </div>
        <div :if={@empty?} id="agents-empty" class="ss-empty">
          <h2>Your team starts here</h2>
          <p>Create an agent with instructions and a provider/model for each role.</p>
        </div>
        <div id="agent-library" class="ss-grid" phx-update="stream">
          <article :for={{id, agent} <- @streams.agents} id={id} class="ss-panel">
            <div class="ss-row">
              <h2>{agent.name}</h2>
              <span class="ss-small">Revision {agent.revision}</span>
            </div>
            <p>{agent.purpose}</p>
            <dl class="ss-roles">
              <div :for={role <- agent.roles} class="ss-row">
                <dt>{role.name}</dt>
                <dd>{provider(role.provider)} · {role.model}</dd>
              </div>
            </dl>
            <div class="ss-actions">
              <code>{agent.slug}</code><.link
                id={"duplicate-#{agent.id}"}
                navigate={~p"/agents/#{agent.slug}/duplicate"}
              >Duplicate</.link><.link
                id={"edit-#{agent.id}"}
                navigate={~p"/agents/#{agent.slug}/edit"}
              >Edit</.link>
            </div>
          </article>
        </div>
      <% else %>
        <div class="ss-heading">
          <div>
            <h1>{if @agent, do: "Edit agent", else: "Create agent"}</h1>
            <p>Save a configuration for CLI use. Each edit creates a new revision.</p>
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
          <.input field={@form[:purpose]} label="Purpose" class="ss-input" />
          <.input
            field={@form[:instructions]}
            type="textarea"
            label="Instructions"
            rows="5"
            class="ss-input"
          />
          <h2 class="ss-section">Team</h2>
          <p>The coordinator is required. Add up to five roles for your workflow.</p>
          <.inputs_for :let={role} field={@form[:roles]}>
            <div class="ss-role-editor">
              <.input field={role[:name]} label="Role" readonly={role.index == 0} class="ss-input" />
              <.input
                field={role[:provider]}
                type="select"
                label="Provider"
                options={providers()}
                class="ss-input"
              />
              <.input
                field={role[:model]}
                type="select"
                label="Model identifier"
                options={Map.get(@catalog, role[:provider].value, [])}
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
