defmodule Shoestring.Coordinator.ToolTokens do
  @moduledoc """
  Bearer tokens for the coordinator's MCP tool endpoint (iteration 15,
  package B). A token binds a coordinator conversation to its grant's
  session and its repository; every tool call acts for that session in that
  repository only, whatever its arguments say.

  Tokens live in memory, keyed by their SHA-256, never in the database: a
  service restart forgets them, and a relaunched conversation gets a new
  one. A token is revoked when the process that asked for it exits, so it
  cannot outlive its conversation.
  """

  use GenServer

  @table __MODULE__

  @type binding :: %{session_id: String.t(), repository: Path.t()}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "A new token for `binding`, revoked when `owner` exits."
  @spec issue(binding(), pid()) :: String.t()
  def issue(%{session_id: session, repository: repository} = binding, owner \\ self())
      when is_binary(session) and session != "" and is_binary(repository) and is_pid(owner) do
    GenServer.call(__MODULE__, {:issue, Map.take(binding, [:session_id, :repository]), owner})
  end

  @doc "The binding of `token`, or `:error`."
  @spec lookup(String.t()) :: {:ok, binding()} | :error
  def lookup(token) when is_binary(token) and token != "" do
    case :ets.lookup(@table, hash(token)) do
      [{_hash, binding, _owner}] -> {:ok, binding}
      [] -> :error
    end
  end

  def lookup(_token), do: :error

  @doc "Revokes `token`; unknown tokens are ignored."
  @spec revoke(String.t()) :: :ok
  def revoke(token) when is_binary(token), do: GenServer.call(__MODULE__, {:revoke, hash(token)})

  defp hash(token), do: :crypto.hash(:sha256, token)

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:issue, binding, owner}, _from, monitors) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    key = hash(token)
    :ets.insert(@table, {key, binding, owner})
    ref = Process.monitor(owner)
    {:reply, token, Map.put(monitors, ref, key)}
  end

  def handle_call({:revoke, key}, _from, monitors) do
    :ets.delete(@table, key)
    {:reply, :ok, monitors}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _owner, _reason}, monitors) do
    {key, monitors} = Map.pop(monitors, ref)
    if key, do: :ets.delete(@table, key)
    {:noreply, monitors}
  end
end
