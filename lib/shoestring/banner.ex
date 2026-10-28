defmodule Shoestring.Banner do
  @moduledoc "What the service prints once it is serving."

  @shoe ~S"""
         __________
        |  x x x   \
        |  x x x    \_________
        |_____________________`\
        (_______________________)
  """

  @doc "The banner: a shoe, the version and where the service is listening."
  def text(url) do
    version = :shoestring |> Application.spec(:vsn) |> to_string()
    @shoe <> "     shoestring #{version} at #{url}\n"
  end

  def print(url), do: IO.puts(text(url))
end
