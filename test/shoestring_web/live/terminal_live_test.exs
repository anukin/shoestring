defmodule ShoestringWeb.TerminalLiveTest do
  use ShoestringWeb.ConnCase, async: false
  alias Shoestring.Test.TerminalHelpers

  test "an existing interactive run renders the terminal and explicit controls", %{conn: conn} do
    fixture = TerminalHelpers.create!()
    {:ok, view, _html} = live(conn, ~p"/runs/#{fixture.dispatch.run_id}/terminal")
    assert has_element?(view, "#terminal-client[phx-update=ignore][phx-hook=Terminal]")

    for id <-
          ~w(terminal-takeover terminal-release terminal-interrupt terminal-detach terminal-reattach terminal-terminate terminal-status terminal-screen terminal-retention),
        do: assert(has_element?(view, "##{id}"))

    assert has_element?(view, "#terminal-retention", "retention is off")
  end

  test "an unknown run receives no attachment capability", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/runs/#{Ecto.UUID.generate()}/terminal")
    assert has_element?(view, "#terminal-unavailable")
    refute has_element?(view, "#terminal-client")
  end
end
