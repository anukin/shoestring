defmodule ShoestringWeb.AttentionComponents do
  @moduledoc """
  The cards that answer what needs the person (`Shoestring.Attention`), as
  the chat screen's popups do: the same title, words and choices. An ask's
  and a hold's buttons send `answer`, `reason`, `reason_back`, `deny_reason`
  and `start_held` to the page; a stopped dispatch's card only says what
  happened and gives the commands. Text a worker or reviewer wrote is
  redacted before it is drawn.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ShoestringWeb.Endpoint,
    router: ShoestringWeb.Router,
    statics: ShoestringWeb.static_paths()

  alias Phoenix.LiveView.JS
  alias ShoestringWeb.RunPresentation

  attr :item, :map, required: true
  attr :reason_for, :string, default: nil
  attr :reason_error, :string, default: nil

  def card(%{item: %{kind: :held}} = assigns) do
    ~H"""
    <div id={@item.id} class="ss-attention" role="group" aria-label={@item.title}>
      <h3>{@item.title}</h3>
      <p class="ss-attention-subject">{RunPresentation.redact_text(@item.subject)}</p>
      <p>{@item.note}</p>
      <div class="ss-attention-choices">
        <button
          id={"#{@item.id}-start"}
          type="button"
          class="ss-button ss-primary"
          phx-click="start_held"
          phx-value-dispatch={@item.dispatch_id}
        >
          Start it
        </button>
        <span class="ss-small">Or leave it held: nothing starts it unless you do.</span>
      </div>
    </div>
    """
  end

  def card(%{item: %{kind: :stopped}} = assigns) do
    ~H"""
    <div id={@item.id} class="ss-attention" role="group" aria-label={@item.title}>
      <h3>{@item.title}</h3>
      <p class="ss-attention-subject">{RunPresentation.redact_text(@item.subject)}</p>
      <p>{RunPresentation.redact_text(@item.note)}</p>
      <ul :if={@item.lines != []} id={"#{@item.id}-lines"} class="ss-attention-lines">
        <li :for={line <- @item.lines}>{RunPresentation.redact_text(line)}</li>
      </ul>
      <div :if={@item.commands != []}>
        <p class="ss-small">In a terminal:</p>
        <pre id={"#{@item.id}-commands"} class="ss-attention-commands" phx-no-format><code>{Enum.join(@item.commands, "\n")}</code></pre>
      </div>
      <div :if={@item.run_id} class="ss-attention-choices">
        <.link id={"#{@item.id}-run"} navigate={~p"/runs/#{@item.run_id}"} class="ss-button">
          Raw events
        </.link>
      </div>
    </div>
    """
  end

  def card(%{item: %{kind: :ask}} = assigns) do
    assigns = assign(assigns, :ask_id, assigns.item.ask.id)

    ~H"""
    <div id={@item.id} class="ss-attention" role="group" aria-label={@item.title}>
      <h3>{@item.title}</h3>
      <p class="ss-attention-subject">
        <code :if={@item.ask.kind == "command"}>{RunPresentation.redact_text(@item.subject)}</code>
        <span :if={@item.ask.kind != "command"}>{RunPresentation.redact_text(@item.subject)}</span>
      </p>
      <p :if={@item.why}>Why: {RunPresentation.redact_text(@item.why)}</p>
      <p>{@item.note}</p>
      <%= if @reason_for == @ask_id do %>
        <form
          id={"#{@item.id}-reason-form"}
          class="ss-attention-reason"
          phx-submit="deny_reason"
        >
          <input type="hidden" name="ask" value={@ask_id} />
          <label for={"#{@item.id}-reason"}>The worker is told</label>
          <textarea
            id={"#{@item.id}-reason"}
            name="note"
            class="ss-input"
            rows="2"
            maxlength="500"
            phx-mounted={JS.focus()}
          ></textarea>
          <p :if={@reason_error} id={"#{@item.id}-reason-error"} class="ss-notice">
            {@reason_error}
          </p>
          <div class="ss-attention-choices">
            <button id={"#{@item.id}-deny-reason"} type="submit" class="ss-button ss-primary">
              Deny and tell it
            </button>
            <button type="button" class="ss-button" phx-click="reason_back">Back</button>
          </div>
        </form>
      <% else %>
        <div class="ss-attention-choices">
          <button
            :for={{choice, text} <- @item.choices}
            id={"#{@item.id}-#{String.replace(choice, "_", "-")}"}
            type="button"
            class={["ss-button", choice == "allow" && "ss-primary"]}
            phx-click={if(choice == "deny_reason", do: "reason", else: "answer")}
            phx-value-ask={@ask_id}
            phx-value-decision={choice}
          >
            {text}
          </button>
        </div>
      <% end %>
    </div>
    """
  end
end
