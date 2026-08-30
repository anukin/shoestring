defmodule Shoestring.Trajectory.AppendInputTest do
  use ExUnit.Case, async: true

  alias Shoestring.Trajectory.AppendInput

  test "a non-map append input returns the stable must-be-a-map error" do
    assert {:error, {:invalid_append_input, changeset}} = AppendInput.cast(:not_an_input)

    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    assert "must be a map" in errors.base
  end
end
