defmodule ShoestringWeb.UsageLive do
  use ShoestringWeb, :live_view
  alias Shoestring.{AgentProfiles, Usage}

  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule()
    {:ok, socket |> assign(current_scope: nil, page_title: "Usage") |> load()}
  end

  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_info(:refresh, socket) do
    schedule()
    {:noreply, load(socket)}
  end

  defp schedule do
    interval = AgentProfiles.settings().refresh_seconds
    if interval > 0, do: Process.send_after(self(), :refresh, interval * 1000)
  end

  defp load(socket), do: stream(socket, :accounts, Usage.cards(), reset: true)
  defp provider("claude"), do: "Claude Code"
  defp provider("codex"), do: "Codex"
  defp provider(value), do: Shoestring.Harness.Security.redact(value)
  defp window("five_hour"), do: "Five-hour allowance"
  defp window("seven_day"), do: "Weekly allowance"
  defp window(value), do: Shoestring.Harness.Security.redact(value)
  defp time(nil), do: "Not reported"
  defp time(value), do: Calendar.strftime(value, "%d %b %Y, %H:%M UTC")
  defp percent(value), do: Float.round(value / 1, 1) |> to_string()

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} product_page="usage">
      <div class="ss-heading">
        <div>
          <h1>Usage</h1>
          <p>Subscription allowances shared by each provider account.</p>
        </div>
        <button
          id="refresh-usage"
          class="ss-button"
          phx-click="refresh"
          phx-disable-with="Refreshing…"
        >
          Refresh
        </button>
      </div>
      <div id="usage-accounts" class="ss-grid" phx-update="stream">
        <article :for={{id, account} <- @streams.accounts} id={id} class="ss-panel">
          <div class="ss-row">
            <h2>{provider(account.provider)}</h2>
            <span class="ss-status">{account.status}</span>
          </div>
          <p class="ss-small ss-scope">{account.scope}</p>
          <p :if={account.reason} class="ss-small">{account.reason}</p>
          <p :if={account.stale?} class="ss-notice">
            This reading is stale. Current allowance is unknown.
          </p>
          <section :for={w <- account.windows} class="ss-window" aria-label={window(w.kind)}>
            <div class="ss-row">
              <h3>{window(w.kind)}</h3>
              <span :if={is_number(w[:used_percent])} class="ss-number">
                {percent(w.used_percent)}% used
              </span>
            </div>
            <%= if w.state == :observed and is_number(w[:used_percent]) do %>
              <div
                class="ss-meter"
                role="progressbar"
                aria-label={window(w.kind) <> " last reported used percentage"}
                aria-valuenow={w.used_percent}
                aria-valuemin="0"
                aria-valuemax="100"
              >
                <span style={"width: #{w.used_percent}%"}></span>
              </div>
              <p class="ss-small">{percent(100 - w.used_percent)}% remaining at last reading</p>
              <p class="ss-small">Resets: {time(w[:reset_at])}</p>
            <% else %>
              <div class="ss-unknown">Unknown · {w[:reason] || "Not reported"}</div>
            <% end %>
          </section>
          <p class="ss-small ss-observed">Last observed: {time(account.observed_at)}</p>
          <details :if={Enum.any?(account.history, &is_number(&1.value))} class="ss-history">
            <summary>Seven-day history</summary>
            <p class="ss-small">
              Daily peak of five-hour usage · UTC · 0–100%. Gaps mean no observation.
            </p>
            <div class="ss-bars">
              <div
                :for={day <- account.history}
                class="ss-day"
                aria-label={"#{day.date}: #{if is_nil(day.value), do: "no observation", else: percent(day.value) <> "% used"}"}
              >
                <div class="ss-column">
                  <span :if={is_number(day.value)} style={"height: #{day.value}%"}></span><span
                    :if={is_nil(day.value)}
                    class="ss-gap"
                  >—</span>
                </div>
                <small>{Calendar.strftime(day.date, "%d %b")}</small>
              </div>
            </div>
          </details>
        </article>
      </div>
      <p class="ss-footnote">
        Refresh reads saved observations. It does not contact a provider. Account allowance is shared across agents; this view does not measure context tokens or API spending.
      </p>
    </Layouts.app>
    """
  end
end
