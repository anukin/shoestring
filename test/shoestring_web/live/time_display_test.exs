defmodule ShoestringWeb.TimeDisplayTest do
  @moduledoc """
  Covers the countdown presentation itself: the phrase format, the parity
  table shared with the browser enhancer, and the guarantee that the exact
  timestamp survives humanization.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ShoestringWeb.TimeDisplay

  doctest ShoestringWeb.TimeDisplay

  @now ~U[2026-09-07 12:00:00.000000Z]
  @parity_fixture "test/fixtures/countdown_phrases.json"

  describe "humanize/2" do
    test "matches every case in the phrase parity table shared with the browser" do
      for kase <- parity_cases() do
        offset = kase["offset_seconds"]
        at = DateTime.add(@now, offset, :second)

        assert TimeDisplay.humanize(at, @now) == %{
                 direction: String.to_existing_atom(kase["direction"]),
                 text: kase["text"],
                 label: kase["label"]
               },
               "offset #{offset}s"
      end
    end

    test "sub-second distances follow DateTime.diff/3, which floors" do
      # Documented rather than smoothed over: the browser enhancer floors the
      # same way, so a phrase does not flip when the script takes over.
      assert %{direction: :now, text: "now"} =
               TimeDisplay.humanize(DateTime.add(@now, 900, :millisecond), @now)

      assert %{direction: :past, text: "1s ago"} =
               TimeDisplay.humanize(DateTime.add(@now, -900, :millisecond), @now)
    end

    test "trailing units are zero padded so a ticking phrase keeps its width" do
      widths =
        for offset <- [11_100, 11_160, 11_220, 11_280], into: MapSet.new() do
          TimeDisplay.humanize(DateTime.add(@now, offset, :second), @now).text
          |> String.length()
        end

      assert MapSet.size(widths) == 1
    end
  end

  describe "to_datetime/1" do
    test "accepts the shapes the goal page actually holds" do
      assert TimeDisplay.to_datetime(@now) == @now

      assert TimeDisplay.to_datetime("2026-09-08T12:00:00.000000Z") ==
               ~U[2026-09-08 12:00:00.000000Z]
    end

    test "refuses to guess at values that are not instants" do
      assert TimeDisplay.to_datetime("soon") == nil
      assert TimeDisplay.to_datetime("2026-09-08") == nil
      assert TimeDisplay.to_datetime(nil) == nil
      assert TimeDisplay.to_datetime(%{"at" => "2026-09-08T12:00:00Z"}) == nil
    end
  end

  describe "countdown/1" do
    test "renders the relative phrase and keeps the exact timestamp in three places" do
      html = render_countdown(at: DateTime.add(@now, 272, :second))

      assert html =~ ~s(datetime="2026-09-07T12:04:32.000000Z")
      assert html =~ ~s(title="2026-09-07T12:04:32.000000Z")
      assert html =~ ~s(id="probe-exact")
      assert html =~ "2026-09-07T12:04:32.000000Z</span>"
      assert html =~ "in 4m 32s"
    end

    test "exposes a spelled-out label and direction for assistive technology" do
      future = render_countdown(at: DateTime.add(@now, 272, :second))
      past = render_countdown(at: DateTime.add(@now, -272, :second))

      assert future =~ ~s(aria-label="in 4 minutes 32 seconds")
      assert future =~ ~s(data-countdown-direction="future")
      assert past =~ ~s(aria-label="4 minutes 32 seconds ago")
      assert past =~ ~s(data-countdown-direction="past")
    end

    test "publishes the tick target the browser enhancer binds to" do
      html = render_countdown(at: "2026-09-08T12:00:00.000000Z")

      assert html =~ ~s(data-countdown-to="2026-09-08T12:00:00.000000Z")
    end

    test "states an unreadable recorded value instead of rendering a guess" do
      html = render_countdown(at: "whenever capacity frees up")

      assert html =~ "not a readable timestamp"
      assert html =~ "whenever capacity frees up"
      refute html =~ "data-countdown-to"
      refute html =~ "ago"
    end
  end

  defp render_countdown(opts) do
    render_component(&TimeDisplay.countdown/1, %{
      id: "probe",
      at: Keyword.fetch!(opts, :at),
      now: @now
    })
  end

  defp parity_cases do
    @parity_fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("cases")
  end
end
