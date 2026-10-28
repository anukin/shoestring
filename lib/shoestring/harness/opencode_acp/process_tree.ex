defmodule Shoestring.Harness.OpencodeAcp.ProcessTree do
  @moduledoc """
  Reaps every process group under an `opencode acp` process.

  `opencode acp` starts `opencode serve --stdio` as a child that leads its own
  process group (VERIFIED, 2.0.31), so a `killpg` of the acp group alone does
  not signal it. The child exited within 0.5 s of the acp group being killed
  in every observed run, but a shell tool runs as the server's child in a
  process group of its own (VERIFIED: a `sleep 45` had pgid = its pid), and
  nothing guarantees it dies with its parent. Cancellation therefore
  snapshots the descendant tree first
  and signals each distinct group in it, then the root group, with a bounded
  TERM → KILL escalation. The caller's own group is never signalled.

  Groups seen earlier can be passed as `:known`: once the acp process has
  died its descendants are reparented and no longer reachable through the
  tree, but processes still in a dead leader's group can be signalled by the
  group id.
  """

  @grace_ms 2_000
  @poll_ms 50

  @doc "Process groups of `root` and all its descendants, root group first."
  @spec groups(pos_integer(), (-> [{integer(), integer(), integer()}])) :: [pos_integer()]
  def groups(root, table \\ &table/0) when is_integer(root) and root > 1 do
    rows = table.()
    children = Enum.group_by(rows, fn {_pid, ppid, _pgid} -> ppid end)
    pgid_of = Map.new(rows, fn {pid, _ppid, pgid} -> {pid, pgid} end)

    descendants = walk([root], children, MapSet.new([root]))
    own = own_group()

    [Map.get(pgid_of, root, root) | Enum.map(descendants, &Map.get(pgid_of, &1))]
    |> Enum.reject(&(is_nil(&1) or &1 <= 1 or &1 == own))
    |> Enum.uniq()
  end

  @doc """
  Terminates `root`'s process tree: TERM to every group, wait up to the grace
  period, KILL what remains. Returns the groups signalled.
  """
  @spec reap(pos_integer() | nil, keyword()) :: [pos_integer()]
  def reap(root, opts \\ [])
  def reap(nil, _opts), do: []

  def reap(root, opts) when is_integer(root) and root > 1 do
    own = own_group()

    groups =
      (groups(root, Keyword.get(opts, :table, &table/0)) ++
         Enum.to_list(Keyword.get(opts, :known, [])))
      |> Enum.reject(&(&1 <= 1 or &1 == own))
      |> Enum.uniq()

    Enum.each(groups, &signal(&1, "TERM"))
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :grace_ms, @grace_ms)

    case wait(groups, deadline) do
      [] -> :ok
      alive -> Enum.each(alive, &signal(&1, "KILL"))
    end

    groups
  end

  def reap(_root, _opts), do: []

  defp walk([], _children, seen), do: MapSet.to_list(seen)

  defp walk([pid | rest], children, seen) do
    kids =
      children
      |> Map.get(pid, [])
      |> Enum.map(fn {child, _ppid, _pgid} -> child end)
      |> Enum.reject(&MapSet.member?(seen, &1))

    walk(rest ++ kids, children, Enum.reduce(kids, seen, &MapSet.put(&2, &1)))
  end

  defp wait(groups, deadline) do
    alive = Enum.filter(groups, &alive?/1)

    if alive == [] or System.monotonic_time(:millisecond) >= deadline do
      alive
    else
      Process.sleep(@poll_ms)
      wait(alive, deadline)
    end
  end

  @doc "Whether any process in group `pgid` is still running."
  @spec alive?(pos_integer()) :: boolean()
  def alive?(pgid) when is_integer(pgid) and pgid > 1 do
    match?({_, 0}, System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true))
  end

  defp signal(pgid, signal) do
    _ = System.cmd("kill", ["-#{signal}", "-#{pgid}"], stderr_to_stdout: true)
    :ok
  end

  defp own_group do
    case System.cmd("ps", ["-o", "pgid=", "-p", System.pid()], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> String.to_integer()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  def table do
    case System.cmd("ps", ["-axo", "pid=,ppid=,pgid="], stderr_to_stdout: true) do
      {out, 0} ->
        for line <- String.split(out, "\n", trim: true),
            [pid, ppid, pgid] <- [String.split(line)],
            do: {String.to_integer(pid), String.to_integer(ppid), String.to_integer(pgid)}

      _ ->
        []
    end
  end
end
