defmodule Shoestring.Test.TerminalHelpers do
  @moduledoc "Local fixture TUI and private Git storage; no provider or network. Scratch evidence is retained."
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Harness.{Dispatches, Interactive}

  def create!(provider \\ "fixture", prompt \\ "Terminal fixture request") do
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    run_id = Ecto.UUID.generate()
    source = Path.join(System.tmp_dir!(), "shoestring-terminal-fixture-#{run_id}")
    File.mkdir_p!(source)

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.name", "Terminal Fixture"],
          ["config", "user.email", "fixture@example.test"]
        ],
        do: {_, 0} = System.cmd("git", args, cd: source)

    File.write!(Path.join(source, "README.md"), "Harmless terminal fixture\n")
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: source)

    {_, 0} =
      System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-qm", "Fixture baseline"],
        cd: source
      )

    {:ok, worktree} = Shoestring.Worktrees.create(source, run_id, "HEAD", private_git: true)

    request =
      ElvesHelpers.run_request(goal, task,
        workspace_ref: worktree.workspace_ref,
        prompt: prompt,
        dispatch_id: Ecto.UUID.generate()
      )

    identity = Interactive.identity(provider)
    {:ok, dispatch, _job} = Dispatches.enqueue(request, identity, run_id: run_id)

    %{
      goal: goal,
      task: task,
      request: request,
      dispatch: dispatch,
      worktree: worktree,
      source: source
    }
  end

  def session!(fixture, owner \\ self()) do
    ExUnit.Callbacks.start_supervised!(
      {Shoestring.Terminal.Session,
       request: fixture.request, provider: "fixture", workdir: fixture.worktree.path, owner: owner}
    )
  end

  def ready_fixture!(run_id) do
    {:ok, snapshot} = Shoestring.Terminal.Session.attach(run_id, :crypto.strong_rand_bytes(32))
    :ok = Shoestring.Terminal.Session.ack(run_id, snapshot.sequence)
    bytes = Base.decode64!(snapshot.data)

    if :binary.match(bytes, "SIZE 24 80") == :nomatch,
      do: output_until(run_id, "SIZE 24 80", bytes)

    :ok = Shoestring.Terminal.Session.detach(run_id)
  end

  def output_until(run_id, expected, acc \\ <<>>) do
    receive_output(run_id, expected, acc, System.monotonic_time(:millisecond) + 5000)
  end

  defp receive_output(run_id, expected, acc, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:terminal_output, sequence, bytes} ->
        :ok = Shoestring.Terminal.Session.ack(run_id, sequence)
        acc = acc <> bytes
        ExUnit.Assertions.assert(byte_size(acc) <= 65_536, "fixture output exceeded its bound")

        if :binary.match(acc, expected) != :nomatch,
          do: acc,
          else: receive_output(run_id, expected, acc, deadline)
    after
      remaining -> ExUnit.Assertions.flunk("fixture terminal did not produce expected bytes")
    end
  end
end
