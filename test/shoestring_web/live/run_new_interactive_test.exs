defmodule ShoestringWeb.RunNewInteractiveTest do
  use ShoestringWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Shoestring.Test.{TerminalHelpers, ProviderCliGuard}
  alias Shoestring.{Repo, Worktrees}
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Harness.CodexAppServer.GitSandbox
  alias Shoestring.Harness.Dispatch.ElfEffect

  setup do
    guard = ProviderCliGuard.install!()
    fixture = TerminalHelpers.create!()
    previous = Application.get_env(:shoestring, :manual_run_allowed_repo_roots)
    Application.put_env(:shoestring, :manual_run_allowed_repo_roots, [fixture.source])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shoestring, :manual_run_allowed_repo_roots, previous),
        else: Application.delete_env(:shoestring, :manual_run_allowed_repo_roots)

      ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
    end)

    %{source: fixture.source}
  end

  for {selection, provider} <- [
        {"claude_interactive", "claude"},
        {"codex_interactive", "codex"},
        {"terminal_fixture", "fixture"}
      ] do
    test "#{selection} submits a private interactive run without starting a provider", %{
      conn: conn,
      source: source
    } do
      before = MapSet.new(Worktrees.list(), & &1.run_id)
      {:ok, view, _} = live(conn, ~p"/runs/new")

      render_submit(view, :start_run, %{
        "run" => %{
          "repo_path" => source,
          "base_revision" => "HEAD",
          "provider" => unquote(selection),
          "prompt" => "Harmless terminal fixture request",
          "timeout_seconds" => "60",
          "max_events" => "100",
          "lease_seconds" => "60"
        }
      })

      assert [wt] = Enum.reject(Worktrees.list(), &MapSet.member?(before, &1.run_id))
      assert wt.metadata["shoestring.manual:source"] == source
      assert {:ok, %{"writableRoots" => roots}} = GitSandbox.policy(wt.path, wt.workspace_ref)
      assert GitSandbox.physical_path(wt.path) in roots
      refute File.exists?(Path.join(source, ".git/worktrees"))
      run = Repo.get!(RunRecord, wt.run_id)
      assert run.provider_id == unquote(provider) <> "_interactive_pty"
      assert {:ok, opts} = ElfEffect.launch_opts(run)
      assert opts[:adapter] == Shoestring.Harness.Interactive
      assert opts[:adapter_opts][:provider] == unquote(provider)
      assert opts[:process_owner] == :adapter
    end
  end
end
