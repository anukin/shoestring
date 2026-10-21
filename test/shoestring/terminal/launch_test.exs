defmodule Shoestring.Terminal.LaunchTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Test.{TerminalHelpers, ProviderCliGuard}
  alias Shoestring.Terminal.Launch

  test "launch profiles preserve user identity without forwarding unrelated environment" do
    guard = ProviderCliGuard.install!()
    keys = ~w(USER SHOESTRING_TERMINAL_UNAPPROVED ANTHROPIC_API_KEY)
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    System.put_env(%{
      "USER" => "terminal-fixture-user",
      "SHOESTRING_TERMINAL_UNAPPROVED" => "synthetic-private-value",
      "ANTHROPIC_API_KEY" => "synthetic-never-forward"
    })

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
    end)

    fixture = TerminalHelpers.create!()

    for provider <- ~w(claude codex fixture) do
      assert {:ok, profile} = Launch.profile(provider, fixture.request, fixture.worktree.path)
      assert profile.env["USER"] == "terminal-fixture-user"
      assert profile.env["PATH"] == System.get_env("PATH")
      refute Map.has_key?(profile.env, "SHOESTRING_TERMINAL_UNAPPROVED")
      refute Map.has_key?(profile.env, "ANTHROPIC_API_KEY")
    end
  end

  test "interactive Claude keeps sandbox restrictions and omits print-only options" do
    guard = ProviderCliGuard.install!()
    on_exit(fn -> ProviderCliGuard.assert_no_provider_cli_spawned!(guard) end)
    fixture = TerminalHelpers.create!()
    assert {:ok, profile} = Launch.profile("claude", fixture.request, fixture.worktree.path)
    refute "--no-session-persistence" in profile.argv
    refute "--permission-prompts" in profile.argv
    assert "--safe-mode" in profile.argv
    assert "--restricted" in profile.argv
    index = Enum.find_index(profile.argv, &(&1 == "--permission-mode"))
    assert Enum.at(profile.argv, index + 1) == "manual"
    index = Enum.find_index(profile.argv, &(&1 == "--settings"))
    settings = Jason.decode!(Enum.at(profile.argv, index + 1))
    assert settings["sandbox"]["enabled"] == true
    assert settings["sandbox"]["failIfUnavailable"] == true
    assert settings["sandbox"]["allowUnsandboxedCommands"] == false
    assert settings["sandbox"]["network"]["allowedDomains"] == []
    assert List.last(profile.argv) == fixture.request.prompt
  end
end
