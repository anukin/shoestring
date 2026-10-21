defmodule Shoestring.Terminal.RetentionTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Terminal.Session
  alias Shoestring.Test.{TerminalHelpers, ProviderCliGuard}
  alias Shoestring.Trajectory.ArtifactStore

  setup do
    guard = ProviderCliGuard.install!()
    previous = Application.get_env(:shoestring, :terminal_log_retention)
    Application.put_env(:shoestring, :terminal_log_retention, :redacted)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shoestring, :terminal_log_retention, previous),
        else: Application.delete_env(:shoestring, :terminal_log_retention)

      ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
    end)

    fixture = TerminalHelpers.create!()
    pid = TerminalHelpers.session!(fixture)
    id = fixture.dispatch.run_id
    assert {:ok, _} = Session.ready(id)
    TerminalHelpers.ready_fixture!(id)
    browser = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Session.attach(id, browser)
    assert {:ok, _} = Session.action(id, browser, :takeover)
    %{id: id, browser: browser, pid: pid}
  end

  test "retained output redacts credentials and keeps ordinary evidence", ctx do
    assert :ok =
             Session.action(
               ctx.id,
               ctx.browser,
               {:input, "token=synthetic-terminal-secret\nPUBLIC_OK\n"}
             )

    assert TerminalHelpers.output_until(ctx.id, "PUBLIC_OK") =~ "PUBLIC_OK"
    assert {:ok, :cancelled} = Session.cancel(ctx.id)
    assert {:ok, events} = Session.events(ctx.id)
    assert [artifact] = Enum.filter(events, &(&1.kind == :artifact))
    assert {:ok, %{bytes: bytes}} = ArtifactStore.read(artifact.artifact_id)
    refute bytes =~ "synthetic"
    refute bytes =~ "terminal-secret"
    assert bytes =~ "PUBLIC_OK"
    assert bytes =~ "REDACTED"
    assert :sys.get_state(ctx.pid).log == <<>>
  end

  test "failure to store enabled diagnostics is an explicit terminal error", ctx do
    previous = Application.get_env(:shoestring, :artifact_root)
    blocked = Path.join(System.tmp_dir!(), "terminal-artifact-file-#{Ecto.UUID.generate()}")
    File.write!(blocked, "fixture")
    Application.put_env(:shoestring, :artifact_root, blocked)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shoestring, :artifact_root, previous),
        else: Application.delete_env(:shoestring, :artifact_root)
    end)

    assert {:ok, :cancelled} = Session.cancel(ctx.id)
    assert %{state: "ended", reason: "artifact_failed"} = Session.status(ctx.id)
    assert {:ok, events} = Session.events(ctx.id)
    assert Enum.any?(events, &(&1.kind == :error and &1.error.code == "terminal_artifact_failed"))
    refute Enum.any?(events, &(&1.kind == :artifact))
  end

  test "retention overflow fails explicitly and retains at most its configured bound", ctx do
    # Near the limit, then send real fixture output across it. No timer or
    # scheduler-dependent output-flood polling is involved.
    :sys.replace_state(ctx.pid, &%{&1 | log: String.duplicate("x", 1_048_576)})
    assert :ok = Session.action(ctx.id, ctx.browser, {:input, "one byte over"})
    assert_receive {:terminal_status, %{state: "ended", reason: "output_overflow"}}, 5000
    assert {:ok, events} = Session.events(ctx.id)
    assert [artifact] = Enum.filter(events, &(&1.kind == :artifact))
    assert {:ok, %{bytes: bytes}} = ArtifactStore.read(artifact.artifact_id)
    assert byte_size(bytes) <= 1_048_576
    assert :sys.get_state(ctx.pid).log == <<>>
  end
end
