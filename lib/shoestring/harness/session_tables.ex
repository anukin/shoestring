defmodule Shoestring.Harness.SessionTables do
  @moduledoc """
  Supervised ownership of the execution adapters' session indexes.

  An Elf may finish while a sibling session is still producing events. The
  session index must therefore outlive any individual caller. The adapters
  retain their existing public ETS lookup/registration boundary; this process
  owns the tables for the application's lifetime, without timers, eviction,
  cancellation or starting replacement work.
  """
  use GenServer

  @tables [:claude_headless_sessions, :codex_app_server_sessions]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def ensure_table(table) when table in @tables do
    if :ets.whereis(table) == :undefined,
      do: GenServer.call(__MODULE__, {:ensure_table, table}),
      else: :ok
  end

  @impl true
  def init(_opts) do
    Enum.each(@tables, &create_table/1)
    {:ok, nil}
  end

  @impl true
  def handle_call({:ensure_table, table}, _from, state) when table in @tables do
    create_table(table)
    {:reply, :ok, state}
  end

  defp create_table(table) do
    if :ets.whereis(table) == :undefined,
      do: :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
  end
end
