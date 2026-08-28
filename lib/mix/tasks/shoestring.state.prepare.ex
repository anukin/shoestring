defmodule Mix.Tasks.Shoestring.State.Prepare do
  @shortdoc "Prepares Shoestring's local state root"

  @moduledoc """
  Creates and verifies the configured state root before Ecto opens SQLite.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Shoestring.State.ensure_writable_root!()
  end
end
