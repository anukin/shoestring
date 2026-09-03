defmodule Shoestring.Harness.Capacity.CommandRunner do
  @moduledoc """
  Injectable boundary for executing external provider CLI commands and discovering versions.

  Normal unit tests must not require installed provider CLIs or network access;
  an injected or mock runner should be used in test environments.
  """

  @callback cmd(binary(), [binary()], keyword()) :: {binary(), non_neg_integer()}
  @callback find_executable(binary()) :: binary() | nil
end
