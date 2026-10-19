# Explicitly authorized post-fix manual-run verification. Uses the actual
# /runs/new event handler, not an expert bypass or plan run. Required:
# ITER8_MANUAL_ROOT=SHOESTRING_STATE_DIR, a fresh disposable fixture root.
# Pass claude|codex as the sole argument; ITER8_MANUAL_REHEARSAL=1 uses Fake.
# Live calls must pass through provider_budget.py under an authorized budget.
defmodule Iter8ManualProbe do
  import Ecto.Query
  alias Shoestring.{Repo, Worktrees}
  alias Shoestring.Cobbler.GateProcess
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Harness.Dispatch.ElfEffect
  alias Shoestring.Trajectory.TrajectoryEvent

  def root, do: System.fetch_env!("ITER8_MANUAL_ROOT") |> Path.expand()

  def git!(directory, args) do
    {:ok, %{exit_status: 0, output: output}} =
      GateProcess.run(["git" | args], directory, 15_000, 65_536)

    String.trim(output)
  end

  def run(provider) when provider in ["claude", "codex"] do
    rehearsal? = System.get_env("ITER8_MANUAL_REHEARSAL") == "1"
    true = Path.expand(System.fetch_env!("SHOESTRING_STATE_DIR")) == root()
    source = Path.join(root(), "repos/source")
    false = File.exists?(source)
    File.mkdir_p!(Path.join(source, "test"))
    File.mkdir_p!(Path.join(root(), "evidence"))

    File.write!(
      Path.join(source, "calc.py"),
      "def add(a, b):\n" <>
        if(rehearsal?, do: "    return a + b\n", else: "    raise NotImplementedError\n")
    )

    File.write!(Path.join(source, "test/__init__.py"), "")

    File.write!(
      Path.join(source, "test/test_calc.py"),
      "import unittest\nfrom calc import add\nclass CalcTest(unittest.TestCase):\n    def test_sum(self):\n        self.assertEqual(add(2, 3), 5)\n"
    )

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.name", "Fixture"],
          ["config", "user.email", "fixture@example.invalid"],
          ["add", "."],
          ["-c", "commit.gpgsign=false", "commit", "-qm", "Fixture base"]
        ],
        do: git!(source, args)

    base = git!(source, ["rev-parse", "HEAD"])

    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :error)

    Application.put_env(:shoestring, :capacity_monitors,
      claude: [enabled: false],
      codex: [enabled: false]
    )

    Application.put_env(:shoestring, :manual_run_allowed_repo_roots, [root()])

    Application.put_env(:shoestring, :elf_dispatch_opts,
      adapter_opts: %{live: true, model: if(provider == "codex", do: "gpt-6-luna", else: "opus")}
    )

    if rehearsal? do
      Application.put_env(:shoestring, :elf_dispatch_opts,
        adapter: Shoestring.Harness.Fake,
        process_owner: :runner,
        command: ["sleep", "30"],
        adapter_opts: %{
          scenario: Shoestring.Harness.Fake.Scenario.normal_completion(now: DateTime.utc_now())
        }
      )
    end

    config = Application.fetch_env!(:shoestring, Oban)

    Application.put_env(
      :shoestring,
      Oban,
      config |> Keyword.put(:plugins, []) |> Keyword.put(:queues, dispatch: 2)
    )

    Shoestring.CLI.Repository.with_repo(fn _ -> :ok end)
    {:ok, _} = Application.ensure_all_started(:shoestring)

    socket = %Phoenix.LiveView.Socket{
      endpoint: ShoestringWeb.Endpoint,
      router: ShoestringWeb.Router,
      assigns: %{__changed__: %{}, flash: %{}}
    }

    {:ok, socket} = ShoestringWeb.RunNewLive.mount(%{}, %{}, socket)

    params = %{
      "repo_path" => source,
      "base_revision" => "HEAD",
      "provider" => provider,
      "prompt" =>
        "Implement add(a,b) in calc.py as a+b. Change only calc.py; do not modify tests. Run python3 -B -m unittest test/test_calc.py. Commit the change with the configured author and no authorship, contributor or co-author trailers. Do not push, delete files or clean up.",
      "timeout_seconds" => "180",
      "max_events" => "1000",
      "lease_seconds" => "300"
    }

    {:noreply, _socket} =
      ShoestringWeb.RunNewLive.handle_event("start_run", %{"run" => params}, socket)

    run = Repo.one!(from r in RunRecord, order_by: [desc: r.inserted_at], limit: 1)
    {:ok, wt} = Worktrees.get(run.id)
    true = wt.metadata["shoestring.manual:source"] == source

    {:ok, %{"writableRoots" => roots}} =
      Shoestring.Harness.CodexAppServer.GitSandbox.policy(wt.path, wt.workspace_ref)

    {:ok, opts} = ElfEffect.launch_opts(run)
    if provider == "claude" and not rehearsal?, do: true = opts[:adapter_opts][:sandbox] == true
    :ok = Phoenix.PubSub.subscribe(Shoestring.PubSub, Shoestring.Trajectory.topic(run.goal_id))
    terminal = terminal!(run, System.monotonic_time(:millisecond) + 360_000)

    if pid = Shoestring.Elves.whereis(run.id) do
      monitor = Process.monitor(pid)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        30_000 -> raise "manual Elf did not finish disposal"
      end
    end

    head = git!(wt.path, ["rev-parse", "HEAD"])

    {:ok, tests} =
      GateProcess.run(
        ["python3", "-B", "-m", "unittest", "test/test_calc.py"],
        wt.path,
        30_000,
        65_536
      )

    summary = %{
      provider: provider,
      rehearsal: rehearsal?,
      terminal: terminal.type,
      base: base,
      commit: head,
      commits: String.to_integer(git!(wt.path, ["rev-list", "--count", base <> "..HEAD"])),
      source_unchanged:
        git!(source, ["rev-parse", "HEAD"]) == base and
          git!(source, ["status", "--porcelain"]) == "",
      private_git: wt.repo_path != source,
      private_git_roots: length(roots),
      claude_sandbox_requested: provider == "claude" and opts[:adapter_opts][:sandbox] == true,
      manual_source_recorded: wt.metadata["shoestring.manual:source"] == source,
      test_exit: tests.exit_status,
      test_output: tests.output,
      commit_message: git!(wt.path, ["show", "-s", "--format=%B", "HEAD"])
    }

    File.write!(Path.join(root(), "evidence/manual.json"), Jason.encode!(summary, pretty: true))
    IO.puts(Jason.encode!(summary))
    true = terminal.type == "run.completed"
    true = rehearsal? or head != base
    true = summary.source_unchanged
    true = tests.exit_status == 0
    :ok
  end

  defp terminal!(run, deadline) do
    case Repo.one(
           from e in TrajectoryEvent,
             where:
               e.run_id == ^run.id and
                 e.type in ["run.completed", "run.failed", "run.cancelled", "run.interrupted"],
             order_by: [desc: e.sequence],
             limit: 1
         ) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("manual verification deadline")

        receive do
          _ -> :ok
        after
          100 -> :ok
        end

        terminal!(run, deadline)

      event ->
        event
    end
  end
end

[provider] = System.argv()
Iter8ManualProbe.run(provider)
