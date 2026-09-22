defmodule Mix.Tasks.Ui.NodeTest do
  @shortdoc "Runs the browser-side UI regression tests"

  @moduledoc """
  Runs `node --test` over every browser-side UI test file (`test/ui_*.test.js`)
  so the scripts served from `priv/static/assets/js/` are gated the same way
  the Elixir code is.

  This project has no asset build step, so `priv/static/assets/js/app.js` is
  hand maintained and shipped as written. Nothing else would catch a change to
  it, which is exactly why it is a gate step rather than a convention.
  """

  use Mix.Task

  @required_test_files ["test/ui_countdown.test.js"]

  @impl Mix.Task
  def run(_args) do
    node = System.find_executable("node") || Mix.raise("node executable not found on PATH")

    missing_required = Enum.reject(@required_test_files, &File.exists?/1)

    if missing_required != [] do
      Mix.raise("Missing required UI Node.js test file(s): #{Enum.join(missing_required, ", ")}")
    end

    test_files = "test/ui_*.test.js" |> Path.wildcard() |> Enum.sort()

    {output, exit_status} = System.cmd(node, ["--test" | test_files], stderr_to_stdout: true)

    Mix.shell().info(output)

    if exit_status != 0 do
      Mix.raise("UI Node.js tests failed (exit status #{exit_status})")
    end
  end
end
