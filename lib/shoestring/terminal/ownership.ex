defmodule Shoestring.Terminal.Ownership do
  @moduledoc "Exclusive terminal input authority. Only a trusted controller declares an automation boundary."
  defstruct state: :agent_owned, browser: nil, client: nil, safe?: true

  def request(%{state: :agent_owned, safe?: safe?} = ownership, browser, client) do
    state = if safe?, do: :human_owned, else: :takeover_requested
    {:ok, %{ownership | state: state, browser: browser, client: client}}
  end

  def request(%{state: :detached_human_owned, browser: browser} = ownership, browser, client),
    do: {:ok, %{ownership | state: :human_owned, client: client}}

  def request(
        %{state: :human_owned, browser: browser, client: client} = ownership,
        browser,
        client
      ),
      do: {:ok, ownership}

  def request(_ownership, _browser, _client), do: {:error, :terminal_owned}

  def boundary(%{state: :takeover_requested, client: nil} = ownership),
    do: %{ownership | state: :detached_human_owned, safe?: true}

  def boundary(%{state: :takeover_requested} = ownership),
    do: %{ownership | state: :human_owned, safe?: true}

  def boundary(ownership), do: %{ownership | safe?: true}

  def agent_input(%{state: :agent_owned} = ownership),
    do: {:ok, %{ownership | safe?: false}}

  def agent_input(_ownership), do: {:error, :terminal_owned}

  def human_input(%{state: :human_owned, browser: browser, client: client}, browser, client),
    do: :ok

  def human_input(_ownership, _browser, _client), do: {:error, :not_input_owner}

  def release(%{state: :human_owned, browser: browser, client: client}, browser, client),
    do: {:ok, %__MODULE__{}}

  def release(_ownership, _browser, _client), do: {:error, :not_input_owner}

  def detach(%{client: client, state: :human_owned} = ownership, client),
    do: %{ownership | state: :detached_human_owned, client: nil}

  def detach(%{client: client} = ownership, client), do: %{ownership | client: nil}
  def detach(ownership, _client), do: ownership

  def public(ownership), do: Atom.to_string(ownership.state)
end
