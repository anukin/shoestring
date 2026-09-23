defmodule ShoestringWeb.GoalPageStylesheetTest do
  @moduledoc """
  Guards the hand-maintained stylesheet behind the Cobbler goal page.

  This project was generated with `--no-tailwind` and has no asset build step,
  so a utility class in the template only does something if a rule for it
  exists in one of the two stylesheets the root layout serves. Nothing else
  would notice a class that silently means nothing, which is how the page came
  to be laid out by markup that the browser was ignoring.
  """

  use ExUnit.Case, async: true

  @templates [
    "lib/shoestring_web/live/cobbler_goal_live.html.heex",
    "lib/shoestring_web/live/time_display.ex"
  ]

  @stylesheets [
    "priv/static/assets/css/app.css",
    "priv/static/assets/default.css"
  ]

  test "every utility class the goal page uses has a rule in a served stylesheet" do
    css = Enum.map_join(@stylesheets, "\n", &File.read!/1)

    unstyled =
      @templates
      |> Enum.flat_map(&classes_in/1)
      |> Enum.uniq()
      |> Enum.reject(&styled?(&1, css))
      |> Enum.sort()

    assert unstyled == [],
           """
           These classes are used by the goal page but have no rule in \
           #{Enum.join(@stylesheets, " or ")}, so the browser ignores them:

             #{Enum.join(unstyled, "\n  ")}

           Add them to priv/static/assets/css/app.css using Tailwind's default \
           values, or stop using them.
           """
  end

  test "the countdown relies on wrapping rules, so they must stay present" do
    app_css = File.read!("priv/static/assets/css/app.css")

    for rule <- [".break-all", ".whitespace-nowrap", ".whitespace-pre-wrap", ".tabular-nums"] do
      assert String.contains?(app_css, rule),
             "#{rule} keeps long identifiers and ticking digits from overflowing a narrow viewport"
    end
  end

  # HEEx carries classes either as a plain attribute or as a list of string
  # literals; only literals are checked, since a computed class cannot be
  # resolved without rendering.
  defp classes_in(path) do
    source = File.read!(path)

    ~r/class=(?:"([^"]*)"|\{\[(.*?)\]\})/s
    |> Regex.scan(source)
    |> Enum.flat_map(fn
      [_full, plain] ->
        String.split(plain)

      [_full, "", list] ->
        list
        |> then(&Regex.scan(~r/"([^"]*)"/, &1))
        |> Enum.flat_map(fn [_, l] -> String.split(l) end)

      _other ->
        []
    end)
    |> Enum.filter(&Regex.match?(~r|^[-a-zA-Z0-9:\[\]./]+$|, &1))
  end

  defp styled?(class, css) do
    selector = "." <> Regex.replace(~r/([.:\[\]\/])/, class, "\\\\\\1")

    Regex.match?(~r/#{Regex.escape(selector)}(?![\w-])/, css)
  end
end
