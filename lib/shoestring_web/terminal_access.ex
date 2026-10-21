defmodule ShoestringWeb.TerminalAccess do
  @moduledoc "Capabilities scoped to a local signed browser session and one existing interactive run."
  alias ShoestringWeb.{Endpoint, TerminalBrowser}
  alias Shoestring.Harness.RunRecord
  @providers ~w(fixture_interactive_pty claude_interactive_pty codex_interactive_pty)
  def interactive?(%RunRecord{provider_id: provider}), do: provider in @providers
  def interactive?(_run), do: false

  def tokens(browser, run_id) do
    if TerminalBrowser.valid?(browser) do
      {:ok,
       %{
         socket_token: Phoenix.Token.sign(Endpoint, "terminal-browser-v1", browser),
         capability: Phoenix.Token.sign(Endpoint, "terminal-run-v1", {browser, run_id})
       }}
    else
      {:error, :local_browser_required}
    end
  end

  def socket(token, browser) when is_binary(token) do
    with true <- TerminalBrowser.valid?(browser),
         {:ok, ^browser} <-
           Phoenix.Token.verify(Endpoint, "terminal-browser-v1", token, max_age: 300) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  def socket(_token, _browser), do: {:error, :unauthorized}

  def authorize(token, browser, run_id) when is_binary(token) and is_binary(run_id) do
    with {:ok, _} <- Ecto.UUID.cast(run_id),
         {:ok, {^browser, ^run_id}} <-
           Phoenix.Token.verify(Endpoint, "terminal-run-v1", token, max_age: 300),
         %RunRecord{} = run <- Shoestring.Repo.get(RunRecord, run_id),
         true <- interactive?(run) do
      {:ok, run}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize(_token, _browser, _run_id), do: {:error, :unauthorized}
end
