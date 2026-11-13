defmodule ShoestringWeb.ExternalWebTest do
  @moduledoc """
  Iteration 20 on the Sessions page: a held EXTERNAL is started with one
  click, then its card says where to work, that it is outside Shoestring's
  guarantee, and the terminal commands that complete or abandon it.
  """
  use ShoestringWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Shoestring.Test.ExternalHelpers

  alias Shoestring.Dispatches.Externals

  @moduletag :tmp_dir

  setup %{tmp_dir: dir}, do: external_session(dir)

  test "start a held EXTERNAL from the Sessions page; its card shows the worktree and commands",
       %{conn: conn} = ctx do
    dispatch = started!(ctx)
    {:ok, view, _} = live(conn, "/sessions/#{ctx.session}")

    assert has_element?(view, "#held-#{dispatch.id}", "Start this EXTERNAL work?")
    view |> element("#held-#{dispatch.id}-start") |> render_click()

    external = Externals.get(dispatch.id)
    assert external.state == "awaiting"
    assert File.dir?(external.worktree_path)

    {:ok, view, _} = live(conn, "/sessions/#{ctx.session}?open=#{dispatch.id}")
    html = render(view)
    assert html =~ "EXTERNAL work waits for you"
    assert html =~ external.worktree_path
    assert html =~ "shoestring external complete #{String.slice(dispatch.id, 0, 8)}"
    assert html =~ "outside Shoestring&#39;s guarantee"
  end
end
