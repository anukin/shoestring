defmodule ShoestringWeb.UsageAccessibilityTest do
  use ShoestringWeb.ConnCase, async: false
  import Shoestring.ConfigurationFixtures

  test "refresh announces saved data without making the account grid a live region", %{conn: conn} do
    {:ok, view, _} = live(conn, "/usage")
    assert has_element?(view, "#usage-refresh-status[role='status'][aria-atomic='true']")
    view |> element("#refresh-usage") |> render_click()
    assert has_element?(view, "#usage-refresh-status", "Saved observations refreshed")
    refute has_element?(view, "#usage-accounts[aria-live]")
  end

  test "usage history exposes dates and values as a table", %{conn: conn} do
    capacity_fixture()
    {:ok, view, _} = live(conn, "/usage")
    assert has_element?(view, "#usage-accounts table caption", "Seven-day usage history")
    assert has_element?(view, "#usage-accounts table th[scope='col']", "Date (UTC)")
    assert has_element?(view, "#usage-accounts table td", "25.0% used")
    assert has_element?(view, "#usage-accounts table td", "No observation")
    assert has_element?(view, "#usage-accounts .ss-bars[aria-hidden='true']")
  end
end
