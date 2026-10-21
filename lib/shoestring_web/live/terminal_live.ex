defmodule ShoestringWeb.TerminalLive do
  use ShoestringWeb, :live_view
  alias Shoestring.Harness.RunRecord
  alias ShoestringWeb.TerminalAccess

  @impl true
  def mount(%{"run_id" => run_id}, session, socket) do
    run = with {:ok, id} <- Ecto.UUID.cast(run_id), do: Shoestring.Repo.get(RunRecord, id)
    browser = session["terminal_browser"]
    tokens = TerminalAccess.tokens(browser, run_id)
    available? = TerminalAccess.interactive?(run) and match?({:ok, _}, tokens)

    socket =
      assign(socket,
        current_scope: nil,
        page_title: "Interactive terminal",
        run_id: run_id,
        available?: available?,
        browser: browser,
        tokens: if(available?, do: elem(tokens, 1), else: nil),
        retention?:
          Application.get_env(:shoestring, :terminal_log_retention, :disabled) == :redacted
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh_terminal_tokens", _params, socket) do
    if socket.assigns.available? do
      {:ok, tokens} = TerminalAccess.tokens(socket.assigns.browser, socket.assigns.run_id)
      {:reply, tokens, socket}
    else
      {:reply, %{error: "terminal_unavailable"}, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} product_page="terminal">
      <section id="terminal-page" class="ss-terminal-page">
        <.link id="terminal-back" navigate={~p"/runs/#{@run_id}"}>Back to run</.link>
        <div class="ss-heading ss-terminal-heading">
          <div>
            <h1>Interactive terminal</h1>
            <p>Run <code>{String.slice(@run_id, 0, 8)}</code>. Request control before typing.</p>
          </div>
        </div>
        <%= if @available? do %>
          <div
            id="terminal-client"
            phx-hook="Terminal"
            phx-update="ignore"
            data-run-id={@run_id}
            data-socket-token={@tokens.socket_token}
            data-capability={@tokens.capability}
          >
            <div class="ss-terminal-toolbar" role="group" aria-label="Terminal controls">
              <button
                id="terminal-takeover"
                type="button"
                data-terminal-action="takeover"
                class="ss-button ss-primary"
                disabled
              >
                Request control
              </button>
              <button
                id="terminal-release"
                type="button"
                data-terminal-action="release"
                class="ss-button"
                disabled
              >
                Release control
              </button>
              <button
                id="terminal-interrupt"
                type="button"
                data-terminal-action="interrupt"
                class="ss-button"
                disabled
              >
                Send Ctrl-C
              </button>
              <button
                id="terminal-detach"
                type="button"
                data-terminal-action="detach"
                class="ss-button"
                disabled
              >
                Detach
              </button>
              <button
                id="terminal-reattach"
                type="button"
                data-terminal-action="reattach"
                class="ss-button"
                hidden
              >
                Reattach
              </button>
              <button
                id="terminal-terminate"
                type="button"
                data-terminal-action="terminate"
                class="ss-button ss-terminal-danger"
                disabled
              >
                Terminate run
              </button>
            </div>
            <p id="terminal-status" class="ss-terminal-status" role="status" aria-live="polite">
              Connecting to the terminal…
            </p>
            <div id="terminal-screen" class="ss-terminal-screen" aria-label="Interactive run terminal">
            </div>
            <p id="terminal-notice" class="ss-notice" role="alert" hidden></p>
            <noscript>
              <p class="ss-notice">
                Enable JavaScript to attach to this terminal. The run continues independently.
              </p>
            </noscript>
          </div>
          <p class="ss-footnote">
            Detaching keeps the run alive and retains human control until you release it.
            Scrollback is bounded; reconnecting may show only recent output.
          </p>
          <p class="ss-small" id="terminal-retention">
            <%= if @retention? do %>
              Redacted terminal-log retention is enabled. Arbitrary terminal bytes may still contain secrets.
            <% else %>
              Terminal-log retention is off. Output is kept only in bounded live scrollback.
            <% end %>
          </p>
        <% else %>
          <div id="terminal-unavailable" class="ss-error">
            <h2>Terminal unavailable</h2>
            <p>
              Use a local browser to open an interactive run. Headless runs keep their existing execution mode.
            </p>
            <.link navigate={~p"/runs/new"}>Start a new run</.link>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
