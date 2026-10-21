defmodule Shoestring.Terminal.LaunchTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Test.{TerminalHelpers, ProviderCliGuard}
  alias Shoestring.Terminal.Launch

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
