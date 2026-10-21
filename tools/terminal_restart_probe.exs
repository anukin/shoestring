# Hermetic, two-VM crash/restart probe. Uses only the packaged fixture TUI.
# Both invocations must share a fresh SHOESTRING_TEST_STATE_DIR.
if Mix.env() != :test, do: raise("Use MIX_ENV=test")

unless System.get_env("SHOESTRING_TEST_STATE_DIR"),
  do: raise("Use a fresh explicit test state root")

stage = List.last(System.argv())
unless stage in ["crash", "recover"], do: raise("Choose crash or recover")

repo = Application.fetch_env!(:shoestring, Shoestring.Repo)

Application.put_env(
  :shoestring,
  Shoestring.Repo,
  Keyword.merge(repo, pool: DBConnection.ConnectionPool, pool_size: 5)
)

Mix.Task.run("shoestring.state.prepare")
Mix.Task.run("ecto.create", ["--quiet"])
Mix.Task.run("ecto.migrate", ["--quiet", "--pool-size", "1"])
Application.put_env(:shoestring, :terminal_recovery, stage == "recover")
{:ok, _} = Application.ensure_all_started(:shoestring)
Logger.configure(level: :warning)
manifest = Path.join(Shoestring.State.root(), "terminal-restart.json")

case stage do
  "crash" ->
    fixture = Shoestring.Test.TerminalHelpers.create!()
    id = fixture.dispatch.run_id
    Phoenix.PubSub.subscribe(Shoestring.PubSub, Shoestring.Trajectory.topic(fixture.goal.id))

    {:ok, _} =
      Shoestring.Elves.start_elf(fixture.request, fixture.dispatch,
        adapter: Shoestring.Harness.Interactive,
        adapter_opts: %{provider: "fixture"},
        process_owner: :adapter,
        command: [],
        runner_opts: [cd: fixture.worktree.path]
      )

    receive do
      {:trajectory_event_committed, %{type: "run.running", run_id: ^id}} -> :ok
    after
      5000 -> raise("Fixture did not start")
    end

    Shoestring.Test.TerminalHelpers.ready_fixture!(id)
    browser = :crypto.strong_rand_bytes(32)
    {:ok, _} = Shoestring.Terminal.Session.attach(id, browser)

    {:ok, %{ownership: "human_owned"}} =
      Shoestring.Terminal.Session.action(id, browser, :takeover)

    File.write!(manifest, Jason.encode!(%{run_id: id, goal_id: fixture.goal.id}))

    IO.puts(
      "Fixture running with recorded human ownership; halting the VM without application shutdown"
    )

    System.halt(37)

  "recover" ->
    %{"run_id" => id, "goal_id" => goal_id} = Jason.decode!(File.read!(manifest))
    run = Shoestring.Repo.get!(Shoestring.Harness.RunRecord, id)
    unless run.status == "failed", do: raise("Lost fixture did not fail at startup")
    unless Shoestring.Terminal.Session.lookup(id) == nil, do: raise("Phantom terminal resumed")

    {:ok, checkpoint} =
      Shoestring.Repo.all(Shoestring.Harness.CheckpointRecord)
      |> Enum.filter(&(&1.run_id == id))
      |> then(fn rows ->
        case rows do
          [checkpoint] -> {:ok, checkpoint}
          _ -> raise("Expected exactly one checkpoint")
        end
      end)

    import Ecto.Query

    ownership =
      Shoestring.Repo.one!(
        from event in Shoestring.Trajectory.TrajectoryEvent,
          where:
            event.goal_id == ^goal_id and event.run_id == ^id and
              event.type == "terminal.ownership.changed",
          order_by: [desc: event.sequence],
          limit: 1
      )

    unless ownership.payload["state"] == "interrupted" and
             ownership.payload["owner_ref"] != "none",
           do: raise("Human ownership was not preserved honestly")

    IO.puts(
      "VERIFIED: failed run, one durable checkpoint, preserved interrupted ownership, no phantom session"
    )

    unless is_binary(checkpoint.id), do: raise("Invalid checkpoint")
end
