defmodule Shoestring.Terminal.SessionTest do
  use Shoestring.DataCase, async: false
  import Ecto.Query
  alias Shoestring.Terminal.Session
  alias Shoestring.Test.{TerminalHelpers, ProviderCliGuard}
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    guard = ProviderCliGuard.install!()
    fixture = TerminalHelpers.create!()
    pid = TerminalHelpers.session!(fixture)
    assert {:ok, pgid} = Session.ready(fixture.dispatch.run_id)
    refute fixture.dispatch.run_id == fixture.request.dispatch_id
    TerminalHelpers.ready_fixture!(fixture.dispatch.run_id)
    on_exit(fn -> ProviderCliGuard.assert_no_provider_cli_spawned!(guard) end)

    %{
      fixture: fixture,
      session: pid,
      run_id: fixture.dispatch.run_id,
      pgid: pgid,
      browser: :crypto.strong_rand_bytes(32)
    }
  end

  test "real PTY output stays binary and only the current human attachment may send", ctx do
    assert {:ok, _snapshot} = Session.attach(ctx.run_id, ctx.browser)
    assert {:error, :not_input_owner} = Session.action(ctx.run_id, ctx.browser, {:input, "hello"})

    assert {:error, :not_input_owner} =
             Session.action(ctx.run_id, ctx.browser, {:resize, 40, 120})

    assert {:ok, %{ownership: "human_owned"}} = Session.action(ctx.run_id, ctx.browser, :takeover)
    assert %{can_input: true} = Session.status(ctx.run_id)
    assert :ok = Session.action(ctx.run_id, ctx.browser, {:resize, 40, 120})
    assert TerminalHelpers.output_until(ctx.run_id, "SIZE 40 120") =~ "SIZE 40 120"
    assert :ok = Session.action(ctx.run_id, ctx.browser, {:input, "héllo 世界"})
    assert TerminalHelpers.output_until(ctx.run_id, "ECHO héllo 世界") =~ "héllo 世界"
    assert :ok = Session.action(ctx.run_id, ctx.browser, {:input, "BINARY\r"})
    raw = :binary.list_to_bin(Enum.to_list(0..255))
    assert :binary.match(TerminalHelpers.output_until(ctx.run_id, raw), raw) != :nomatch

    assert {:error, :terminal_input_too_large} =
             Session.action(ctx.run_id, ctx.browser, {:input, String.duplicate("x", 8193)})

    events = Repo.all(from event in TrajectoryEvent, where: event.run_id == ^ctx.run_id)
    ownership = Enum.find(events, &(&1.type == "terminal.ownership.changed"))
    assert ownership.actor == "human:local"
    refute Jason.encode!(Enum.map(events, & &1.payload)) =~ "héllo"
  end

  test "takeover waits for explicit automation boundary and fences both input sources", ctx do
    assert {:ok, _} = Session.attach(ctx.run_id, ctx.browser)
    assert :ok = Session.agent_input(ctx.run_id, "agent batch")

    assert {:ok, %{ownership: "takeover_requested"}} =
             Session.action(ctx.run_id, ctx.browser, :takeover)

    assert {:error, :terminal_owned} = Session.agent_input(ctx.run_id, "second batch")
    assert {:error, :not_input_owner} = Session.action(ctx.run_id, ctx.browser, {:input, "human"})
    assert {:ok, %{ownership: "human_owned"}} = Session.boundary(ctx.run_id)
    assert :ok = Session.action(ctx.run_id, ctx.browser, {:input, "human"})
    assert {:ok, %{ownership: "agent_owned"}} = Session.action(ctx.run_id, ctx.browser, :release)
    assert :ok = Session.agent_input(ctx.run_id, "next batch")
  end

  test "detaching preserves the child and requires explicit reclaim and release", ctx do
    {:ok, _} = Session.attach(ctx.run_id, ctx.browser)
    {:ok, _} = Session.action(ctx.run_id, ctx.browser, :takeover)
    assert :ok = Session.detach(ctx.run_id)
    assert %{state: "running", ownership: "detached_human_owned"} = Session.status(ctx.run_id)
    assert {:error, :terminal_owned} = Session.agent_input(ctx.run_id, "no automatic release")
    assert {:ok, %{can_input: false}} = Session.attach(ctx.run_id, ctx.browser)
    assert {:ok, _} = Session.action(ctx.run_id, ctx.browser, :takeover)
    assert {:ok, _} = Session.action(ctx.run_id, ctx.browser, :release)
    assert :ok = Session.agent_input(ctx.run_id, "released")
  end

  test "a slow attachment is explicitly detached while the live session stays bounded", ctx do
    {:ok, _} = Session.attach(ctx.run_id, ctx.browser)
    {:ok, _} = Session.action(ctx.run_id, ctx.browser, :takeover)
    assert :ok = Session.action(ctx.run_id, ctx.browser, {:input, "FLOOD\r"})
    assert_receive {:terminal_detached, :slow_consumer}, 5000
    assert %{state: "running", ownership: "detached_human_owned"} = Session.status(ctx.run_id)
    state = :sys.get_state(ctx.session)
    assert byte_size(state.ring) <= 65_536
    assert state.clients == %{}
    assert state.log == <<>>
    assert {:ok, :cancelled} = Session.cancel(ctx.run_id)
  end

  test "helper crash yields one error without taking down Repo, PubSub or endpoint", ctx do
    before =
      Enum.map([Shoestring.Repo, Shoestring.PubSub, ShoestringWeb.Endpoint], &Process.whereis/1)

    {:ok, _} = Session.attach(ctx.run_id, ctx.browser)
    state = :sys.get_state(ctx.session)
    {:os_pid, pid} = Port.info(state.port, :os_pid)

    {_, 0} =
      System.cmd("python3", [
        "-c",
        "import os,signal,sys; os.kill(int(sys.argv[1]),signal.SIGKILL)",
        to_string(pid)
      ])

    assert_receive {:terminal_status, %{state: "ended", reason: "helper_failed"}}, 5000
    assert {:ok, events} = Session.events(ctx.run_id)
    assert Enum.any?(events, &(&1.kind == :error and &1.error.code == "terminal_helper_failed"))

    assert Repo.aggregate(
             from(event in TrajectoryEvent,
               where: event.run_id == ^ctx.run_id and event.type == "terminal.session.exited"
             ),
             :count
           ) == 1

    assert before ==
             Enum.map(
               [Shoestring.Repo, Shoestring.PubSub, ShoestringWeb.Endpoint],
               &Process.whereis/1
             )
  end
end
