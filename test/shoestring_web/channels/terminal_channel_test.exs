defmodule ShoestringWeb.TerminalChannelTest do
  use Shoestring.DataCase, async: false
  import Phoenix.ChannelTest
  @endpoint ShoestringWeb.Endpoint
  alias Shoestring.Terminal.Session
  alias Shoestring.Test.{TerminalHelpers, ProviderCliGuard}
  alias ShoestringWeb.{TerminalAccess, TerminalChannel, TerminalSocket}

  setup do
    Process.flag(:trap_exit, true)
    guard = ProviderCliGuard.install!()
    fixture = TerminalHelpers.create!()
    pid = TerminalHelpers.session!(fixture)
    run_id = fixture.dispatch.run_id
    assert {:ok, _} = Session.ready(run_id)
    TerminalHelpers.ready_fixture!(run_id)
    browser = :crypto.strong_rand_bytes(32)
    {:ok, tokens} = TerminalAccess.tokens(browser, run_id)
    socket = socket(TerminalSocket, nil, %{terminal_browser: browser})
    on_exit(fn -> ProviderCliGuard.assert_no_provider_cli_spawned!(guard) end)

    %{
      fixture: fixture,
      session: pid,
      run_id: run_id,
      browser: browser,
      tokens: tokens,
      socket: socket
    }
  end

  test "socket requires loopback, a local host and a matching signed browser session", ctx do
    info = %{
      session: %{"terminal_browser" => ctx.browser},
      peer_data: %{address: {127, 0, 0, 1}},
      uri: URI.parse("http://localhost:4002/terminal/socket")
    }

    assert {:ok, _socket} =
             connect(TerminalSocket, %{"token" => ctx.tokens.socket_token}, connect_info: info)

    assert :error =
             connect(TerminalSocket, %{"token" => ctx.tokens.socket_token},
               connect_info: %{info | peer_data: %{address: {192, 0, 2, 1}}}
             )

    assert :error =
             connect(TerminalSocket, %{"token" => ctx.tokens.socket_token},
               connect_info: %{info | uri: URI.parse("http://foreign.example/terminal/socket")}
             )

    assert :error =
             connect(TerminalSocket, %{"token" => ctx.tokens.socket_token},
               connect_info: %{info | session: %{}}
             )

    assert :error = connect(TerminalSocket, %{"token" => "invalid"}, connect_info: info)
  end

  test "wrong run/browser capabilities expose no output while authorized attachment does", ctx do
    wrong = Ecto.UUID.generate()

    assert {:error, _} =
             subscribe_and_join(ctx.socket, TerminalChannel, "terminal:#{wrong}", %{
               "capability" => ctx.tokens.capability
             })

    other = socket(TerminalSocket, nil, %{terminal_browser: :crypto.strong_rand_bytes(32)})

    assert {:error, _} =
             subscribe_and_join(other, TerminalChannel, "terminal:#{ctx.run_id}", %{
               "capability" => ctx.tokens.capability
             })

    assert :sys.get_state(ctx.session).clients == %{}

    assert {:ok, snapshot, _socket} =
             subscribe_and_join(ctx.socket, TerminalChannel, "terminal:#{ctx.run_id}", %{
               "capability" => ctx.tokens.capability
             })

    assert Base.decode64!(snapshot.data) =~ "Shoestring fixture terminal"
    assert snapshot.can_input == false
  end

  test "the browser cannot launch commands, and input needs exclusive takeover", ctx do
    {:ok, snapshot, socket} =
      subscribe_and_join(ctx.socket, TerminalChannel, "terminal:#{ctx.run_id}", %{
        "capability" => ctx.tokens.capability
      })

    ack = push(socket, "ack", %{"sequence" => snapshot.sequence})
    assert_reply ack, :ok

    spawn =
      push(socket, "spawn", %{"executable" => "/bin/sh", "argv" => ["-c", "echo forbidden"]})

    assert_reply spawn, :error, %{reason: "invalid_terminal_message"}
    input = push(socket, "input", %{"data" => Base.encode64("human input")})
    assert_reply input, :error, %{reason: "not_input_owner"}
    control = push(socket, "takeover", %{})
    assert_reply control, :ok, %{can_input: true, ownership: "human_owned"}
    input = push(socket, "input", %{"data" => Base.encode64("héllo 世界")})
    assert_reply input, :ok
    assert_push "output", %{data: data}, 5000
    assert Base.decode64!(data) =~ "ECHO héllo 世界"
    too_large = push(socket, "input", %{"data" => Base.encode64(String.duplicate("x", 8193))})
    assert_reply too_large, :error, %{reason: "invalid_terminal_message"}
    bad = push(socket, "input", %{"data" => "not base64"})
    assert_reply bad, :error, %{reason: "invalid_terminal_message"}
  end

  test "leaving the channel retains human ownership and the child", ctx do
    {:ok, _snapshot, socket} =
      subscribe_and_join(ctx.socket, TerminalChannel, "terminal:#{ctx.run_id}", %{
        "capability" => ctx.tokens.capability
      })

    control = push(socket, "takeover", %{})
    assert_reply control, :ok, %{ownership: "human_owned"}
    {:ok, _} = Session.attach(ctx.run_id, :crypto.strong_rand_bytes(32))
    ref = leave(socket)
    assert_reply ref, :ok

    assert_receive {:terminal_status, %{state: "running", ownership: "detached_human_owned"}},
                   5000

    assert {:error, :terminal_owned} = Session.agent_input(ctx.run_id, "not released")
  end
end
