defmodule Shoestring.WorktreesGitObserveTest do
  @moduledoc """
  Two separate VMs observe their own worktrees at the same time. Each VM's
  unique integers count up from 1, so a private index copy named by them alone
  is shared between VMs in the system temp directory. Both VMs here advance
  their counters to the same value and start at the same instant, which makes
  their names coincide.
  """
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Shoestring.Worktrees.Git

  @rounds 60

  test "concurrent VMs each read their own worktree status", %{tmp_dir: dir} do
    repos =
      for name <- ["left", "right"] do
        path = Path.join(dir, name)
        File.mkdir_p!(path)
        git!(path, ["init", "-q"])
        File.write!(Path.join(path, "#{name}.txt"), "base\n")
        git!(path, ["add", "."])

        git!(path, [
          "-c",
          "user.name=T",
          "-c",
          "user.email=t@example.com",
          "commit",
          "-qm",
          "base"
        ])

        File.write!(Path.join(path, "#{name}.txt"), "changed\n")
        {name, path}
      end

    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    peers =
      for {name, path} <- repos do
        {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})
        {name, path, peer}
      end

    # Both peers are up; they begin observing together shortly after.
    start_at = System.os_time(:millisecond) + 500

    results =
      peers
      |> Enum.map(fn {name, path, peer} ->
        Task.async(fn ->
          # Test modules are not loaded in the peer, so the loop is evaluated there.
          {observed, _binding} =
            :peer.call(
              peer,
              Code,
              :eval_string,
              [
                """
                Stream.repeatedly(fn -> System.unique_integer([:positive, :monotonic]) end)
                |> Enum.find(&(&1 >= 100_000))

                Process.sleep(max(start_at - System.os_time(:millisecond), 0))
                Enum.map(1..rounds, fn _ -> Shoestring.Worktrees.Git.observe(path, args) end)
                """,
                [
                  rounds: @rounds,
                  path: path,
                  args: ["status", "--porcelain=v1"],
                  start_at: start_at
                ]
              ],
              60_000
            )

          {name, Enum.frequencies(observed)}
        end)
      end)
      |> Task.await_many(70_000)

    Enum.each(peers, fn {_name, _path, peer} -> :peer.stop(peer) end)

    for {name, outcomes} <- results do
      assert outcomes == %{{" M #{name}.txt\n", 0} => @rounds}
    end
  end

  defp git!(path, args) do
    {_, 0} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
  end
end
