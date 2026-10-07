defmodule ShoestringWeb.AgentSettingsLive do
  use ShoestringWeb, :live_view
  alias Shoestring.AgentProfiles

  def mount(_, _, socket),
    do: {:ok, socket |> assign(current_scope: nil, page_title: "Settings") |> load()}

  def handle_event("validate", %{"settings" => attrs}, socket) do
    {:noreply,
     form(
       socket,
       AgentProfiles.change_settings(socket.assigns.settings, attrs)
       |> Map.put(:action, :validate)
     )}
  end

  def handle_event("save", %{"settings" => attrs}, socket) do
    case AgentProfiles.save_settings(socket.assigns.settings, attrs) do
      {:ok, _} -> {:noreply, socket |> load() |> put_flash(:info, "Settings saved")}
      {:error, changeset} -> {:noreply, form(socket, changeset)}
    end
  end

  def handle_event("reload-settings", _, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    settings = AgentProfiles.settings()

    socket
    |> assign(
      settings: settings,
      agent_options: Enum.map(AgentProfiles.list(), &{&1.name, &1.id})
    )
    |> form(AgentProfiles.change_settings(settings))
  end

  defp form(socket, changeset),
    do:
      assign(socket,
        form: to_form(changeset, as: :settings),
        form_errors: if(changeset.action, do: changeset.errors, else: [])
      )

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} product_page="settings">
      <div class="ss-heading">
        <div>
          <h1>Settings</h1>
          <p>Providers and defaults for saved agents.</p>
        </div>
      </div>
      <.form for={@form} id="settings-form" class="ss-form" phx-change="validate" phx-submit="save">
        <div :if={@form_errors != []} id="settings-errors" class="ss-error" role="alert">
          <p :for={{field, {message, _}} <- @form_errors}>{field}: {message}</p>
          <button id="reload-settings" type="button" class="ss-button" phx-click="reload-settings">
            Reload saved settings
          </button>
        </div>
        <h2>Providers</h2>
        <p>
          Authentication is managed by each provider's CLI. This page does not test access or verify model availability.
        </p>
        <div class="ss-fields ss-section">
          <div>
            <.input
              field={@form[:claude_models]}
              type="textarea"
              label="Claude Code model identifiers"
              rows="4"
              class="ss-input"
            />
            <p class="ss-small">
              One identifier per line. “default” delegates model selection to the provider.
            </p>
          </div>
          <div>
            <.input
              field={@form[:codex_models]}
              type="textarea"
              label="Codex model identifiers"
              rows="4"
              class="ss-input"
            />
            <p class="ss-small">Use identifiers available in your installed CLI and account.</p>
          </div>
        </div>
        <h2 class="ss-section">Defaults</h2>
        <div class="ss-fields">
          <.input
            field={@form[:default_agent_id]}
            type="select"
            label="Default agent"
            prompt="Choose when using the CLI"
            options={@agent_options}
            class="ss-input"
          /><.input
            field={@form[:refresh_seconds]}
            type="select"
            label="Usage refresh"
            options={[{"Manual", 0}, {"Every minute", 60}, {"Every five minutes", 300}]}
            class="ss-input"
          />
        </div>
        <p class="ss-footnote">
          Refresh reloads saved observations. These settings do not change quota reserves, approval requirements or execution policy.
        </p>
        <div class="ss-form-actions">
          <button id="save-settings" class="ss-button ss-primary" phx-disable-with="Saving…">
            Save settings
          </button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
