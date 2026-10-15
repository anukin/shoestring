# Diagnostic probe for the Exqlite statement-destructor stall. Not part of the
# hermetic gate: under `mix test` the stall does not reproduce (the same steps
# finish in about 160 ms there), so it lives here instead of in the suite.
#
#   P holds the SQLite write lock on connection A, after using and dropping a
#   statement of connection B.
#   Q runs BEGIN IMMEDIATE on B and waits in Exqlite's busy handler.
#   P collects garbage, then writes and commits.
#
# Exqlite 0.40's destructor took B's mutex, which Q held for its whole busy
# wait. P stalled until Q's busy timeout expired, and Q then failed with
# "database is locked". From 0.42 the destructor defers the finalize, P
# commits at once and Q gets the lock.
#
# Usage (raw Exqlite only; no application, provider or network):
#
#     MIX_ENV=test mix run --no-start tools/diagnostics/exqlite_destructor_stall.exs [busy_timeout_ms] < /dev/null
#
# Prints one line and exits 0 when Q got the lock, 1 when it did not. The
# database lives in a fresh temporary directory and is retained.
alias Exqlite.Sqlite3

defmodule ExqliteDestructorStall do
  alias Exqlite.Sqlite3

  # The statement lives only in this frame, so the caller's next collection
  # drops the resource.
  def use_and_drop_statement(conn) do
    {:ok, statement} = Sqlite3.prepare(conn, "SELECT count(*) FROM t")
    {:row, _} = Sqlite3.step(conn, statement)
    Sqlite3.release(conn, statement)
  end
end

busy_timeout =
  case System.argv() do
    [ms] -> String.to_integer(ms)
    [] -> 3_000
  end

suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
directory = Path.join(System.tmp_dir!(), "exqlite-destructor-#{suffix}")
File.mkdir_p!(directory)
database = Path.join(directory, "probe.db")

open = fn ->
  {:ok, conn} = Sqlite3.open(database)
  :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
  :ok = Sqlite3.set_busy_timeout(conn, busy_timeout)
  conn
end

a = open.()
:ok = Sqlite3.execute(a, "CREATE TABLE t (x)")
b = open.()
parent = self()

holder =
  spawn(fn ->
    :ok = ExqliteDestructorStall.use_and_drop_statement(b)
    :ok = Sqlite3.execute(a, "BEGIN IMMEDIATE")
    send(parent, :holding_write_lock)

    receive do
      :collect -> :ok
    end

    true = :erlang.garbage_collect()
    {insert_us, :ok} = :timer.tc(fn -> Sqlite3.execute(a, "INSERT INTO t VALUES (1)") end)
    :ok = Sqlite3.execute(a, "COMMIT")
    send(parent, {:committed, div(insert_us, 1000)})
  end)

receive do
  :holding_write_lock -> :ok
end

started = System.monotonic_time(:millisecond)

spawn(fn ->
  result = Sqlite3.execute(b, "BEGIN IMMEDIATE")
  send(parent, {:waiter, System.monotonic_time(:millisecond) - started, result})
end)

# Lets the waiter enter the busy handler; nothing observable marks it there.
Process.sleep(100)
send(holder, :collect)

limit = busy_timeout * 2

{insert_ms, waiter_ms, result} =
  receive do
    {:committed, insert_ms} ->
      receive do
        {:waiter, waiter_ms, result} -> {insert_ms, waiter_ms, result}
      after
        limit -> {insert_ms, nil, :no_reply}
      end
  after
    limit -> {nil, nil, :no_reply}
  end

{:ok, version} = :application.get_key(:exqlite, :vsn)

IO.puts(
  "exqlite=#{version} busy_timeout=#{busy_timeout}ms holder_insert=#{insert_ms}ms " <>
    "waiter_returned=#{waiter_ms}ms waiter=#{inspect(result)}"
)

System.halt(if(result == :ok, do: 0, else: 1))
