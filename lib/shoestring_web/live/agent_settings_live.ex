defmodule ShoestringWeb.AgentSettingsLive do
  use ShoestringWeb, :live_view
  on_mount ShoestringWeb.NeedsYou
  alias Shoestring.{AgentProfiles, Harnesses, ModelCatalog}

  def mount(_, _, socket),
    do:
      {:ok,
       socket
       |> assign(
         current_scope: nil,
         page_title: "Settings",
         model_query: "",
         model_notice: nil,
         model_error: nil,
         refreshing: nil,
         model_limit: 30,
         manual_form: to_form(%{"provider" => "opencode", "model" => ""}, as: :manual)
       )
       |> load()
       |> load_models()
       |> ShoestringWeb.ModelCatalogWatch.schedule()}

  def handle_event("search-models", %{"model_search" => %{"query" => query}}, socket),
    do: {:noreply, socket |> assign(model_query: query, model_limit: 30) |> load_models()}

  def handle_event("more-models", _, socket),
    do:
      {:noreply, socket |> assign(:model_limit, socket.assigns.model_limit + 30) |> load_models()}

  def handle_event(
        "toggle-model",
        %{"provider" => provider, "model" => model, "action" => action},
        socket
      )
      when provider in ["claude", "codex", "opencode"] and action in ["enable", "disable"] do
    result =
      if action == "enable",
        do: ModelCatalog.enable(provider, model),
        else: ModelCatalog.disable(provider, model)

    {:noreply, model_result(socket, result)}
  end

  def handle_event("add-model", %{"manual" => attrs}, socket) do
    socket = assign(socket, :manual_form, to_form(attrs, as: :manual))

    if attrs["provider"] in Harnesses.ids() do
      {:noreply,
       model_result(
         socket,
         ModelCatalog.add(attrs["provider"], String.trim(attrs["model"] || ""))
       )}
    else
      {:noreply, assign(socket, :model_error, "Choose an agent CLI.")}
    end
  end

  def handle_event(
        "refresh-models",
        %{"provider" => provider},
        %{assigns: %{refreshing: nil}} = socket
      )
      when provider in ["claude", "codex", "opencode"] do
    {:noreply,
     socket
     |> assign(refreshing: provider, model_error: nil, model_notice: nil)
     |> start_async(:model_refresh, fn -> ModelCatalog.refresh(provider) end)}
  end

  def handle_event("refresh-models", _, socket), do: {:noreply, socket}

  def handle_event("validate", %{"settings" => attrs}, socket) do
    {:noreply,
     form(
       socket,
       ModelCatalog.change_settings(socket.assigns.settings, attrs)
       |> Map.put(:action, :validate)
     )}
  end

  def handle_event("save", %{"settings" => attrs}, socket) do
    case ModelCatalog.save_settings(socket.assigns.settings, attrs) do
      {:ok, _} ->
        {:noreply, socket |> load() |> load_models() |> put_flash(:info, "Settings saved")}

      {:error, changeset} ->
        {:noreply, form(socket, changeset)}
    end
  end

  def handle_event("reload-settings", _, socket),
    do: {:noreply, socket |> load() |> load_models()}

  def handle_async(:model_refresh, {:ok, result}, socket),
    do: {:noreply, socket |> assign(:refreshing, nil) |> model_result(result)}

  def handle_async(:model_refresh, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         refreshing: nil,
         model_error: "Model refresh failed. Saved choices have been kept; try again."
       )}

  def handle_info(:model_catalog_check, socket),
    do: {:noreply, socket |> load_models() |> ShoestringWeb.ModelCatalogWatch.schedule()}

  defp model_result(socket, {:ok, _}) do
    # Model actions save immediately. Rebase only this page's own action,
    # keeping the rest of the settings draft; external changes stay subject
    # to optimistic locking on Save settings.
    settings = AgentProfiles.settings()

    params = Map.drop(socket.assigns.form.source.changes, [:lock_version])

    socket
    |> assign(
      settings: settings,
      model_notice: "Model settings updated. Other unsaved settings have been kept.",
      model_error: nil
    )
    |> form(AgentProfiles.change_settings(settings, params))
    |> load_models()
  end

  defp model_result(socket, {:error, {:in_use, users}}),
    do:
      assign(socket,
        model_error:
          "Change the agents or teams using this model first: #{Enum.join(users, ", ")}",
        model_notice: nil
      )

  defp model_result(socket, {:error, _}),
    do:
      assign(socket,
        model_error:
          "Could not update models. Check the identifier, installed CLI and sign-in, then try again. Saved choices have been kept.",
        model_notice: nil
      )

  defp load_models(socket) do
    all = ModelCatalog.choices(include_disabled: true, include_unavailable: true)
    rows = Enum.filter(all, &ModelCatalog.matches?(&1, socket.assigns.model_query))
    version = :erlang.phash2(all)
    old = Map.get(socket.assigns, :model_version)
    changed? = old != nil and old != version

    socket
    |> assign(
      model_version: version,
      models_empty?: rows == [],
      model_total: length(rows),
      model_shown: min(length(rows), socket.assigns.model_limit),
      model_search_form: to_form(%{"query" => socket.assigns.model_query}, as: :model_search),
      model_notice:
        if(changed?,
          do:
            "Model choices updated from saved configuration. Your settings draft has been kept.",
          else: socket.assigns.model_notice
        )
    )
    |> stream(:models, Enum.take(rows, socket.assigns.model_limit),
      reset: true,
      dom_id: fn row ->
        "model-" <> Base.url_encode64(row.provider <> ":" <> row.model, padding: false)
      end
    )
  end

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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      product_page="settings"
      needs_you={@needs_you}
    >
      <div class="ss-heading">
        <div>
          <h1>Settings</h1>
          <p>Providers and defaults for saved teams and agents.</p>
        </div>
      </div>
      <section
        id="model-catalog"
        class="ss-form ss-model-catalog"
        aria-labelledby="model-catalog-title"
      >
        <h2 id="model-catalog-title">Models</h2>
        <p>
          Search models reported by your agent CLIs. Enabling a model saves immediately; it does not start work or verify access.
        </p>
        <p class="ss-small">
          New opencode models require you to enable them. Their provider may charge per token. Discovery uses global configuration and does not verify project access or billing.
        </p>
        <div class="ss-model-refresh">
          <button
            :for={provider <- Harnesses.ids()}
            id={"refresh-models-#{provider}"}
            type="button"
            class="ss-button"
            phx-click="refresh-models"
            phx-value-provider={provider}
            disabled={@refreshing != nil}
          >
            {if @refreshing == provider,
              do: "Refreshing…",
              else: "Refresh #{Harnesses.name(provider)}"}
          </button>
        </div>
        <p :if={@model_notice} id="model-notice" class="ss-notice" role="status">{@model_notice}</p>
        <p :if={@model_error} id="model-error" class="ss-error" role="alert">{@model_error}</p>
        <.form
          for={@model_search_form}
          id="model-search-form"
          method="post"
          phx-change="search-models"
          phx-submit="search-models"
        >
          <.input
            field={@model_search_form[:query]}
            id="model-search"
            type="search"
            label="Search models"
            placeholder="Name, agent CLI or opencode provider"
            phx-debounce="150"
            class="ss-input"
          />
        </.form>
        <p :if={@models_empty?} id="model-catalog-empty" class="ss-small" role="status">
          No matching models. Clear the search, refresh a CLI or add an identifier below.
        </p>
        <div id="model-rows" phx-update="stream">
          <div
            :for={{id, row} <- @streams.models}
            id={id}
            class="ss-model-row"
            data-provider={row.provider}
            data-model={row.model}
          >
            <div>
              <strong>{ModelCatalog.label(row)}</strong>
              <code>{row.model}</code>
              <p class="ss-small">
                {cond do
                  not row.available -> "No longer reported"
                  row.source == "live" -> "Reported by CLI"
                  true -> "Manually configured; access unverified"
                end}
                <span :if={row.fetched_at}>
                  · Last reported {Calendar.strftime(row.fetched_at, "%Y-%m-%d %H:%M UTC")}
                </span>
                · {if row.enabled, do: "Enabled", else: "Disabled"}
              </p>
            </div>
            <button
              id={"#{id}-toggle"}
              type="button"
              class="ss-button"
              phx-click="toggle-model"
              phx-value-provider={row.provider}
              phx-value-model={row.model}
              phx-value-action={if row.enabled, do: "disable", else: "enable"}
              disabled={!row.available and !row.enabled}
              aria-label={"#{if row.enabled, do: "Disable", else: "Enable"} #{ModelCatalog.label(row)}"}
            >
              {if row.enabled, do: "Disable", else: "Enable"}
            </button>
          </div>
        </div>
        <p id="model-count" class="ss-small">Showing {@model_shown} of {@model_total} models.</p>
        <button
          :if={@model_shown < @model_total}
          id="more-models"
          type="button"
          phx-click="more-models"
          class="ss-button"
        >
          Show more models
        </button>
        <details id="manual-model" class="ss-section">
          <summary>Add an unlisted model</summary>
          <.form
            for={@manual_form}
            id="manual-model-form"
            method="post"
            phx-submit="add-model"
            class="ss-section"
          >
            <div class="ss-fields">
              <.input
                field={@manual_form[:provider]}
                type="select"
                label="Agent CLI"
                options={Enum.map(Harnesses.ids(), &{Harnesses.name(&1), &1})}
                class="ss-input"
              />
              <.input
                field={@manual_form[:model]}
                label="Exact model identifier"
                placeholder="provider/model for opencode"
                class="ss-input"
              />
            </div>
            <button id="add-model" class="ss-button" phx-disable-with="Adding…">
              Add and enable model
            </button>
          </.form>
        </details>
      </section>
      <.form
        for={@form}
        id="settings-form"
        method="post"
        class="ss-form"
        phx-change="validate"
        phx-submit="save"
      >
        <div :if={@form_errors != []} id="settings-errors" class="ss-error" role="alert">
          <p :for={{field, {message, _}} <- @form_errors}>{field}: {message}</p>
          <button id="reload-settings" type="button" class="ss-button" phx-click="reload-settings">
            Reload saved settings
          </button>
        </div>
        <details id="advanced-model-identifiers">
          <summary>Advanced: edit enabled model identifiers</summary>
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
            <div>
              <.input
                field={@form[:opencode_models]}
                type="textarea"
                label="opencode model identifiers"
                rows="4"
                class="ss-input"
              />
              <p class="ss-small">
                provider/model, as <code>opencode models</code> lists them. There is no default model.
                An openai/ model uses the same ChatGPT subscription as Codex, and Shoestring cannot see that use.
              </p>
            </div>
          </div>
        </details>
        <h2 class="ss-section">Parallel work</h2>
        <div class="ss-fields">
          <div>
            <.input
              field={@form[:parallel_tasks]}
              type="number"
              label="IMPLEMENT tasks that may run at once"
              min="1"
              max="8"
              class="ss-input"
            />
            <p class="ss-small">
              1 runs every task after the one before. More lets the tasks of a batch dispatch,
              or a plan's tasks that change separate files, run at once, each in its own worktree;
              you then take each task's commit and record the merge. It changes only while no
              task is running or waiting to run.
            </p>
          </div>
        </div>
        <h2 class="ss-section">Lessons and the web UI</h2>
        <div class="ss-fields">
          <.input
            field={@form[:lessons_space_mb]}
            type="number"
            label="Most space lessons may take in one repository (MB)"
            min="1"
            max="100000"
            class="ss-input"
          /><.input
            field={@form[:session_days]}
            type="number"
            label="Sessions shown on the Sessions page (days)"
            min="1"
            max="365"
            class="ss-input"
          /><.input
            field={@form[:open_browser_on_start]}
            type="checkbox"
            label="Open this page in the default browser when shoestring start is ready"
          />
        </div>
        <h2 class="ss-section">Defaults</h2>
        <div class="ss-fields">
          <.input
            field={@form[:default_agent_id]}
            type="select"
            label="Default team"
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
