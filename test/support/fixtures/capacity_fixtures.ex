defmodule Shoestring.Test.Fixtures.CapacityFixtures do
  @moduledoc """
  ExUnit test helper module delegating to `Shoestring.Harness.Capacity.Fixtures`.
  """

  alias Shoestring.Harness.Capacity.Fixtures

  defdelegate fixture_root(), to: Fixtures
  defdelegate list_fixtures(), to: Fixtures
  defdelegate load_fixture(rel_path), to: Fixtures
  defdelegate load_fixture!(rel_path), to: Fixtures
  defdelegate scan_term(term), to: Fixtures
  defdelegate scan_all_fixtures(), to: Fixtures
end
