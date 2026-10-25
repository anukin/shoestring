defmodule ShoestringWeb.InputAccessibilityTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias ShoestringWeb.CoreComponents

  test "every visible input type associates errors without losing its help" do
    for type <- ["text", "textarea", "select", "checkbox"] do
      attrs = [
        id: "test-field",
        name: "field",
        label: "Field",
        type: type,
        value: "value",
        options: [{"Value", "value"}],
        errors: ["Choose a valid value", "A second error"],
        "aria-describedby": "field-help"
      ]

      document = render_component(&CoreComponents.input/1, attrs) |> LazyHTML.from_fragment()
      field = LazyHTML.query(document, "#test-field")
      assert LazyHTML.attribute(field, "aria-invalid") == ["true"], type

      assert LazyHTML.attribute(field, "aria-describedby") == ["field-help test-field-errors"],
             type

      errors = LazyHTML.query(document, "#test-field-errors")
      assert LazyHTML.text(errors) =~ "Choose a valid value", type
      assert LazyHTML.text(errors) =~ "A second error", type

      valid =
        render_component(&CoreComponents.input/1, Keyword.put(attrs, :errors, []))
        |> LazyHTML.from_fragment()

      assert LazyHTML.attribute(LazyHTML.query(valid, "#test-field"), "aria-invalid") == [], type

      assert LazyHTML.attribute(LazyHTML.query(valid, "#test-field"), "aria-describedby") == [
               "field-help"
             ],
             type

      assert LazyHTML.query(valid, "#test-field-errors") |> Enum.empty?(), type
    end
  end
end
