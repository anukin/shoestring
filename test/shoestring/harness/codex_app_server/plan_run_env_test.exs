defmodule Shoestring.Harness.CodexAppServer.PlanRunEnvTest do
  @moduledoc """
  A Codex run in private per-run Git storage (a plan run) is launched with
  PYTHONDONTWRITEBYTECODE=1, like a sandboxed Claude Elf; other runs keep the
  inherited environment. Local git and python3 only; no Codex CLI.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Harness.Capacity.Codex.StdioTransport
  alias Shoestring.Harness.CodexAppServer.Session
  alias Shoestring.Harness.RunRequest
  alias Shoestring.Worktrees

  defmodule CaptureTransport do
    @moduledoc false
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def send_frame(_pid, _frame), do: :ok
    def os_pid(_pid), do: nil
    def close(pid), do: GenServer.stop(pid, :normal)

    @impl true
    def init(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:transport_opts, opts})
      {:ok, opts}
    end
  end

  @moduletag :tmp_dir

  test "the transport sets the given variables in the launched process" do
    {:ok, transport} =
      StdioTransport.start_link(
        owner: self(),
        executable: System.find_executable("python3"),
        args: ["-c", "import os; print(os.environ.get('PYTHONDONTWRITEBYTECODE', 'unset'))"],
        env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
      )

    assert_receive {:codex_transport_frame, ^transport, "1"}, 5_000
  end

  test "only a plan run's session asks for it", %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    File.mkdir_p!(source)
    git!(source, ["init", "-q", "-b", "main"])
    File.write!(Path.join(source, "a.txt"), "a\n")
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-qm",
      "Base"
    ])

    {:ok, private} = Worktrees.create(source, Ecto.UUID.generate(), "HEAD", private_git: true)
    {:ok, shared} = Worktrees.create(source, Ecto.UUID.generate(), "HEAD")

    for {wt, expected} <- [{private, [{"PYTHONDONTWRITEBYTECODE", "1"}]}, {shared, nil}] do
      {:ok, session} =
        Session.start_link(
          run_request: request(wt.workspace_ref),
          workdir: wt.path,
          transport: CaptureTransport,
          transport_opts: [test_pid: self()],
          auto_handshake: false
        )

      assert_receive {:transport_opts, opts}, 5_000
      assert opts[:env] == expected
      GenServer.stop(session, :normal)
    end
  end

  defp request(workspace_ref) do
    {:ok, req} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        dispatch_id: "00000000-0000-4000-8000-000000000003",
        workspace_ref: workspace_ref,
        prompt: "Check the fixture",
        policy: %{mode: "supervised"},
        requested_capabilities: []
      })

    req
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end
end
