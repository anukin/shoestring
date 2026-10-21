defmodule Shoestring.Terminal.CompatibilityTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Test.TerminalHelpers
  alias Shoestring.Terminal.Session

  for {version, helper_version} <- [{99, "99.0.0"}, {1, "0.1.0"}] do
    test "helper #{helper_version} with protocol #{version} is visibly incompatible and cannot spawn" do
      assert_incompatible!(unquote(version), unquote(helper_version))
    end
  end

  defp assert_incompatible!(version, helper_version) do
    fixture = TerminalHelpers.create!()
    path = Path.join(System.tmp_dir!(), "terminal-incompatible-#{Ecto.UUID.generate()}")
    python = System.find_executable("python3")

    File.write!(path, """
    #!#{python}
    import json, struct, sys
    body = json.dumps({"op":"hello","version":#{version},"helper_version":"#{helper_version}","max_frame":65536}).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(body)) + body)
    sys.stdout.buffer.flush()
    sys.stdin.buffer.read()
    """)

    File.chmod!(path, 0o700)
    previous = Application.get_env(:shoestring, :terminal_helper)
    Application.put_env(:shoestring, :terminal_helper, path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shoestring, :terminal_helper, previous),
        else: Application.delete_env(:shoestring, :terminal_helper)
    end)

    pid = TerminalHelpers.session!(fixture)
    assert {:error, :terminal_session_ended} = Session.ready(fixture.dispatch.run_id)

    assert %{state: "ended", reason: "incompatible_helper"} =
             Session.status(fixture.dispatch.run_id)

    assert :sys.get_state(pid).process_group == nil
    assert {:ok, events} = Session.events(fixture.dispatch.run_id)
    assert [error] = events
    assert error.error.code == "terminal_incompatible_helper"
  end
end
