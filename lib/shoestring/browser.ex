defmodule Shoestring.Browser do
  @moduledoc """
  Opens the web UI in the person's default browser when `shoestring start`
  is serving (iteration 16). Only when the person started it from a
  terminal (the release wrapper sets `SHOESTRING_OPEN_BROWSER=1`; `--no-open`
  or no terminal sets `0`) and Settings' "open on start" is on; never in a
  test, a background service or the source checkout's server.
  """
  require Logger

  @doc """
  Opens `url` when allowed: `:opened` or `:skipped`. Options: `:env` (a
  `System.get_env/1`), `:allowed?` (Settings, by default) and `:opener`.
  """
  def open_on_start(url, opts \\ []) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    allowed? = Keyword.get_lazy(opts, :allowed?, &setting/0)

    if env.("SHOESTRING_OPEN_BROWSER") == "1" and allowed? do
      opener = Keyword.get(opts, :opener, &open/1)
      {:ok, _} = Task.start(fn -> opener.(url) end)
      :opened
    else
      :skipped
    end
  end

  defp setting do
    Shoestring.AgentProfiles.settings().open_browser_on_start != false
  rescue
    _ -> false
  end

  @doc "Opens `url` with the system's opener (`open` on macOS, `xdg-open` elsewhere)."
  def open(url) do
    program = if match?({:unix, :darwin}, :os.type()), do: "open", else: "xdg-open"

    case System.find_executable(program) do
      nil ->
        :ok

      path ->
        case System.cmd(path, [url], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, _} -> Logger.warning("could not open #{url}: #{String.trim(output)}")
        end
    end
  end
end
