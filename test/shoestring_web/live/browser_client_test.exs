defmodule ShoestringWeb.BrowserClientTest do
  use ShoestringWeb.ConnCase, async: false

  test "page loads locked browser clients before bootstrap", %{conn: conn} do
    document = conn |> get("/agents/new") |> html_response(200) |> LazyHTML.from_document()
    sources = document |> LazyHTML.query("script[src]") |> LazyHTML.attribute("src")

    assert sources == [
             "/assets/vendor/phoenix/phoenix.js",
             "/assets/vendor/live_view/phoenix_live_view.js",
             "/assets/vendor/xterm/xterm.js",
             "/assets/vendor/xterm/addon-fit.js",
             "/assets/js/terminal.js",
             "/assets/js/app.js"
           ]

    assert document |> LazyHTML.query("meta[name='csrf-token']") |> LazyHTML.attribute("content") !=
             []

    assert document |> LazyHTML.query("#agent-form") |> LazyHTML.attribute("method") == ["post"]
  end

  test "all locked browser and terminal assets are served", %{conn: conn} do
    for path <- [
          "/assets/vendor/phoenix/phoenix.js",
          "/assets/vendor/live_view/phoenix_live_view.js",
          "/assets/vendor/xterm/xterm.js",
          "/assets/vendor/xterm/addon-fit.js",
          "/assets/js/terminal.js"
        ] do
      response = get(conn, path)
      assert response.status == 200
      assert byte_size(response.resp_body) > 1000

      assert Enum.any?(
               get_resp_header(response, "content-type"),
               &String.contains?(&1, "javascript")
             )
    end
  end

  test "settings fallback avoids submitting configuration in the URL", %{conn: conn} do
    document = conn |> get("/settings") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#settings-form") |> LazyHTML.attribute("method") == [
             "post"
           ]
  end
end
