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

  # A decision (iteration 19): the question, each candidate with what it
  # looks like and a button, and "None of these" with the note it needs.
  # Candidate bytes come from the loopback-only artifact route; text a
  # worker wrote (labels, note) is redacted before it is drawn.
  def card(%{item: %{kind: :decision}} = assigns) do
    assigns =
      assign(assigns,
        decision: assigns.item.decision,
        reject?: assigns.reason_for == assigns.item.decision.id
      )

    ~H"""
    <div id={@item.id} class="ss-attention ss-decision" role="group" aria-label={@item.title}>
      <h3>{@item.title}</h3>
      <p class="ss-attention-subject">{RunPresentation.redact_text(@item.subject)}</p>
      <p :if={@item.why}>{RunPresentation.redact_text(@item.why)}</p>
      <p>{@item.note}</p>
      <ul id={"#{@item.id}-options"} class="ss-decision-options">
        <li
          :for={option <- @decision.options}
          id={"#{@item.id}-option-#{option["key"]}"}
          class="ss-decision-option"
        >
          <span class="ss-decision-label">{RunPresentation.redact_text(option["label"])}</span>
          <.candidate goal_id={@decision.goal_id} option={option} />
          <span :if={option["source"]} class="ss-small ss-mono">
            Full file: {option["source"]}
          </span>
          <button
            :if={not @reject?}
            id={"#{@item.id}-choose-#{option["key"]}"}
            type="button"
            class="ss-button ss-primary"
            phx-click="choose"
            phx-value-decision={@decision.id}
            phx-value-choice={option["key"]}
          >
            Choose this
          </button>
        </li>
      </ul>
      <%= if @reject? do %>
        <form id={"#{@item.id}-reject-form"} class="ss-attention-reason" phx-submit="reject_decision">
          <input type="hidden" name="decision" value={@decision.id} />
          <label for={"#{@item.id}-reject-note"}>Why none of these (required)</label>
          <textarea
            id={"#{@item.id}-reject-note"}
            name="note"
            class="ss-input"
            rows="2"
            maxlength="2000"
            phx-mounted={JS.focus()}
          ></textarea>
          <p :if={@reason_error} id={"#{@item.id}-reject-error"} class="ss-notice">
            {@reason_error}
          </p>
          <div class="ss-attention-choices">
            <button id={"#{@item.id}-reject-submit"} type="submit" class="ss-button ss-primary">
              None of these
            </button>
            <button type="button" class="ss-button" phx-click="reason_back">Back</button>
          </div>
        </form>
      <% else %>
        <div :if={@decision.allow_reject} class="ss-attention-choices">
          <button
            id={"#{@item.id}-reject"}
            type="button"
            class="ss-button"
            phx-click="reason"
            phx-value-ask={@decision.id}
          >
            None of these…
          </button>
        </div>
      <% end %>
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

  attr :goal_id, :string, required: true
  attr :option, :map, required: true

  @doc "How one candidate looks: a picture, a player, or a link to its bytes."
  def candidate(assigns) do
    assigns =
      assign(assigns,
        url: ~p"/goals/#{assigns.goal_id}/artifacts/#{assigns.option["artifact_id"]}",
        kind: candidate_kind(assigns.option["media_type"])
      )

    assigns = assign(assigns, :excerpt, if(assigns.kind == :text, do: excerpt(assigns.option)))

    ~H"""
    <%= case @kind do %>
      <% :image -> %>
        <a href={@url} target="_blank" rel="noopener">
          <img
            src={@url}
            alt={RunPresentation.redact_text(@option["label"])}
            class="ss-decision-image"
            loading="lazy"
          />
        </a>
      <% :video -> %>
        <video src={@url} controls preload="metadata" class="ss-decision-image"></video>
      <% :audio -> %>
        <audio src={@url} controls preload="metadata"></audio>
      <% :text -> %>
        <pre :if={@excerpt} class="ss-decision-text" phx-no-format>{@excerpt}</pre>
        <a href={@url} target="_blank" rel="noopener" class="ss-small">Open the whole text</a>
      <% _ -> %>
        <a href={@url} target="_blank" rel="noopener" class="ss-small">
          Open {@option["media_type"]}
        </a>
    <% end %>
    """
  end

  defp candidate_kind("image/svg+xml"), do: :file
  defp candidate_kind("image/" <> _), do: :image
  defp candidate_kind("video/" <> _), do: :video
  defp candidate_kind("audio/" <> _), do: :audio
  defp candidate_kind("text/plain"), do: :text
  defp candidate_kind(_), do: :file

  # The start of a small text candidate, redacted like any worker text.
  defp excerpt(option) do
    case Shoestring.Trajectory.ArtifactStore.read(option["artifact_id"]) do
      {:ok, %{bytes: bytes}} when byte_size(bytes) <= 65_536 ->
        if String.valid?(bytes),
          do: bytes |> String.slice(0, 600) |> RunPresentation.redact_text(),
          else: nil

      _ ->
        nil
    end
  end
end
