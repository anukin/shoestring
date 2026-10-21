# Local browser demo. Default is the hermetic fixture. Vendor mode requires an
# explicit user-authorized one-session live budget; never invoke it in tests.
if Mix.env() != :test, do: raise("Use MIX_ENV=test for the hermetic terminal demo")

provider = System.get_env("ITER9_TERMINAL_PROVIDER", "fixture")
unless provider in ~w(fixture claude codex), do: raise("Unsupported demo provider")

if provider != "fixture" and System.get_env("ITER9_LIVE_AUTHORIZED") != "one-session",
  do: raise("Vendor demo requires an explicit one-session live authorization")

prompt =
  "Terminal smoke check in a synthetic Git repository. Do not use tools, read files, modify files, or run commands. Reply exactly TERMINAL_OK."

limit_ms = if provider == "fixture", do: 840_000, else: 120_000

# A standalone multi-process demo is not an ExUnit shared sandbox owner.
# Preserve the application's independent connections rather than inheriting
# the serial test sandbox's single connection.
repo = Application.fetch_env!(:shoestring, Shoestring.Repo)

Application.put_env(
  :shoestring,
  Shoestring.Repo,
  Keyword.merge(repo, pool: DBConnection.ConnectionPool, pool_size: 5)
)

Mix.Task.run("shoestring.state.prepare")
Mix.Task.run("ecto.create", ["--quiet"])
Mix.Task.run("ecto.migrate", ["--quiet", "--pool-size", "1"])
Application.put_env(:shoestring, :terminal_log_retention, :disabled)
Application.put_env(:shoestring, :terminal_recovery, false)
endpoint = Application.fetch_env!(:shoestring, ShoestringWeb.Endpoint)

Application.put_env(
  :shoestring,
  ShoestringWeb.Endpoint,
  Keyword.merge(endpoint, server: true, http: [ip: {127, 0, 0, 1}, port: 4309])
)

{:ok, _} = Application.ensure_all_started(:shoestring)
Logger.configure(level: :warning)

fixture = Shoestring.Test.TerminalHelpers.create!(provider, prompt)

{:ok, _elf} =
  Shoestring.Elves.start_elf(fixture.request, fixture.dispatch,
    adapter: Shoestring.Harness.Interactive,
    adapter_opts: %{provider: provider},
    process_owner: :adapter,
    command: [],
    runner_opts: [cd: fixture.worktree.path],
    notify: self()
  )

url = "http://localhost:4309/runs/#{fixture.dispatch.run_id}/terminal"
File.mkdir_p!("tmp")

File.write!(
  "tmp/iter9-fixture-demo.json",
  Jason.encode!(
    %{
      url: url,
      run_id: fixture.dispatch.run_id,
      goal_id: fixture.goal.id,
      provider: provider,
      provider_calls: if(provider == "fixture", do: 0, else: 1),
      parent_os_pid: System.pid(),
      log_retention: "disabled"
    },
    pretty: true
  )
)

IO.puts("Fixture browser terminal: #{url}")

receive do
  {:elf_terminal, run_id, terminal} ->
    IO.puts("Fixture terminal ended: #{run_id} #{inspect(terminal)}")
    Application.stop(:shoestring)
after
  limit_ms ->
    _ = Shoestring.Elves.cancel_run(fixture.dispatch.run_id)
    Application.stop(:shoestring)
    raise("Terminal demo exceeded its explicit session time limit")
end
