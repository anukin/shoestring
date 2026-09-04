defmodule ShoestringWeb.CapacityObservatoryLive do
  use ShoestringWeb, :live_view

  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Harness.Observatory
  alias Shoestring.Harness.Security

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_scope, fn -> nil end)
    {:ok, load_observations(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_observations(socket)}
  end

  # -- Presentation helpers (UI boundary) --
  #
  # Mapping from underlying observation conditions to a distinct
  # presentational state (label + dot color + badge colors + icon).
  # The domain model carries only four `capacity_state` values plus a freeform
  # `reason`, so keyword heuristics on the downcased reason disambiguate the
  # refused/unknown families. This classifier intentionally lives in the
  # LiveView (presentation layer), not in the domain modules.
  #
  # | State            | Underlying condition                                              |
  # |------------------|-----------------------------------------------------------------|
  # | `:healthy`       | eligible for automatic admission                                    |
  # | `:auth_required` | `capacity_state == :refused` and reason mentions authentication   |
  # | `:hard_block`    | `capacity_state == :refused` and reason mentions rate limiting    |
  # | `:refused`       | `capacity_state == :refused`, no auth/block keywords              |
  # | `:disconnected`  | `capacity_state == :unknown` and reason mentions connectivity loss |
  # | `:unknown`       | `capacity_state == :unknown`, no disconnect keywords              |
  # | `:stale` (additive) | freshness is `:stale`; rendered as a separate marker  |
  # |                            alongside the primary state, never instead of it  |
  # | `:partial`       | `:degraded` with a mix of observed and unknown windows            |
  # | `:degraded`      | `:degraded` otherwise (e.g. version drift, reduced confidence)    |
  #
  # Priority: eligibility first, then the refused family (auth before block),
  # then the unknown family, then the degraded family. Staleness is orthogonal:
  # it never changes the primary state. A stale refusal or unknown keeps its
  # primary state and additionally surfaces a staleness marker via `stale?/1`,
  # so the operator can tell whether a block is current or hours old. A stale
  # `:observed` summary is never presented as `:healthy` (it is not eligible);
  # it demotes to `:degraded` plus the stale marker.
  #
  # NOTE: `auth_reason?/1`, `block_reason?/1`, and `disconnect_reason?/1` are an
  # interim prose heuristic, not a contract: `CapacitySnapshot` carries only
  # `capacity_state` plus a freeform `reason` and has no structured
  # refusal-kind field. The producers that would populate such a field live in
  # domain modules owned by other workstreams, so the heuristic stays until a
  # structured refusal-kind field lands. Keep its tokens narrow: only tokens
  # that genuinely indicate a hard block (rate limit / quota / 429 /
  # exhausted) belong in `block_reason?/1`; anything that merely restates the
  # refusal (e.g. "refused", "blocked") must stay out so generic refusals keep
  # rendering as `:refused`.
  @doc "Derives the distinct presentational state for an observation summary."
  @spec presentational_state(map()) :: atom()
  def presentational_state(%{eligible?: true}), do: :healthy

  def presentational_state(%{capacity_state: :refused} = summary) do
    reason = downcased_reason(summary)

    cond do
      auth_reason?(reason) -> :auth_required
      block_reason?(reason) -> :hard_block
      true -> :refused
    end
  end

  def presentational_state(%{capacity_state: :unknown} = summary) do
    if disconnect_reason?(downcased_reason(summary)), do: :disconnected, else: :unknown
  end

  def presentational_state(%{capacity_state: :degraded, windows: windows})
      when is_list(windows) do
    if partial_windows?(windows), do: :partial, else: :degraded
  end

  def presentational_state(%{capacity_state: :observed} = summary) do
    if stale?(summary), do: :degraded, else: :healthy
  end

  def presentational_state(_summary), do: :unknown

  @doc """
  Returns true when the observation is past its configured max age
  (`freshness_state == :stale`), independent of the primary presentational
  state. The template renders this as a separate, independently visible
  staleness marker alongside the primary state badge.
  """
  @spec stale?(map()) :: boolean()
  def stale?(summary), do: Map.get(summary, :freshness_state) == :stale

  @doc """
  Visual presentation (label, dot, badge, icon) for a presentational state.

  Every state has a distinct label; colors and icons differ across the
  hard-block / authentication-required / disconnected / partial / stale /
  unknown family so no two states render as the same visual.
  """
  @spec status_presentation(atom()) :: %{
          label: String.t(),
          detail: String.t(),
          dot_class: String.t(),
          badge_class: String.t(),
          icon: String.t(),
          status: String.t()
        }
  def status_presentation(:healthy) do
    %{
      label: "Eligible for automatic admission.",
      detail:
        "The source is fresh, confident, and reports sufficient capacity without hard blocks or authentication requirements.",
      dot_class: "bg-emerald-500",
      badge_class: "bg-emerald-100 text-emerald-800",
      icon: "hero-check-circle",
      status: "healthy"
    }
  end

  def status_presentation(:hard_block) do
    %{
      label: "Hard block — provider refused capacity.",
      detail:
        "The provider reported a rate limit or quota refusal. Automatic admission is blocked until capacity recovers.",
      dot_class: "bg-red-600",
      badge_class: "bg-red-100 text-red-800",
      icon: "hero-x-circle",
      status: "hard-block"
    }
  end

  def status_presentation(:auth_required) do
    %{
      label: "Authentication required.",
      detail:
        "The provider refused the request for credentials or authentication. Check provider login before retrying.",
      dot_class: "bg-purple-500",
      badge_class: "bg-purple-100 text-purple-800",
      icon: "hero-key",
      status: "auth-required"
    }
  end

  def status_presentation(:disconnected) do
    %{
      label: "Disconnected — no provider contact.",
      detail:
        "No usable observation could be obtained from the provider. The source appears unreachable or disconnected.",
      dot_class: "bg-zinc-400",
      badge_class: "bg-zinc-200 text-zinc-800",
      icon: "hero-wifi",
      status: "disconnected"
    }
  end

  def status_presentation(:partial) do
    %{
      label: "Partial observation — some windows absent.",
      detail:
        "Only some capacity windows were reported. Missing windows are shown as absent, never as zero usage.",
      dot_class: "bg-yellow-500",
      badge_class: "bg-yellow-100 text-yellow-800",
      icon: "hero-exclamation-triangle",
      status: "partial"
    }
  end

  def status_presentation(:stale) do
    %{
      label: "Stale observation.",
      detail:
        "The observation is older than its configured max age and must not be treated as usable capacity.",
      dot_class: "bg-orange-500",
      badge_class: "bg-orange-100 text-orange-800",
      icon: "hero-clock",
      status: "stale"
    }
  end

  def status_presentation(:degraded) do
    %{
      label: "Degraded observation.",
      detail:
        "The observation is usable with reduced confidence (for example version drift or a conservative tier).",
      dot_class: "bg-amber-500",
      badge_class: "bg-amber-100 text-amber-800",
      icon: "hero-exclamation-circle",
      status: "degraded"
    }
  end

  def status_presentation(:refused) do
    %{
      label: "Refused by provider.",
      detail: "The provider refused to report capacity. Automatic admission is blocked.",
      dot_class: "bg-rose-500",
      badge_class: "bg-rose-100 text-rose-800",
      icon: "hero-minus-circle",
      status: "refused"
    }
  end

  def status_presentation(_state) do
    %{
      label: "Unknown state.",
      detail:
        "No usable capacity information is available. This source is never treated as available.",
      dot_class: "bg-zinc-400",
      badge_class: "bg-zinc-100 text-zinc-800",
      icon: "hero-question-mark-circle",
      status: "unknown"
    }
  end

  @doc """
  Redacts a snapshot or window reason for display at the UI boundary.

  Reuses `Shoestring.Harness.Security.redact/1` so render-time defense does
  not depend on upstream callers having sanitized the text. Returns `nil`
  unchanged so templates can fall back to a default message.
  """
  @spec redact_reason(String.t() | nil) :: String.t() | nil
  def redact_reason(nil), do: nil
  def redact_reason(reason) when is_binary(reason), do: Security.redact(reason)

  @doc """
  Returns the discovered CLI/adapter version for an observation summary, or
  `nil` when the producer did not report one.
  """
  @spec cli_version(map()) :: String.t() | nil
  def cli_version(%{snapshot: %CapacitySnapshot{} = snapshot}) do
    CapacitySnapshot.cli_version(snapshot)
  end

  def cli_version(_summary), do: nil

  defp load_observations(socket) do
    # Fetch all latest observations
    summaries =
      Observatory.latest_observations()
      |> Enum.map(&Observatory.observation_summary/1)
      |> Enum.map(&enrich_summary/1)

    socket
    |> assign(:page_title, "Capacity Observatory")
    |> assign(:observations_empty?, summaries == [])
    |> stream(:observations, summaries,
      reset: true,
      dom_id: fn s -> "obs-#{s.provider_id}-#{s.invocation_mode}-#{s.scope}" end
    )
  end

  # Adds UI-boundary fields: redacted reasons, presentational state, CLI version,
  # and the additive staleness marker.
  defp enrich_summary(summary) do
    windows =
      Enum.map(summary.windows, fn window ->
        Map.put(window, :display_reason, redact_reason(Map.get(window, :reason)))
      end)

    state = presentational_state(summary)

    summary
    |> Map.put(:windows, windows)
    |> Map.put(:display_reason, redact_reason(summary.reason))
    |> Map.put(:presentational_state, state)
    |> Map.put(:presentation, status_presentation(state))
    |> Map.put(:stale?, stale?(summary))
    |> Map.put(:stale_presentation, status_presentation(:stale))
    |> Map.put(:cli_version, cli_version(summary))
  end

  defp downcased_reason(summary) do
    summary |> Map.get(:reason) |> to_string() |> String.downcase()
  end

  defp auth_reason?(reason) do
    String.contains?(reason, [
      "authentication",
      "auth required",
      "auth failed",
      "unauthorized",
      "unauthorised",
      "credential",
      "login",
      "sign-in",
      "signin",
      "access denied",
      "forbidden",
      "401",
      "api_key",
      "api-key"
    ]) or Regex.match?(~r/\bauth\b/, reason)
  end

  # Interim prose heuristic (see the note on `presentational_state/1`): only
  # tokens that genuinely indicate a hard block belong here. "refus*"/"blocked"
  # merely restate the refusal and must stay out so the generic `:refused`
  # branch remains reachable.
  defp block_reason?(reason) do
    String.contains?(reason, [
      "rate limit",
      "rate_limit",
      "ratelimit",
      "quota",
      "hard block",
      "hard_block",
      "exhaust",
      "too many requests",
      "limit reached",
      "429"
    ])
  end

  defp disconnect_reason?(reason) do
    String.contains?(reason, [
      "disconnect",
      "unreachable",
      "connection",
      "offline",
      "timeout",
      "timed out",
      "network",
      "provider_error",
      "socket",
      "econn",
      "no response",
      "unavailable"
    ])
  end

  defp partial_windows?(windows) do
    Enum.any?(windows, &(&1.state == :observed)) and
      Enum.any?(windows, &(&1.state == :unknown))
  end
end
