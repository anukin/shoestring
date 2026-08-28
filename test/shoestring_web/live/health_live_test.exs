defmodule ShoestringWeb.HealthLiveTest do
  use ShoestringWeb.ConnCase, async: false

  test "renders local readiness without contacting vendors", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert has_element?(view, "#health-page")
    assert has_element?(view, "#health-status")
    assert has_element?(view, "#health-refresh")
    assert has_element?(view, "#health-application", "ok")
    assert has_element?(view, "#health-repo", "ok")
    assert has_element?(view, "#health-state", "ok")
    assert html =~ "Shoestring health"
  end

  test "refreshes the health status from the LiveView", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert view |> element("#health-refresh") |> render_click()
    assert has_element?(view, "#health-refresh")
  end

  test "renders JSON readiness from the local endpoint", %{conn: conn} do
    conn = get(conn, "/health")
    body = json_response(conn, 200)

    assert body["ready"] == true
    assert body["checks"]["application"] == "ok"
  end

  test "returns service unavailable when local state is invalid", %{conn: conn} do
    previous = System.get_env("SHOESTRING_TEST_STATE_DIR")

    invalid_root =
      Path.join(System.tmp_dir!(), "shoestring-health-file-#{System.unique_integer([:positive])}")

    File.write!(invalid_root, "not a directory")
    System.put_env("SHOESTRING_TEST_STATE_DIR", invalid_root)

    on_exit(fn ->
      if previous,
        do: System.put_env("SHOESTRING_TEST_STATE_DIR", previous),
        else: System.delete_env("SHOESTRING_TEST_STATE_DIR")

      File.rm(invalid_root)
    end)

    body = conn |> get("/health") |> json_response(503)

    assert body["ready"] == false
    assert body["checks"]["state"] == "error"
  end
end
