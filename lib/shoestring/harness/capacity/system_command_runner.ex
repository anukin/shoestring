defmodule Shoestring.Harness.Capacity.SystemCommandRunner do
  @moduledoc false
  @behaviour Shoestring.Harness.Capacity.CommandRunner

  @impl true
  def cmd(command, args, opts \\ []), do: System.cmd(command, args, opts)

  @impl true
  def find_executable(command), do: System.find_executable(command)
end
