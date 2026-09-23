defmodule ShoestringWeb.TimeDisplay do
  @moduledoc """
  Relative-time presentation for operator-facing timestamps.

  An absolute UTC timestamp such as `2026-09-08T12:00:00.000000Z` is exact but
  not understandable at a glance: an operator reading a sleep card has to do
  the subtraction themselves. This module renders the same instant twice — a
  humanized distance (`in 4m 32s`) and the unchanged exact timestamp — so
  legibility costs nothing in precision.

  Two rules hold this to the project's honesty bar:

    * The exact timestamp is never replaced. It stays in the `datetime`
      attribute, in the element's `title`, and in visible text beside the
      relative phrase.
    * Nothing here schedules, times, or wakes anything. `humanize/2` is a pure
      function of two instants, evaluated once per render; the optional client
      enhancement in `priv/static/assets/js/app.js` only re-renders text. No
      server timer exists, so no lifecycle behaviour depends on this module.

  A value that cannot be read as an instant is reported as such rather than
  guessed at or hidden.
  """

  use Phoenix.Component

  @minute 60
  @hour 3_600
  @day 86_400

  @typedoc "A humanized distance between two instants."
  @type humanized :: %{
          direction: :future | :past | :now,
          text: String.t(),
          label: String.t()
        }

  @doc """
  Renders an instant as a countdown phrase plus its exact timestamp.

  `at` accepts a `DateTime` or an ISO8601 string (admission payloads carry the
  latter). `now` is the render-time instant, passed in so the caller owns the
  clock and tests stay deterministic.

  The rendered `<time>` carries `data-countdown-to`, which the client enhancer
  uses to keep the phrase ticking. Without JavaScript the phrase is still
  correct as of page render, and the exact timestamp is always present.
  """
  attr :id, :string, required: true
  attr :at, :any, required: true
  attr :now, DateTime, required: true
  attr :class, :string, default: nil
  attr :exact_class, :string, default: "text-xs font-mono text-zinc-500 break-all"

  def countdown(assigns) do
    instant = to_datetime(assigns.at)

    assigns =
      assigns
      |> assign(:instant, instant)
      |> assign(:iso, instant && DateTime.to_iso8601(instant))
      |> assign(:humanized, instant && humanize(instant, assigns.now))

    ~H"""
    <%= if @instant do %>
      <time
        id={@id}
        datetime={@iso}
        title={@iso}
        class={["inline-flex flex-wrap items-baseline gap-x-2 gap-y-0.5", @class]}
      >
        <span
          id={"#{@id}-relative"}
          class="font-medium tabular-nums text-zinc-900 whitespace-nowrap"
          data-countdown-to={@iso}
          data-countdown-direction={to_string(@humanized.direction)}
          aria-label={@humanized.label}
        >
          {@humanized.text}
        </span>
        <span id={"#{@id}-exact"} class={@exact_class}>{@iso}</span>
      </time>
    <% else %>
      <span id={@id} class={["text-xs italic text-zinc-500 break-all", @class]}>
        Recorded value is not a readable timestamp: {inspect(@at)}
      </span>
    <% end %>
    """
  end

  @doc """
  Coerces a `DateTime` or ISO8601 string to a `DateTime`, or `nil`.

  Anything that is not unambiguously an instant returns `nil` so callers can
  say so plainly instead of rendering a guess.

      iex> ShoestringWeb.TimeDisplay.to_datetime("2026-09-08T12:00:00Z")
      ~U[2026-09-08 12:00:00Z]

      iex> ShoestringWeb.TimeDisplay.to_datetime("soon")
      nil
  """
  @spec to_datetime(term()) :: DateTime.t() | nil
  def to_datetime(%DateTime{} = at), do: at

  def to_datetime(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, instant, _offset} -> instant
      _error -> nil
    end
  end

  def to_datetime(_at), do: nil

  @doc """
  Describes the distance from `now` to `at`.

  Returns `:text` (compact, for a ticking display), `:label` (spelled out, for
  assistive technology) and `:direction`. The two largest units are used, and
  every unit after the first is zero padded so the phrase keeps its width as
  it counts down.

      iex> ShoestringWeb.TimeDisplay.humanize(~U[2026-09-07 12:04:32Z], ~U[2026-09-07 12:00:00Z])
      %{direction: :future, text: "in 4m 32s", label: "in 4 minutes 32 seconds"}

      iex> ShoestringWeb.TimeDisplay.humanize(~U[2026-09-07 11:59:18Z], ~U[2026-09-07 12:00:00Z])
      %{direction: :past, text: "42s ago", label: "42 seconds ago"}
  """
  @spec humanize(DateTime.t(), DateTime.t()) :: humanized()
  def humanize(%DateTime{} = at, %DateTime{} = now) do
    seconds = DateTime.diff(at, now, :second)
    magnitude = abs(seconds)

    cond do
      magnitude < 1 -> %{direction: :now, text: "now", label: "now"}
      seconds > 0 -> phrase(:future, magnitude)
      true -> phrase(:past, magnitude)
    end
  end

  defp phrase(direction, magnitude) do
    parts = parts(magnitude)

    %{
      direction: direction,
      text: direction |> decorate(render(parts, &compact/2)),
      label: direction |> decorate(render(parts, &spelled/2))
    }
  end

  # `leading?` is positional, not per unit: only the first unit keeps its
  # natural width, so "3h 09m" never becomes the narrower "3h 9m".
  defp render(parts, formatter) do
    parts
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {part, index} -> formatter.(part, index == 0) end)
  end

  defp decorate(:future, body), do: "in " <> body
  defp decorate(:past, body), do: body <> " ago"

  defp parts(magnitude) when magnitude < @minute, do: [{:second, magnitude}]

  defp parts(magnitude) when magnitude < @hour,
    do: [{:minute, div(magnitude, @minute)}, {:second, rem(magnitude, @minute)}]

  defp parts(magnitude) when magnitude < @day,
    do: [{:hour, div(magnitude, @hour)}, {:minute, rem(div(magnitude, @minute), @minute)}]

  defp parts(magnitude),
    do: [{:day, div(magnitude, @day)}, {:hour, rem(div(magnitude, @hour), 24)}]

  defp compact({unit, value}, leading?), do: "#{pad(value, leading?)}#{suffix(unit)}"

  defp spelled({unit, value}, _leading?), do: "#{value} #{word(unit, value)}"

  defp pad(value, false) when value < 10, do: "0#{value}"
  defp pad(value, _leading?), do: to_string(value)

  defp suffix(:second), do: "s"
  defp suffix(:minute), do: "m"
  defp suffix(:hour), do: "h"
  defp suffix(:day), do: "d"

  defp word(:second, 1), do: "second"
  defp word(:second, _value), do: "seconds"
  defp word(:minute, 1), do: "minute"
  defp word(:minute, _value), do: "minutes"
  defp word(:hour, 1), do: "hour"
  defp word(:hour, _value), do: "hours"
  defp word(:day, 1), do: "day"
  defp word(:day, _value), do: "days"
end
